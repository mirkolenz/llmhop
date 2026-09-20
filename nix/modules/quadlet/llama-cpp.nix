{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.llama-cpp-quadlet;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib)
    credentialDirectory
    renderCliArgsShell
    resolveCredentialRefs
    sortedModels
    ;
  inherit (llmhopLib.quadlet)
    mkConfig
    mkContainerArgs
    mkModelSubmodule
    mkOptions
    mkStartupOrdering
    mkWorker
    ;

  renderArgs = renderCliArgsShell "llama-cpp-quadlet";
  workerPort = 8080;
  models = sortedModels cfg;

  mkContainer =
    index: model:
    lib.nameValuePair "llama-cpp-${model.name}" (mkWorker {
      inherit cfg;
      inherit (model) credentials;
      overrides = model.quadlet;
      healthPort = workerPort;
      containerConfig =
        mkContainerArgs {
          backend = "llama-cpp-quadlet";
          inherit cfg model;
        }
        // {
          PublishPort = [ "127.0.0.1:${toString model.port}:${toString workerPort}" ];
          Exec = renderArgs (
            resolveCredentialRefs credentialDirectory model.credentials (
              {
                host = "0.0.0.0";
                port = workerPort;
                alias = model.name;
              }
              // cfg.modelSettings
              // model.settings
            )
          );
        };
      unitConfig = mkStartupOrdering {
        inherit
          config
          cfg
          models
          index
          ;
        prefix = "llama-cpp";
      };
    });
in
{
  options.services.llmhop.llama-cpp-quadlet =
    mkOptions {
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
          lib.types.submodule {
            imports = [
              (mkModelSubmodule {
                backend = "llama-cpp-quadlet";
                inherit cfg;
                hasModel = false;
              })
            ];
            options.port = lib.mkOption {
              type = lib.types.port;
              description = ''
                Loopback host port forwarded to the container's llama.cpp API.
                Must be unique per model.
              '';
            };
          }
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
      (mkConfig {
        backend = "llama-cpp-quadlet";
        inherit cfg config pkgs;
      })
      {
        virtualisation.quadlet.containers = lib.listToAttrs (lib.imap0 mkContainer models);
      }
    ]
  );
}
