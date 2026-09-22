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
    identityConfig
    renderCliArgs
    systemd
    withManagedSettings
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
          Each enabled entry produces one systemd service named `vllm-<name>`;
          the attribute name is the routing key surfaced through llmhop as the
          OpenAI `model` field.
          Enabled entries are sorted by ascending `port`.
        '';
      };

      detectors = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule (detector.mkNativeSubmodule { inherit cfg pkgs; }));
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
      # The workers run as a real user rather than `DynamicUser`; see the module
      # internals documentation.
      (identityConfig {
        backend = "vllm";
        inherit cfg;
      })
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
            execStart =
              model: settings:
              [
                (lib.getExe' model.package "vllm")
                "serve"
                model.model
              ]
              ++ renderCliArgs "vllm" (
                withManagedSettings {
                  served-model-name = model.name;
                  host = "127.0.0.1";
                  port = model.port;
                } settings
              );
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
