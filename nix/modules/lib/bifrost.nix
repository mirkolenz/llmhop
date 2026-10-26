# Bifrost in front of every listed endpoint, as a native service under
# `services.llmhop.gateway.bifrost` and as a Quadlet container under
# `services.llmhop.gateway.bifrost-quadlet`.
lib:
{
  gateway,
  quadlet,
}:
let
  inherit (lib) mkOption types;

  unit = "bifrost";

  # Bifrost has no llama.cpp provider, but its vLLM one serves any
  # OpenAI-compatible server and, like SGLang's, takes a URL per key, so each
  # endpoint becomes one key of its engine's provider.
  provider = engine: if engine == "sglang" then "sgl" else "vllm";
  key =
    e:
    {
      inherit (e) name;
      value = "";
      models = [ e.name ];
      weight = 1;
    }
    // (
      if provider e.engine == "sgl" then
        { sgl_key_config.url = e.url; }
      else
        {
          vllm_key_config = {
            inherit (e) url;
            model_name = e.name;
          };
        }
    );

  # The module of the gateway `name`, whose `options` extend the shared ones
  # and whose `config` runs Bifrost with its `configFile`.
  mkModule =
    {
      name,
      options,
      config,
    }:
    gateway.mkModule {
      inherit name unit options;
      displayName = "Bifrost";
      settings =
        pkgs:
        mkOption {
          inherit (pkgs.formats.json { }) type;
          default = { };
          example = {
            encryption_key = "env.BIFROST_ENCRYPTION_KEY";
            governance.virtual_keys = [
              {
                id = "default";
                name = "default";
                value = "env.BIFROST_VIRTUAL_KEY";
                is_active = true;
              }
            ];
          };
          description = ''
            Bifrost's `config.json`, with every listed model as a key of its
            `vllm` or `sgl` provider. Changes from its web UI or API persist
            until the matching section of this file changes, while
            `source_of_truth = "config.json"` prunes them and
            `config_store.enabled = false` disables them. Use upstream `env.`
            references with `environmentFile` for secrets.
          '';
        };
      defaults =
        { endpoints, ... }:
        {
          "$schema" = lib.mkDefault "https://www.getbifrost.ai/schema";
          providers = lib.mapAttrs (_: endpoints: { keys = map key endpoints; }) (
            lib.groupBy (e: provider e.engine) endpoints
          );
        };
      config =
        context@{ pkgs, cfg, ... }:
        config (
          context
          // {
            configFile = (pkgs.formats.json { }).generate "bifrost-config.json" cfg.settings;
          }
        );
    };
in
{
  native = mkModule {
    name = "bifrost";
    options.package = mkOption {
      type = types.package;
      description = ''
        Package providing `bifrost-http` as its main program, taken from
        Bifrost's own flake, since nixpkgs lacks it.
      '';
    };
    config =
      context@{
        pkgs,
        utils,
        cfg,
        configFile,
        ...
      }:
      gateway.nativeService (
        context
        // {
          description = "Bifrost model gateway";
          command = [
            (lib.getExe cfg.package)
            "-host"
            cfg.host
            "-port"
            cfg.port
            "-app-dir"
            "/var/lib/${unit}"
          ];
          serviceConfig = {
            ExecStartPre = utils.escapeSystemdExecArgs [
              (lib.getExe' pkgs.coreutils "install")
              "-m"
              "600"
              configFile
              "/var/lib/${unit}/config.json"
            ];
            StateDirectory = unit;
            StateDirectoryMode = "0700";
          };
        }
      );
  };

  quadlet = mkModule {
    name = "bifrost-quadlet";
    options.image = quadlet.imageOption // {
      example = "docker.io/maximhq/bifrost:v2.3.2";
    };
    config =
      context@{ cfg, configFile, ... }:
      gateway.quadletContainer (
        context
        // {
          # `U` hands the app directory to whatever user the container runs as.
          volumes = [
            "/var/lib/${unit}:/app/data:U"
            "${configFile}:/app/data/config.json:ro"
          ];
          environment = {
            APP_DIR = "/app/data";
            APP_HOST = cfg.host;
            APP_PORT = toString cfg.port;
          };
          serviceConfig.StateDirectory = unit;
        }
      );
  };
}
