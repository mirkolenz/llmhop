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
  inherit (llmhopLib) cliOptionFormat flipBoolFlags;
  inherit (llmhopLib.systemd)
    mkConfig
    mkUvModelSubmodule
    mkUvOptions
    mkUvServices
    ;

  # vLLM uses argparse `BooleanOptionalAction` (paired `--key` / `--no-key`)
  # for every `bool`-typed option, so `flipBoolFlags` lets `key = false`
  # render as `--no-key`.
  renderArgs = attrs: lib.cli.toCommandLine (cliOptionFormat null) (flipBoolFlags attrs);
in
{
  options.services.llmhop.vllm =
    mkUvOptions {
      backend = "vllm";
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
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig {
        backend = "vllm";
        inherit cfg;
      })
      {
        # `mkUvServices` owns the shared GPU/cache/hardening service body; vLLM
        # supplies only its `vllm serve <model>` invocation (a real `bin/vllm`
        # console script) and its own cache-root env vars.
        systemd.services = mkUvServices {
          serviceName = "vllm";
          inherit cfg pkgs utils;
          extraEnvironment = cacheBase: {
            VLLM_CACHE_ROOT = "${cacheBase}/vllm";
            OUTLINES_CACHE_DIR = "${cacheBase}/outlines";
          };
          execStart =
            model:
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
              // cfg.modelSettings
              // model.settings
            );
        };
      }
    ]
  );
}
