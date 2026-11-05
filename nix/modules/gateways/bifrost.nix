# Bifrost in front of every listed endpoint under
# `services.llmhop.gateway.bifrost`.
sectionType:
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  gateway = import ./shared.nix lib;

  name = "bifrost";
  displayName = "Bifrost";
  cfg = config.services.llmhop.gateway.${name};
  endpoints = gateway.listedEndpoints config;

  # Bifrost has no llama.cpp provider, but its vLLM one serves any
  # OpenAI-compatible server and, like SGLang's, takes a URL per key, so each
  # endpoint becomes one key of its engine's provider.
  provider = e: if e.engine == "sglang" then "sgl" else "vllm";
  key =
    e:
    {
      inherit (e) name;
      value = "";
      models = [ e.name ];
      weight = 1;
    }
    // (
      if provider e == "sgl" then
        { sgl_key_config.url = e.url; }
      else
        {
          vllm_key_config = {
            inherit (e) url;
            model_name = e.name;
          };
        }
    );

  configFile = (pkgs.formats.json { }).generate "bifrost-config.json" cfg.settings;
in
{
  options.services.llmhop.gateway.${name} =
    gateway.options {
      inherit config sectionType displayName;
      image = util.imageOption // {
        example = "docker.io/maximhq/bifrost:v2.3.2";
      };
    }
    // gateway.tcpOptions displayName
    // {
      package = mkOption {
        type = types.package;
        description = ''
          Package providing `bifrost-http` as its main program, taken from
          Bifrost's own flake, since nixpkgs lacks it.
          Only used if `runtime` is `"native"`.
        '';
      };
      settings = mkOption {
        type = with types; attrsOf json;
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
    };

  config = lib.mkIf (config.services.llmhop.gateway.type == name) (
    lib.mkMerge [
      (gateway.tcpConfig { inherit name cfg endpoints; })
      {
        services.llmhop.gateway.${name}.settings = {
          "$schema" = lib.mkDefault "https://www.getbifrost.ai/schema";
          providers = lib.mapAttrs (_: endpoints: { keys = map key endpoints; }) (
            lib.groupBy provider endpoints
          );
        };
      }
      (gateway.unit {
        inherit config utils name;
        description = "Bifrost model gateway";
        command = [
          (lib.getExe cfg.package)
          "-host"
          cfg.host
          "-port"
          cfg.port
          "-app-dir"
          "/var/lib/${name}"
        ];
        serviceConfig = {
          ExecStartPre = utils.escapeSystemdExecArgs [
            (lib.getExe' pkgs.coreutils "install")
            "-m"
            "600"
            configFile
            "/var/lib/${name}/config.json"
          ];
          StateDirectory = name;
          StateDirectoryMode = "0700";
        };
        # `U` hands the app directory to whatever user the container runs as.
        container = {
          volumes = [
            "/var/lib/${name}:/app/data:U"
            "${configFile}:/app/data/config.json:ro"
          ];
          environment = {
            APP_DIR = "/app/data";
            APP_HOST = cfg.host;
            APP_PORT = toString cfg.port;
          };
          serviceConfig.StateDirectory = name;
        };
      })
    ]
  );
}
