{
  lib,
  config,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.llmhop.llama-cpp;

  inherit (import ../lib.nix lib) renderCliArgs systemd withManagedSettings;
in
{
  options.services.llmhop.llama-cpp = systemd.mkOptions { backend = "llama-cpp"; } // {
    enable = lib.mkEnableOption "llama.cpp model serving via systemd, fronted by llmhop";

    package = lib.mkPackageOption pkgs "llama-cpp" { };

    models = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          systemd.mkModelSubmodule {
            backend = "llama-cpp";
            portDescription = ''
              Loopback host port that llama-server binds to. Must be unique per
              enabled model; the gateway (llmhop) reaches each backend at
              `http://127.0.0.1:<port>`.
            '';
          }
        )
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
      (systemd.mkConfig {
        backend = "llama-cpp";
        inherit cfg;
      })
      {
        # llama.cpp compiles nothing at runtime, so it keeps `DynamicUser`: the
        # `parent/leaf` State/CacheDirectory form shares `/var/{lib,cache}/llama-cpp/`
        # across models with only the leaf owned by the ephemeral UID.
        systemd.services = systemd.mkServices {
          serviceName = "llama-cpp";
          inherit cfg pkgs utils;
          environment = cacheBase: { LLAMA_CACHE = cacheBase; };
          serviceConfig.DynamicUser = true;
          # llama-server serves `/health` as 503 while the model loads, 200 once
          # it can generate, so the unit only goes active when it is servable.
          execStart =
            model: settings:
            [ (lib.getExe' cfg.package "llama-server") ]
            ++ renderCliArgs "llama-cpp" (
              withManagedSettings {
                host = "127.0.0.1";
                port = model.port;
                alias = model.name;
              } settings
            );
        };
      }
    ]
  );
}
