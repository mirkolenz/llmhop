{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.vllm-quadlet;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib) cliOptionFormat flipBoolFlags sortedModels;
  inherit (llmhopLib.quadlet)
    mkConfig
    mkContainerArgs
    mkModelSubmodule
    mkOptions
    mkWorker
    ;

  # vLLM uses argparse `BooleanOptionalAction` (paired `--key` / `--no-key`)
  # for every `bool`-typed option, so `flipBoolFlags` lets `key = false`
  # render as `--no-key`. A few manual `store_true` flags (`--headless`,
  # `--grpc`, `--disable-log-stats`, `--aggregate-engine-logging`) have no
  # `--no-X` form — omit them instead of writing `... = false`.
  renderArgs = attrs: lib.cli.toCommandLineShell (cliOptionFormat "=") (flipBoolFlags attrs);

  # Internal port every worker binds to inside its container.
  workerPort = 8000;

  # Sort by port so the After= chain is deterministic across rebuilds.
  models = sortedModels cfg;

  mkContainer =
    i: model:
    lib.nameValuePair "vllm-${model.name}" (mkWorker {
      inherit cfg;
      healthPort = workerPort;
      containerConfig =
        (mkContainerArgs {
          backend = "vllm-quadlet";
          inherit cfg model;
        })
        // {
          PublishPort = [ "127.0.0.1:${toString model.port}:${toString workerPort}" ];
          Exec = "${lib.escapeShellArg model.model} ${
            renderArgs (
              {
                served-model-name = model.name;
                host = "0.0.0.0";
                port = workerPort;
              }
              // cfg.modelSettings
              // model.settings
            )
          }";
        };
      # Chain ascending so each worker finishes GPU-memory profiling before the next starts.
      unitConfig = {
        After =
          lib.optional (cfg.startupOrdering && i > 0)
            "${
              config.virtualisation.quadlet.containers."vllm-${(lib.elemAt models (i - 1)).name}".serviceName
            }.service";
      };
    });
in
{
  options.services.llmhop.vllm-quadlet =
    mkOptions {
      backend = "vllm-quadlet";
      inherit cfg config;
      defaultImage = "docker.io/vllm/vllm-openai";
      defaultCacheDir = "/var/cache/vllm";
      tagExample = "v0.11.0";
    }
    // {
      enable = lib.mkEnableOption "vLLM model serving via Quadlet, fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            imports = [
              (mkModelSubmodule {
                backend = "vllm-quadlet";
                inherit cfg;
              })
            ];
            options.port = lib.mkOption {
              type = lib.types.port;
              description = ''
                Loopback host port forwarded to the container's vLLM API.
                Must be unique per model.
              '';
            };
          }
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen2-5-7b" = {
              model = "Qwen/Qwen2.5-7B-Instruct";
              port = 18001;
            };
            "llama-3-8b" = {
              model = "meta-llama/Meta-Llama-3-8B-Instruct";
              port = 18002;
              settings.max-model-len = 8192;
            };
          }
        '';
        description = ''
          Models to serve.
          Each entry produces one quadlet container; the attribute name is the routing key.
          Enabled entries are sorted by ascending `port`.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig {
        backend = "vllm-quadlet";
        inherit cfg config pkgs;
      })
      {
        virtualisation.quadlet.containers = lib.listToAttrs (lib.imap0 mkContainer models);
      }
    ]
  );
}
