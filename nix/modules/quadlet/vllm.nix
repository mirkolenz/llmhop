{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.vllm-quadlet;

  inherit (import ../lib.nix lib) enabled quadlet;
  detector = import ../detector.nix lib;

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
      defaultCacheDir = "/var/cache/vllm";
    }
    // {
      enable = lib.mkEnableOption "vLLM model serving via Quadlet, fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            quadlet.mkModelSubmodule {
              backend = "vllm-quadlet";
              inherit cfg;
              portDescription = ''
                Loopback host port forwarded to the container's vLLM API.
                Must be unique per model.
              '';
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
          Each entry produces one quadlet container; the attribute name is the routing key.
          Enabled entries are sorted by ascending `port`.
        '';
      };

      detectors = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule detector.mkQuadletSubmodule);
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
      {
        virtualisation.quadlet.containers =
          quadlet.mkModelContainers {
            backend = "vllm-quadlet";
            inherit cfg config workerPort;
            arguments = model: [ model.model ];
            settings = model: {
              served-model-name = model.name;
              host = "0.0.0.0";
              port = workerPort;
            };
          }
          // lib.listToAttrs (
            map (
              d:
              detector.mkQuadletContainer {
                inherit cfg;
                detector = d;
              }
            ) (lib.attrValues detectors)
          );
      }
    ]
  );
}
