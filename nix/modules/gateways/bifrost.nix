# Bifrost in front of every listed endpoint, as a native service under
# `services.llmhop.gateway.bifrost` and as a Quadlet container under
# `services.llmhop.gateway.bifrost-quadlet`.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  gateway = import ./shared.nix lib;

  unit = "bifrost";
  displayName = "Bifrost";

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

  settingsOption = mkOption {
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

  options = gateway.options displayName // {
    credentials = util.credentialsOption;
    settings = settingsOption;
  };

  defaultSettings = endpoints: {
    "$schema" = lib.mkDefault "https://www.getbifrost.ai/schema";
    providers = lib.mapAttrs (_: endpoints: { keys = map key endpoints; }) (
      lib.groupBy (e: provider e.engine) endpoints
    );
  };

  configFile = pkgs: settings: (pkgs.formats.json { }).generate "bifrost-config.json" settings;
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
      name = "bifrost";
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
              Package providing `bifrost-http` as its main program, taken from
              Bifrost's own flake, since nixpkgs lacks it.
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
          { services.llmhop.gateway.${name}.settings = defaultSettings endpoints; }
          (gateway.nativeService {
            inherit utils cfg unit;
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
                (configFile pkgs cfg.settings)
                "/var/lib/${unit}/config.json"
              ];
              StateDirectory = unit;
              StateDirectoryMode = "0700";
            };
          })
        ]
      );
    };

  quadlet =
    sectionType:
    { config, pkgs, ... }:
    let
      name = "bifrost-quadlet";
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
              example = "docker.io/maximhq/bifrost:v2.3.2";
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
          { services.llmhop.gateway.${name}.settings = defaultSettings endpoints; }
          (gateway.quadletContainer {
            inherit
              config
              name
              cfg
              unit
              ;
            # `U` hands the app directory to whatever user the container runs as.
            volumes = [
              "/var/lib/${unit}:/app/data:U"
              "${configFile pkgs cfg.settings}:/app/data/config.json:ro"
            ];
            environment = {
              APP_DIR = "/app/data";
              APP_HOST = cfg.host;
              APP_PORT = toString cfg.port;
            };
            serviceConfig.StateDirectory = unit;
          })
        ]
      );
    };
}
