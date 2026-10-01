# vLLM's watermark detector, the `detect` command of `mkVllmWatermark`'s
# script. The native backend runs it with the detector's own vLLM environment,
# the Quadlet backend mounts it into the image and runs it with the image's
# Python.
lib:
let
  inherit (lib) mkOption types;

  detectors = import ./lib.nix lib;
  watermark = import ../watermark.nix lib;
  inherit (import ../lib.nix lib) settingsRendering;

  # Internal port the container binds to; the host port is published onto it.
  containerPort = 8000;

  managed = detector: { inherit (detector) tokenizer; } // watermark.flags detector.watermark;

  # `defaultScript` is the `script` default for a detector's config.
  options = backend: defaultScript: config: {
    tokenizer = mkOption {
      type = types.str;
      example = "Qwen/Qwen3-8B";
      description = ''
        Tokenizer used to encode candidate text. It must exactly match the
        tokenizer used for watermarked generation.
      '';
    };
    script = mkOption {
      type = types.path;
      default = defaultScript config;
      defaultText = lib.literalMD "the script built by `mkVllmWatermark`";
      description = ''
        Detector server run by the detector's Python interpreter.
        It receives `detect`, `--tokenizer`, `--watermark-config`,
        `--watermark-key-file`, the listener flags (`--host` and `--port`,
        or `--uds`) and `settings`, and must serve `GET /health` and
        `POST /detect`.
        The native default is checked against `package` at build time, the
        Quadlet one only at startup, since the image is opaque to the build.
      '';
    };
    settings = mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        p-value-threshold = 0.01;
      };
      description = ''
        Arguments passed to the detector script.
        `p-value-threshold` is the only detection-side setting.
        `tokenizer`, the watermark flags and the listener (`host`, `port`,
        `uds`) are derived from the options and always win over entries set
        here.
        ${settingsRendering backend}
      '';
    };
  };
in
{
  native = {
    registry = detectors.registry "vllm";

    mkSubmodule =
      {
        cfg,
        pkgs,
        socketDirectory,
      }:
      [
        (detectors.mkNativeSubmodule {
          backend = "vllm";
          inherit cfg socketDirectory;
          options = options "vllm" (config: watermark.mkScript pkgs config.package);
        })
        (watermark.module { optional = false; })
      ];

    mkService =
      {
        cfg,
        pkgs,
        utils,
        detector,
      }:
      detectors.mkNativeService {
        backend = "vllm";
        inherit
          cfg
          pkgs
          utils
          detector
          ;
        command = watermark.nativeCommand detector.package detector.script "detect";
        managed = managed detector;
        inherit (detector) settings;
      };
  };

  quadlet = {
    registry = detectors.registry "vllm-quadlet";

    mkSubmodule =
      { socketDirectory }:
      [
        (detectors.mkQuadletSubmodule {
          backend = "vllm-quadlet";
          inherit socketDirectory;
          options = options "vllm-quadlet" (_config: watermark.source);
        })
        (watermark.module { optional = false; })
      ];

    mkContainer =
      {
        cfg,
        config,
        detector,
      }:
      detectors.mkQuadletContainer (
        {
          backend = "vllm-quadlet";
          inherit
            cfg
            config
            detector
            containerPort
            ;
          managed = managed detector;
          inherit (detector) settings;
        }
        // watermark.container detector.script "detect"
      );
  };
}
