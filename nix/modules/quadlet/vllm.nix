{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.vllm-quadlet;

  inherit (import ../lib lib) enabled quadlet;
  detector = (import ../detectors/vllm.nix lib).quadlet;
  watermark = import ../watermark.nix lib;

  # Internal port every worker binds to inside its container.
  workerPort = 8000;

  detectors = enabled cfg.detectors;
in
{
  options.services.llmhop.vllm-quadlet =
    quadlet.mkOptions {
      backend = "vllm-quadlet";
      inherit cfg config;
      defaultImage = "docker.io/vllm/vllm-openai";
    }
    // {
      enable = lib.mkEnableOption "vLLM model serving via Quadlet, fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule [
            (quadlet.mkModelSubmodule {
              backend = "vllm-quadlet";
              inherit cfg;
              socketDirectory = config.services.llmhop.socketDirectory;
              portDescription = ''
                Loopback host port of the container's vLLM API.
                Must be unique per model.
              '';
              modelDescription = "Hugging Face repository passed to `vllm serve`, or an absolute path inside the container.";
              modelExample = "Qwen/Qwen2.5-7B-Instruct";
            })
            (watermark.module { optional = true; })
          ]
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen2-5-7b" = {
              model = "Qwen/Qwen2.5-7B-Instruct";
            };
            "llama-3-8b" = {
              model = "meta-llama/Meta-Llama-3-8B-Instruct";
              settings.max-model-len = 8192;
            };
          }
        '';
        description = ''
          Models to serve.
          Each entry produces one quadlet container; the attribute name is the routing key.
          Enabled entries are sorted by ascending `name`.
        '';
      };

      detectors = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            detector.mkSubmodule { socketDirectory = config.services.llmhop.socketDirectory; }
          )
        );
        default = { };
        description = "Standalone watermark detection containers.";
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (quadlet.mkConfig (
        {
          backend = "vllm-quadlet";
          inherit cfg config pkgs;
        }
        // detector.registry detectors
      ))
      { assertions = watermark.assertions "vllm-quadlet" cfg; }
      # A watermarking model runs `mkVllmWatermark`'s script, mounted into the
      # image, instead of the image's `vllm serve` entrypoint.
      (quadlet.mergeWorkloads (
        quadlet.mkModelWorkloads {
          backend = "vllm-quadlet";
          inherit
            cfg
            config
            pkgs
            workerPort
            ;
          container =
            model:
            let
              script = lib.optionalAttrs (model.watermark != null) (watermark.container watermark.source "serve");
            in
            script
            // {
              arguments = (script.arguments or [ ]) ++ [ model.model ];
              managed = watermark.flags model.watermark;
            };
        }
        ++ map (
          d:
          detector.mkWorkload {
            inherit cfg config pkgs;
            detector = d;
          }
        ) (lib.attrValues detectors)
      ))
    ]
  );
}
