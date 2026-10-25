{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.llama-cpp-quadlet;

  inherit (import ../lib lib) quadlet;

  workerPort = 8080;
in
{
  options.services.llmhop.llama-cpp-quadlet =
    quadlet.mkOptions {
      backend = "llama-cpp-quadlet";
      inherit cfg config;
      defaultImage = "ghcr.io/ggml-org/llama.cpp";
      tagExample = "server-cuda";
    }
    // {
      enable = lib.mkEnableOption "llama.cpp model serving via Quadlet, fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            quadlet.mkModelSubmodule {
              backend = "llama-cpp-quadlet";
              inherit cfg;
              socketDirectory = config.services.llmhop.socketDirectory;
              portDescription = ''
                Loopback host port of the container's llama.cpp API.
                Must be unique per model.
              '';
              modelDescription = ''
                Hugging Face repository with an optional quantization tag, passed
                as `--hf-repo`, or an absolute path to a GGUF file inside the
                container, passed as `--model`.
              '';
              modelExample = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
            }
          )
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
          }
        '';
        description = ''
          Models served by `llama-server` containers. Each entry produces one
          `llama-cpp-<name>` unit and uses the attribute name as its llmhop
          routing key and llama.cpp `--alias`.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (quadlet.mkConfig {
        backend = "llama-cpp-quadlet";
        inherit cfg config pkgs;
      })
      (quadlet.mergeWorkloads (
        quadlet.mkModelWorkloads {
          backend = "llama-cpp-quadlet";
          inherit
            cfg
            config
            pkgs
            workerPort
            ;
        }
      ))
    ]
  );
}
