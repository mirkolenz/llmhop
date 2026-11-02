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

  settingsOption = mkOption {
    type = with types; attrsOf anything;
    default = { };
    example = {
      api-key-file = "\${cred:smg.api-key}";
      policy = "cache_aware";
    };
    description = ''
      CLI flags of SMG, rendered as `--<key> <value>` with `false`
      dropped. The listener, the discovery file of every listed model,
      metrics on `127.0.0.1:29000` and disabled tokenizer downloads are
      defaults here, so a definition replaces them. Credential references
      resolve to file paths for upstream options such as `api-key-file`
      and `tenant-api-keys-file`, which require a supporting SMG build.
    '';
  };

  # The `settings` of `cfg` reading the discovery file at `discovery`.
  defaultSettings =
    cfg: discovery:
    lib.mapAttrs (_: lib.mkOptionDefault) {
      inherit (cfg) host port;
      enable-igw = true;
      discovery-provider = "file";
      discovery-file = discovery;
      prometheus-host = "127.0.0.1";
      prometheus-port = 29000;
      disable-tokenizer-autoload = true;
    };

  # The metrics port beside `port`.
  metricsPorts =
    cfg: lib.optional (cfg.settings.prometheus-port or null != null) cfg.settings.prometheus-port;
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
        ${name} = gateway.options displayName // {
          package = mkOption {
            type = types.package;
            description = ''
              Python environment providing the `smg` package, built with the
              flake's `mkUvEnv`, since nixpkgs lacks SMG.
            '';
          };
          credentials = util.credentialsOption;
          settings = settingsOption;
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
            ports = metricsPorts cfg;
          })
          { services.llmhop.gateway.${name}.settings = defaultSettings cfg (discoveryFile pkgs endpoints); }
          (gateway.nativeService {
            inherit utils cfg unit;
            inherit (cfg) credentials;
            description = "SMG model gateway";
            command = [ (lib.getExe' cfg.package "python") ] ++ argv cfg;
          })
        ]
      );
    };

  quadlet =
    { config, pkgs, ... }:
    let
      name = "smg-quadlet";
      cfg = config.services.llmhop.gateway.${name};
      endpoints = gateway.listedEndpoints config;
    in
    {
      options.services.llmhop.gateway = {
        type = mkOption { type = types.nullOr (types.enum [ name ]); };
        ${name} = gateway.options displayName // {
          image = util.imageOption // {
            example = "ghcr.io/smg-project/smg:nightly";
          };
          credentials = util.credentialsOption;
          settings = settingsOption;
          containerConfig = util.containerConfigOption "SMG";
          mountOptions.credentials = util.credentialMountOptionsOption "SMG";
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
            ports = metricsPorts cfg;
          })
          { services.llmhop.gateway.${name}.settings = defaultSettings cfg containerDiscoveryFile; }
          (gateway.quadletContainer {
            inherit
              config
              name
              cfg
              unit
              ;
            inherit (cfg) credentials;
            credentialMountOptions = cfg.mountOptions.credentials;
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
