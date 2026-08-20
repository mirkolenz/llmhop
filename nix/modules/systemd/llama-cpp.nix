{
  lib,
  config,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.llmhop.llama-cpp;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib) enabledModels renderCliArgs;
  inherit (llmhopLib.systemd)
    mkConfig
    mkModelSubmodule
    mkOptions
    mkWorker
    ncclServiceConfig
    ncclEnvironment
    gpuServiceConfig
    gpuCacheEnvironment
    ;

  renderArgs = renderCliArgs "llama-cpp";

  mkService =
    model:
    let
      subdir = "llama-cpp/${model.name}";
      cacheBase = "/var/cache/${subdir}";
    in
    lib.nameValuePair "llama-cpp-${model.name}" (
      {
        description = "llama.cpp server for ${model.name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        environment = {
          LLAMA_CACHE = cacheBase;
        }
        // gpuCacheEnvironment cacheBase
        // ncclEnvironment
        // cfg.environment
        // model.environment;
      }
      // mkWorker {
        inherit (cfg) openFilesLimit;
        inherit pkgs utils;
        # llama-server serves `/health` as 503 while the model loads, 200 once it
        # can generate, so the unit only goes active when it is servable.
        healthPort = model.port;
        execStart = [
          (lib.getExe' cfg.package "llama-server")
        ]
        ++ renderArgs (
          {
            host = "127.0.0.1";
            port = model.port;
            alias = model.name;
          }
          // cfg.modelSettings
          // model.settings
        );
        serviceConfig = {
          KillSignal = "SIGINT";
          Restart = "on-failure";
          TasksMax = 4096;
          UMask = "0077";

          # DynamicUser + per-unit StateDirectory/CacheDirectory pin the
          # ephemeral UID across restarts and own writable paths under
          # `ProtectSystem = "strict"`. The `parent/leaf` form shares
          # `/var/{lib,cache}/llama-cpp/` across models — only the leaf
          # is owned by the DynamicUser; parents stay root-owned.
          DynamicUser = true;
          StateDirectory = subdir;
          CacheDirectory = subdir;
          WorkingDirectory = "/var/lib/${subdir}";

          EnvironmentFile =
            lib.optional (cfg.environmentFile != null) cfg.environmentFile
            ++ lib.optional (model.environmentFile != null) model.environmentFile;
        }
        # GPU relaxations, then NCCL/RCCL's — which also cover llama-server's own
        # listener, denied by `SocketBindDeny = "any"` otherwise — then the
        # per-model escape hatch.
        // gpuServiceConfig
        // ncclServiceConfig
        // model.serviceConfig;
      }
    );
in
{
  options.services.llmhop.llama-cpp = mkOptions { backend = "llama-cpp"; } // {
    enable = lib.mkEnableOption "llama.cpp model serving via systemd, fronted by llmhop";

    package = lib.mkPackageOption pkgs "llama-cpp" { };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          imports = [ (mkModelSubmodule { backend = "llama-cpp"; }) ];
          options.port = lib.mkOption {
            type = lib.types.port;
            description = ''
              Loopback host port that llama-server binds to. Must be unique per
              enabled model; the gateway (llmhop) reaches each backend at
              `http://127.0.0.1:<port>`.
            '';
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          "qwen3-8b" = {
            port = 18001;
            settings = {
              hf-repo = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
              temperature = 1.0;
              top-k = 20;
            };
            # Pin this model to a specific GPU. The right variable depends on
            # the llama.cpp build: CUDA_VISIBLE_DEVICES for CUDA,
            # HIP_VISIBLE_DEVICES / ROCR_VISIBLE_DEVICES for ROCm,
            # GGML_VK_VISIBLE_DEVICES for Vulkan, ZE_AFFINITY_MASK for SYCL.
            environment.CUDA_VISIBLE_DEVICES = "0";
          };
        }
      '';
      description = ''
        Models to serve.
        Each entry produces one systemd service running `llama-server`; the
        attribute name is the routing key surfaced through llmhop and the OpenAI
        `model` field.

        GPU selection is done via build-specific environment variables on
        `environment` (top-level or per-model), since llama.cpp runs as a host
        process — no CDI involved. Common variables: `CUDA_VISIBLE_DEVICES`
        (CUDA), `HIP_VISIBLE_DEVICES` / `ROCR_VISIBLE_DEVICES` (ROCm),
        `GGML_VK_VISIBLE_DEVICES` (Vulkan), `ZE_AFFINITY_MASK` (SYCL).
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig {
        backend = "llama-cpp";
        inherit cfg;
      })
      {
        systemd.services = lib.mapAttrs' (_: mkService) (enabledModels cfg);
      }
    ]
  );
}
