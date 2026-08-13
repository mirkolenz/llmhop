{
  lib,
  config,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.llmhop.sglang;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib) cliOptionFormat;
  inherit (llmhopLib.systemd)
    mkConfig
    mkUvModelSubmodule
    mkUvOptions
    mkUvServices
    ;

  # SGLang uses plain `store_true` booleans paired as `--enable-X` /
  # `--disable-X`, so we deliberately do NOT apply `flipBoolFlags` here.
  # `true` collapses to `--key`, `null`/`false` are dropped; users write the
  # negated key explicitly (e.g. `disable-radix-cache = true`).
  renderArgs = lib.cli.toCommandLine (cliOptionFormat null);
in
{
  options.services.llmhop.sglang =
    mkUvOptions {
      backend = "sglang";
      displayName = "SGLang";
      packageEntry = "the SGLang Python environment, launched as `bin/python -m sglang.launch_server`";
      packageNote = "\nThe native module serves workers only; the SGL Model Gateway remains a `sglang-quadlet` feature (llmhop already routes between backends).";
    }
    // {
      enable = lib.mkEnableOption "SGLang model serving via systemd (native host process), fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (mkUvModelSubmodule {
            backend = "sglang";
            inherit cfg;
            modelArgument = "`--model-path`";
            modelExample = "Qwen/Qwen3-8B";
          })
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen3-8b" = {
              model = "Qwen/Qwen3-8B";
              port = 19001;
              settings = {
                reasoning-parser = "qwen3";
                mem-fraction-static = 0.6;
              };
            };
          }
        '';
        description = ''
          Models to serve.
          Each enabled entry produces one systemd service named `sglang-<name>`;
          the attribute name is the routing key surfaced through llmhop as the
          OpenAI `model` field.
          Enabled entries are sorted by ascending `port`.
        '';
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig {
        backend = "sglang";
        inherit cfg;
      })
      {
        # `mkUvServices` owns the shared GPU/cache/hardening service body; SGLang
        # supplies only its launcher. `python -m sglang.launch_server` is the entry
        # point present in every SGLang wheel (a top-level `sglang` console script
        # is not), so it is the robust choice for a from-wheel virtual environment.
        systemd.services = mkUvServices {
          serviceName = "sglang";
          inherit cfg pkgs utils;
          execStart =
            model:
            [
              (lib.getExe' model.package "python")
              "-m"
              "sglang.launch_server"
            ]
            ++ renderArgs (
              {
                model-path = model.model;
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
