{
  lib,
  config,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.llmhop.vllm;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib)
    enabled
    identityConfig
    renderCliArgs
    resolveCredentialRefs
    systemdCredentialDirectory
    vllmDetectorOptions
    vllmDetectorRegistry
    vllmDetectorSettings
    vllmDetectorUnit
    ;
  inherit (llmhopLib.systemd)
    mkConfig
    mkUvModelSubmodule
    mkUvOptions
    mkUvService
    mkUvServices
    ;

  renderArgs = renderCliArgs "vllm";

  detectors = enabled cfg.detectors;

  # An auxiliary service rather than a model worker: no GPU device access, no
  # `StateDirectory`, and readiness from FastAPI's `/openapi.json` because the
  # upstream script serves no health endpoint.
  mkDetectorService =
    detector:
    let
      unitName = vllmDetectorUnit detector;
    in
    mkUvService {
      inherit
        unitName
        cfg
        pkgs
        utils
        ;
      description = "vLLM watermark detector ${detector.name}";
      subdir = "vllm/detector-${detector.name}";
      workload = detector;
      healthPath = "/openapi.json";
      execStart = [
        (lib.getExe' detector.package "python")
        detector.script
      ]
      ++ renderArgs (
        resolveCredentialRefs (systemdCredentialDirectory unitName) detector.credentials (
          vllmDetectorSettings "127.0.0.1" detector.port detector
        )
      );
    };
in
{
  options.services.llmhop.vllm =
    mkUvOptions {
      backend = "vllm";
      inherit cfg;
      displayName = "vLLM";
      packageEntry = "the `vllm` CLI at `bin/vllm`";
    }
    // {
      enable = lib.mkEnableOption "vLLM model serving via systemd (native host process), fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (mkUvModelSubmodule {
            backend = "vllm";
            inherit cfg;
            modelArgument = "the `vllm serve` positional argument";
            modelExample = "Qwen/Qwen2.5-7B-Instruct";
          })
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
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = vllmDetectorOptions name // {
                script = lib.mkOption {
                  type = lib.types.path;
                  example = lib.literalExpression ''
                    inputs.vllm-src + "/examples/basic/online_serving/watermark_detection_server.py"
                  '';
                  description = ''
                    Path to vLLM's upstream `watermark_detection_server.py`.
                    Pin it to the same revision as the package used by this detector.
                  '';
                };
                package = lib.mkOption {
                  type = lib.types.package;
                  default = cfg.package;
                  defaultText = lib.literalExpression "config.services.llmhop.vllm.package";
                  description = "vLLM Python environment used by this detector.";
                };
                serviceConfig = lib.mkOption {
                  type = with lib.types; attrsOf anything;
                  default = { };
                  description = "Additional `[Service]` settings for this detector.";
                };
                unitConfig = lib.mkOption {
                  type = with lib.types; attrsOf anything;
                  default = { };
                  description = "Additional `[Unit]` settings for this detector.";
                };
              };
            }
          )
        );
        default = { };
        description = "Standalone watermark detection services.";
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig (
        {
          backend = "vllm";
          inherit cfg;
        }
        // vllmDetectorRegistry detectors
      ))
      # The workers run as a real user rather than `DynamicUser`; see `mkUvWorker`.
      (identityConfig {
        backend = "vllm";
        inherit cfg;
      })
      {
        # `mkUvServices` owns the shared GPU/cache/hardening service body; vLLM
        # supplies only its `vllm serve <model>` invocation (a real `bin/vllm`
        # console script) and its own cache-root env vars.
        systemd.services =
          mkUvServices {
            serviceName = "vllm";
            inherit cfg pkgs utils;
            extraEnvironment = cacheBase: {
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
              ++ renderArgs (
                {
                  served-model-name = model.name;
                  host = "127.0.0.1";
                  port = model.port;
                }
                // settings
              );
          }
          // lib.mapAttrs' (_: mkDetectorService) detectors;
      }
    ]
  );
}
