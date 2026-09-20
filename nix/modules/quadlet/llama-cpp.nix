{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.llama-cpp-quadlet;

  inherit (import ../lib.nix lib) quadlet;

  workerPort = 8080;
in
{
  options.services.llmhop.llama-cpp-quadlet =
    quadlet.mkOptions {
      backend = "llama-cpp-quadlet";
      inherit cfg config;
      defaultImage = "ghcr.io/ggml-org/llama.cpp";
      defaultCacheDir = "/var/cache/llama-cpp";
      defaultContainerCacheDir = "/root/.cache/llama.cpp";
      defaultCacheEnvVar = "LLAMA_CACHE";
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
              hasModel = false;
              portDescription = ''
                Loopback host port forwarded to the container's llama.cpp API.
                Must be unique per model.
              '';
            }
          )
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen3-8b" = {
              port = 18001;
              settings.hf-repo = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
            };
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
      {
        virtualisation.quadlet.containers = quadlet.mkModelContainers {
          backend = "llama-cpp-quadlet";
          inherit cfg config workerPort;
          settings = model: {
            host = "0.0.0.0";
            port = workerPort;
            alias = model.name;
          };
        };
      }
    ]
  );
}
