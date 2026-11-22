# The submodule of a model of a backend.
lib:
let
  inherit (lib) mkOption types;
  util = import ../../lib lib;
  inherit (import ./options.nix lib) workloadOptions watermarkType settingsRendering;
in
{
  # Submodule of a model of the backend `cfg` of `engine`.
  modelModule =
    {
      engine,
      llmhop,
      cfg,
    }:
    {
      name,
      config,
      ...
    }:
    {
      options =
        workloadOptions {
          inherit
            engine
            llmhop
            cfg
            name
            config
            ;
          noun = "model";
          socketCapable = engine.socketSettings != null;
        }
        // {
          model = mkOption {
            type = types.str;
            example = engine.modelExample;
            description = ''
              ${engine.modelDescription}
              Natively, the fetcher downloads a repository, while an absolute
              path is served as is, in a container one inside it.
            '';
          };
          extraRepositories = mkOption {
            type = with types; listOf str;
            default = [ ];
            example = [ "Qwen/Qwen3-0.6B" ];
            description = ''
              Further repositories the fetcher downloads beside `model`, such as a
              speculative draft model that `settings` reference, since an
              offline server cannot download them itself.
            '';
          };
          settings = mkOption {
            type = with types; attrsOf json;
            default = { };
            description = ''
              CLI flags of this model's server, over the backend's
              `modelSettings`. They must not set the listener or the flags
              derived from the other options, such as the served name.
              ${settingsRendering engine}
            '';
          };
          native.devices = mkOption {
            type = with types; nullOr (listOf str);
            default = cfg.native.devices;
            defaultText = lib.literalExpression "config.services.llmhop.${engine.name}.native.devices";
            example = [
              "/dev/kfd"
              "char-drm"
            ];
            description = "Devices this model's service may access, replacing the backend's `native.devices`. ${util.runtimeOnly "native"}";
          };
          container = {
            devices = mkOption {
              type = with types; listOf str;
              default = cfg.container.devices;
              defaultText = lib.literalExpression "config.services.llmhop.${engine.name}.container.devices";
              example = [ "nvidia.com/gpu=GPU-8932f937-d72c-4106-c12f-20bd9faed9f6" ];
              description = ''Devices exposed to this model's container, replacing the backend's `container.devices`. Prefer the UUID names of `hardware.nvidia-container-toolkit.device-name-strategy = "uuid"` over indices, which may change between boots. ${util.runtimeOnly "container"}'';
            };
            shmSize = mkOption {
              type = types.str;
              default = "32g";
              example = "64g";
              description = ''
                Size of the container's private `/dev/shm` tmpfs, which
                PyTorch uses for tensor-parallel inference.
                ${util.runtimeOnly "container"}
              '';
            };
          };
        }
        // lib.optionalAttrs engine.revisions {
          revision = mkOption {
            type = with types; nullOr str;
            default = null;
            example = "main";
            description = ''
              Branch, tag or commit of `model` that the fetcher downloads and the
              server loads. `null` follows the default branch, so `fetch.schedule`
              picks up upstream changes, while a commit pins the model.
            '';
          };
        }
        // lib.optionalAttrs engine.dataParallel {
          dataParallelSize = mkOption {
            type = types.ints.between 1 256;
            default = 1;
            example = 2;
            description = ''
              Number of data-parallel ranks of the server, each a full copy of
              the model on its own GPUs, rendered as `--data-parallel-size` so
              that `settings` must not set it.
              The server balances requests over its ranks, while the gateway
              pins those of a conversation to one rank for its prefix cache.
            '';
          };
        }
        // lib.optionalAttrs (engine.loras != null) {
          loras = mkOption {
            type = with types; attrsOf str;
            default = { };
            example."qwen3-8b-sql" = "org/qwen3-8b-sql-lora";
            description = ''
              LoRA adapters served beside `model`, each a Hugging Face repository
              by the model name clients request it under, which the fetcher
              downloads and the gateway routes to this model.
            '';
          };
        }
        // lib.optionalAttrs (engine.watermark != null) {
          watermark = mkOption {
            type = types.nullOr (watermarkType engine);
            default = null;
            example.settings = engine.watermark.example;
            description = ''
              Watermark of this model's output, its settings and the
              credential holding its key.
            '';
          };
        };
      config.settings = lib.mapAttrs (_: lib.mkDefault) cfg.modelSettings;
    };
}
