# Options and units shared by the external gateways, each the one entry point
# routing the listed endpoints of every backend. See "Gateways" in the module
# internals documentation.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
in
rec {
  # Option path of the gateway `name`, naming it in `services.llmhop.claims`.
  owner = name: "services.llmhop.gateway.${name}";

  # Restarts of every gateway, which exits only on failure.
  restartConfig = {
    Restart = "on-failure";
    RestartSec = 5;
  };

  # The endpoints an external gateway routes, in a stable order.
  listedEndpoints =
    config:
    lib.pipe config.services.llmhop.endpoints [
      lib.attrValues
      (lib.filter (e: !e.unlisted))
      (lib.sortOn (e: e.name))
    ];

  # Options of every external gateway listening on TCP.
  options = displayName: {
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
      description = ''
        Environment variables of ${displayName}. With `credentials`,
        `''${cred:<name>}` expands to the path of one of them.
      '';
    };
    environmentFile = mkOption {
      type = with types; nullOr externalPath;
      default = null;
      description = ''
        File outside the Nix store in `KEY=VALUE` format, loaded by
        systemd or Podman and forwarded to ${displayName}.
      '';
    };
  };

  # Configuration of the selected gateway `name`, which reaches `endpoints` on
  # TCP only and binds `port` and the further `ports`.
  config =
    {
      name,
      unit,
      cfg,
      endpoints,
      ports ? [ ],
    }:
    {
      assertions = map (e: {
        assertion = e.socket == null;
        message = "services.llmhop: `${e.owner}` is routed by the gateway `${name}`, but binds a unix socket, which the gateway cannot reach, so set its `port`.";
      }) endpoints;
      services.llmhop = {
        gateway.routes = map (e: e.owner) endpoints;
        claims = {
          unit.${unit} = [ (owner name) ];
          port = lib.genAttrs (map toString ([ cfg.port ] ++ ports)) (_: [ (owner name) ]);
        };
      };
      networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
    };

  # The systemd service `unit` of a native gateway as a dynamic user.
  nativeService =
    {
      utils,
      cfg,
      unit,
      description,
      command,
      credentials ? { },
      serviceConfig ? { },
    }:
    {
      systemd.services.${unit} = {
        inherit description;
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = util.resolveCredentialRefs util.credentialDirectory credentials cfg.environment;
        unitConfig = util.startLimitConfig;
        serviceConfig =
          util.hardenedServiceConfig
          // util.credentialServiceConfig credentials
          // restartConfig
          // {
            DynamicUser = true;
            EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
            ExecStart = util.execStart utils credentials command;
            UMask = "0077";
          }
          // serviceConfig;
      };
    };

  # The Quadlet image and container `unit` of the gateway `name` on the host
  # network, which reaches every endpoint on loopback and binds its listener
  # there directly. It runs the `image` of `cfg` unless `image` and `imageTag`
  # replace it, with its entrypoint unless `entrypoint` replaces it, followed
  # by `arguments`.
  quadletContainer =
    {
      config,
      name,
      cfg,
      unit,
      image ? cfg.image,
      imageTag ? null,
      entrypoint ? null,
      arguments ? [ ],
      credentials ? { },
      credentialMountOptions ? [ ],
      environment ? { },
      volumes ? [ ],
      serviceConfig ? { },
      containerConfig ? { },
    }:
    let
      imageUnit = util.imageUnit {
        inherit (config.virtualisation.quadlet) images;
        inherit image;
        tag = imageTag;
        name = unit;
        owner = owner name;
      };
    in
    {
      assertions = [ (util.requireQuadlet config (owner name)) ];
      services.llmhop.claims = imageUnit.claims;
      virtualisation.quadlet = {
        inherit (imageUnit) images;
        containers.${unit} = {
          unitConfig = util.startLimitConfig;
          serviceConfig = util.credentialServiceConfig credentials // serviceConfig;
          containerConfig =
            util.baseContainerConfig
            // imageUnit.containerConfig
            // {
              Network = "host";
              Environment =
                util.resolveCredentialRefs util.containerCredentialDirectory credentials cfg.environment
                // util.credentialEnvironment credentials
                // environment;
              EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
              Volume = volumes ++ util.credentialMount credentialMountOptions credentials;
            }
            // lib.optionalAttrs (entrypoint != null) { Entrypoint = lib.toJSON [ entrypoint ]; }
            // lib.optionalAttrs (arguments != [ ]) {
              Exec = lib.escapeShellArgs (
                util.resolveCredentialRefs util.containerCredentialDirectory credentials arguments
              );
            }
            # The credential mount belongs to host root, so the container runs
            # as root to read it, without any capability like every backend,
            # unless `containerConfig` maps another identity.
            // lib.optionalAttrs (credentials != { }) { User = "0:0"; }
            // containerConfig
            // cfg.containerConfig;
        };
      };
    };
}
