# The Shepherd Model Gateway (SMG) in front of every listed endpoint, as a
# native service under `services.llmhop.gateway.smg` and as a Quadlet
# container under `services.llmhop.gateway.smg-quadlet`.
lib:
{
  common,
  gateway,
  quadlet,
}:
let
  inherit (lib) mkOption types;
  inherit (common) replaceCredentialRefs;

  unit = "smg";

  # SMG's launcher parses its flags with argparse.
  dialect = {
    negateBools = false;
    listStyle = "values";
  };

  launcher = [
    "-m"
    "smg.launch_router"
  ];

  containerDiscoveryFile = "${quadlet.containerRuntimeDirectory}/workers.json";

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

  # The shell command running `argv`, each `${cred:<name>}` in it replaced at
  # start by the contents of the credential below `directory`, a shell
  # expression, since SMG takes its keys on its command line only.
  credentialCommand =
    directory: credentials: argv:
    # `escapeShellArg` single-quotes every reference, which the replacement
    # closes around a command substitution.
    "exec "
    + replaceCredentialRefs (name: "'\"$(cat ${directory}/${name})\"'") credentials (
      lib.escapeShellArgs argv
    );

  # The module of the gateway `name`, whose `options` extend the shared ones
  # and whose `config` runs it with its `settings` rendered as `argv` and the
  # generated `discovery` file, unless the container mounts it at
  # `discoveryPath`.
  mkModule =
    {
      name,
      options,
      discoveryPath ? null,
      config,
    }:
    gateway.mkModule {
      inherit name unit options;
      displayName = "SMG";
      secrets = ''
        In `settings`, a reference expands to the credential's contents, read
        when SMG starts, since SMG takes `--api-key` and `--tenant-api-key`
        only on its command line.
      '';
      settings =
        _:
        mkOption {
          type = with types; attrsOf anything;
          default = { };
          example = {
            api-key = "\${cred:smg.api-key}";
            policy = "cache_aware";
          };
          description = ''
            CLI flags of SMG, rendered as `--<key> <value>` with `false`
            dropped. The listener, the discovery file of every listed model,
            metrics on `127.0.0.1:29000` and disabled tokenizer downloads are
            defaults here, so a definition replaces them.
          '';
        };
      defaults =
        {
          pkgs,
          cfg,
          endpoints,
          ...
        }:
        lib.mapAttrs (_: lib.mkOptionDefault) {
          inherit (cfg) host port;
          enable-igw = true;
          discovery-provider = "file";
          discovery-file = if discoveryPath == null then discoveryFile pkgs endpoints else discoveryPath;
          prometheus-host = "127.0.0.1";
          prometheus-port = 29000;
          disable-tokenizer-autoload = true;
        };
      ports =
        cfg: lib.optional (cfg.settings.prometheus-port or null != null) cfg.settings.prometheus-port;
      config =
        context@{
          pkgs,
          cfg,
          endpoints,
          ...
        }:
        config (
          context
          // {
            argv = common.renderCliArgs dialect cfg.settings;
            discovery = discoveryFile pkgs endpoints;
          }
        );
    };
in
{
  native = mkModule {
    name = "smg";
    options.package = mkOption {
      type = types.package;
      description = ''
        Python environment providing the `smg` package, built with the
        flake's `mkUvEnv`, since nixpkgs lacks SMG.
      '';
    };
    config =
      context@{ cfg, argv, ... }:
      gateway.nativeService (
        context
        // {
          description = "SMG model gateway";
          script = credentialCommand ''"$CREDENTIALS_DIRECTORY"'' cfg.credentials (
            [ (lib.getExe' cfg.package "python") ] ++ launcher ++ argv
          );
        }
      );
  };

  quadlet = mkModule {
    name = "smg-quadlet";
    options.image = quadlet.imageOption // {
      example = "docker.io/lightseekorg/smg:1.13.0";
    };
    discoveryPath = containerDiscoveryFile;
    config =
      context@{
        cfg,
        argv,
        discovery,
        ...
      }:
      gateway.quadletContainer (
        context
        // {
          script = credentialCommand quadlet.credentialDirectory cfg.credentials (
            [ "python3" ] ++ launcher ++ argv
          );
          volumes = [ "${discovery}:${containerDiscoveryFile}:ro" ];
        }
      );
  };
}
