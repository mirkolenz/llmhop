{
  lib,
  config,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.llmhop.vllm;

  inherit (import ../lib.nix lib)
    enabled
    systemd
    ;
  detector = import ../detector.nix lib;

  detectors = enabled cfg.detectors;
in
{
  options.services.llmhop.vllm =
    systemd.mkUvOptions {
      backend = "vllm";
      inherit cfg;
      displayName = "vLLM";
      packageEntry = "the `vllm` CLI at `bin/vllm`";
    }
    // {
      enable = lib.mkEnableOption "vLLM model serving via systemd (native host process), fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            systemd.mkUvModelSubmodule {
              backend = "vllm";
              inherit cfg;
              socketDirectory = config.services.llmhop.socketDirectory;
              modelArgument = "the `vllm serve` positional argument";
              modelExample = "Qwen/Qwen2.5-7B-Instruct";
            }
          )
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
          Each enabled entry produces one systemd service named `vllm-<name>`;
          the attribute name is the routing key surfaced through llmhop as the
          OpenAI `model` field.
          Enabled entries are sorted by ascending `name`.
        '';
      };

      detectors = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            detector.mkNativeSubmodule {
              inherit cfg pkgs;
              socketDirectory = config.services.llmhop.socketDirectory;
            }
          )
        );
        default = { };
        description = "Standalone watermark detection services.";
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (systemd.mkConfig (
        {
          backend = "vllm";
          inherit cfg;
        }
        // detector.registry detectors
      ))
      {
        # `mkUvServices` owns the shared GPU/cache/hardening service body; vLLM
        # supplies only its `vllm serve <model>` invocation (a real `bin/vllm`
        # console script) and its own cache-root env vars.
        systemd.services =
          systemd.mkUvServices {
            serviceName = "vllm";
            inherit cfg pkgs utils;
            environment = cacheBase: {
              VLLM_CACHE_ROOT = "${cacheBase}/vllm";
              OUTLINES_CACHE_DIR = "${cacheBase}/outlines";
            };
            command = model: [
              (lib.getExe' model.package "vllm")
              "serve"
              model.model
            ];
            settings = model: { served-model-name = model.name; };
          }
          // lib.listToAttrs (
            map (
              d:
              detector.mkNativeService {
                inherit cfg pkgs utils;
                detector = d;
              }
            ) (lib.attrValues detectors)
          );
      }
    ]
  );
}
