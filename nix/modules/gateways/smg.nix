# The Shepherd Model Gateway (SMG) in front of every listed endpoint, as a
# native service under `services.llmhop.gateway.smg` and as a Quadlet
# container under `services.llmhop.gateway.smg-quadlet`.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  gateway = import ./shared.nix lib;

  unit = "smg";
  displayName = "SMG";

  # SMG's launcher parses its flags with argparse.
  argv =
    cfg:
    [
      "-m"
      "smg.launch_router"
    ]
    ++ util.renderCliArgs {
      negateBools = false;
      listStyle = "values";
    } cfg.settings;

  # A discovery file rather than `--worker-urls`: SMG keeps retrying the
  # workers it lists, while it gives up on one of the command line after
  # `--worker-startup-timeout-secs`, which loading a model may well exceed.
  discoveryFile =
    pkgs: endpoints:
    (pkgs.formats.json { }).generate "smg-workers.json" {
      version = 1;
      workers = map (e: {
        id = e.name;
        inherit (e) url;
        model_id = e.name;
      }) endpoints;
    };
  containerDiscoveryFile = "${util.containerRuntimeDirectory}/workers.json";

  options = gateway.options displayName // {
    credentials = util.credentialsOption;
    settings = settingsOption;
  };

  settingsOption = mkOption {
    type = with types; attrsOf json;
    default = { };
    example = {
      api-key-file = "\${cred:smg.api-key}";
      policy = "cache_aware";
    };
    description = ''
      CLI flags of SMG, rendered as `--<key> <value>` with `false`
      dropped. The listener and the discovery file of every listed model
      always win, while metrics on `127.0.0.1:29000` and disabled
      tokenizer downloads are defaults. Credential references
      resolve to file paths for upstream options such as `api-key-file`
      and `tenant-api-keys-file`, which require a supporting SMG build.
    '';
  };

  # The `settings` of `cfg` reading the discovery file at `discovery`, whose
  # listener wins, so the port claim and the firewall agree with SMG.
  defaultSettings =
    cfg: discovery:
    lib.mapAttrs (_: lib.mkForce) {
      inherit (cfg) host port;
      discovery-provider = "file";
      discovery-file = discovery;
    }
    // lib.mapAttrs (_: lib.mkOptionDefault) {
      enable-igw = true;
      prometheus-host = "127.0.0.1";
      prometheus-port = 29000;
      disable-tokenizer-autoload = true;
    };

  # The claim of the metrics port beside `port`.
  metricsClaim = name: cfg: {
    services.llmhop.claims.port = lib.optionalAttrs (cfg.settings.prometheus-port or null != null) {
      ${toString cfg.settings.prometheus-port} = [ (gateway.owner name) ];
    };
  };
in
{
  native =
    {
      config,
      pkgs,
      utils,
      ...
    }:
    let
      name = "smg";
      cfg = config.services.llmhop.gateway.${name};
      endpoints = gateway.listedEndpoints config;
    in
    {
      options.services.llmhop.gateway = {
        type = mkOption { type = types.nullOr (types.enum [ name ]); };
        ${name} = options // {
          package = mkOption {
            type = types.package;
            description = ''
              Python environment providing the `smg` package, built with the
              flake's `mkUvEnv`, since nixpkgs lacks SMG.
            '';
          };
        };
      };
      config = lib.mkIf (config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          (gateway.config {
            inherit
              name
              unit
              cfg
              endpoints
              ;
          })
          (metricsClaim name cfg)
          { services.llmhop.gateway.${name}.settings = defaultSettings cfg (discoveryFile pkgs endpoints); }
          (gateway.nativeService {
            inherit utils cfg unit;
            description = "SMG model gateway";
            command = [ (lib.getExe' cfg.package "python") ] ++ argv cfg;
          })
        ]
      );
    };

  quadlet =
    sectionType:
    { config, pkgs, ... }:
    let
      name = "smg-quadlet";
      cfg = config.services.llmhop.gateway.${name};
      endpoints = gateway.listedEndpoints config;
    in
    {
      options.services.llmhop.gateway = {
        type = mkOption { type = types.nullOr (types.enum [ name ]); };
        ${name} =
          options
          // gateway.containerOptions {
            inherit sectionType;
            inherit displayName;
            image = util.imageOption // {
              example = "ghcr.io/smg-project/smg:nightly";
            };
          };
      };
      config = lib.mkIf (config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          (gateway.config {
            inherit
              name
              unit
              cfg
              endpoints
              ;
          })
          (metricsClaim name cfg)
          { services.llmhop.gateway.${name}.settings = defaultSettings cfg containerDiscoveryFile; }
          (gateway.quadletContainer {
            inherit
              config
              name
              cfg
              unit
              ;
            entrypoint = "python3";
            arguments = argv cfg;
            volumes = [
              "${discoveryFile pkgs endpoints}:${containerDiscoveryFile}:ro"
            ];
          })
        ]
      );
    };
}
