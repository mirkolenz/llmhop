# Options and units shared by the gateways, each the one entry point that
# routes the endpoints of every backend. See "Gateways" in the module
# internals documentation.
lib:
{
  common,
  native,
  quadlet,
}:
let
  inherit (lib) mkOption types;
  inherit (common)
    credentialServiceConfig
    credentialsOption
    sharedUnitConfig
    ;
in
rec {
  # Option path of the gateway `name`, naming it in `services.llmhop.claims`.
  owner = name: "services.llmhop.gateway.${name}";

  # Adds `name` to the values of `services.llmhop.gateway.type`, whose
  # declarations by every gateway module merge.
  typeOption = name: { type = mkOption { type = types.nullOr (types.enum [ name ]); }; };

  # Restarts of every gateway, which exits only on failure.
  restartConfig = {
    Restart = "on-failure";
    RestartSec = 5;
  };

  # Options of a gateway running from a container `image`.
  imageOptions =
    { image, tagExample }:
    {
      image = mkOption {
        type = types.str;
        default = image;
        description = "Container image of the gateway.";
      };
      tag = mkOption {
        type = types.str;
        example = tagExample;
        description = "Tag of `image`, unless `digest` pins it.";
      };
      digest = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "sha256:a73fb0b9046fee099f7c1829d2548e6cc1740f4c2776a6855fa659ae5d0deb49";
        description = "Immutable digest of `image`, which takes precedence over `tag`.";
      };
    };

  # The module of the gateway `name` listening on TCP, which routes the listed
  # endpoints in a stable order and reaches them on TCP only. Its options are
  # the shared ones, `options` and the `settings` option, which `settings`
  # builds from `pkgs`. `secrets` describes what `${cred:<name>}` expands to.
  # Once selected, `defaults` of `settings`, the further `ports` it binds and
  # `config` derive from `{ pkgs, config, cfg, endpoints }`.
  mkModule =
    {
      name,
      displayName,
      unit,
      secrets,
      options,
      settings,
      defaults,
      ports ? _: [ ],
      config,
    }:
    args@{ pkgs, ... }:
    let
      cfg = args.config.services.llmhop.gateway.${name};
      endpoints = lib.pipe args.config.services.llmhop.endpoints [
        lib.attrValues
        (lib.filter (e: !e.unlisted))
        (lib.sortOn (e: e.name))
      ];
      context = {
        inherit
          pkgs
          cfg
          endpoints
          name
          unit
          ;
        inherit (args) config;
      };
    in
    {
      options.services.llmhop.gateway = typeOption name // {
        ${name} = {
          host = mkOption {
            type = types.str;
            default = "127.0.0.1";
            example = "0.0.0.0";
            description = "IP address ${displayName} listens on.";
          };
          port = mkOption {
            type = types.port;
            default = 8080;
            description = "TCP port ${displayName} listens on.";
          };
          openFirewall = mkOption {
            type = types.bool;
            default = false;
            description = "Whether to open `port` in the host firewall.";
          };
          environment = mkOption {
            type = with types; attrsOf str;
            default = { };
            description = "Environment variables of ${displayName}.";
          };
          environmentFile = mkOption {
            type = with types; nullOr path;
            default = null;
            description = ''
              File in `KEY=VALUE` format forwarded to ${displayName}. Prefer
              `credentials` for secrets.
            '';
          };
          credentials = credentialsOption // {
            description = credentialsOption.description + ''

              ${secrets}
            '';
          };
          settings = settings pkgs;
        }
        // options;
      };
      config = lib.mkIf (args.config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          {
            assertions = map (e: {
              assertion = e.socket == null;
              message = "services.llmhop: `${e.owner}` is routed by the gateway `${name}`, but binds a unix socket, which the gateway cannot reach, so set its `port`.";
            }) endpoints;
            services.llmhop = {
              gateway = {
                routes = map (e: e.name) endpoints;
                ${name}.settings = defaults context;
              };
              claims = {
                unit.${unit} = [ (owner name) ];
                port = lib.genAttrs (map toString ([ cfg.port ] ++ ports cfg)) (_: [ (owner name) ]);
              };
            };
            networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
          }
          (config context)
        ]
      );
    };

  # The systemd service of a native gateway as a dynamic user, running
  # `script` with `$CREDENTIALS_DIRECTORY` set, given the `mkModule` context.
  nativeService =
    {
      pkgs,
      cfg,
      unit,
      description,
      script,
      serviceConfig ? { },
      ...
    }:
    {
      systemd.services.${unit} = {
        inherit description;
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        inherit (cfg) environment;
        unitConfig = sharedUnitConfig;
        serviceConfig =
          native.hardenedServiceConfig
          // credentialServiceConfig cfg.credentials
          // restartConfig
          // {
            DynamicUser = true;
            EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
            ExecStart = pkgs.writeShellScript unit script;
            UMask = "0077";
          }
          // serviceConfig;
      };
    };

  # The Quadlet image and container of the gateway `name` on the host network,
  # which reaches every endpoint on loopback and binds its listener there
  # directly. `script` runs as the container's entrypoint, with the
  # credentials of `cfg` mounted at `quadlet.credentialDirectory`, given the
  # `mkModule` context.
  quadletContainer =
    {
      config,
      name,
      cfg,
      unit,
      script,
      environment ? { },
      volumes ? [ ],
      serviceConfig ? { },
      ...
    }:
    let
      image = quadlet.imageUnit {
        inherit (config.virtualisation.quadlet) images;
        inherit (cfg) image tag digest;
        prefix = unit;
      };
    in
    {
      assertions = [ (quadlet.requireEnabled config (owner name)) ];
      virtualisation.quadlet = {
        inherit (image) images;
        containers.${unit} = {
          unitConfig = sharedUnitConfig;
          serviceConfig = credentialServiceConfig cfg.credentials // restartConfig // serviceConfig;
          containerConfig =
            quadlet.baseContainerConfig
            // image.containerConfig (cfg.digest == null)
            // {
              Network = "host";
              Environment = cfg.environment // environment;
              EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
              Entrypoint = lib.toJSON [
                "/bin/sh"
                "-c"
                script
              ];
              Volume = volumes ++ quadlet.credentialMount [ ] cfg.credentials;
            }
            # The credential mount belongs to host root, so the container runs
            # as root to read it, without any capability like every backend.
            // lib.optionalAttrs (cfg.credentials != { }) { User = "0:0"; };
        };
      };
    };
}
