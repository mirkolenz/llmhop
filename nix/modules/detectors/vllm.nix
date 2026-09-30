# vLLM's watermark detector, the server built by `mkVllmDetector`. The native
# backend runs it with the detector's own vLLM environment, the Quadlet backend
# mounts it into the image and runs it with the image's Python.
lib:
let
  inherit (lib) mkOption types;

  detectors = import ./lib.nix lib;
  inherit (import ../lib.nix lib) containerRuntimeDirectory settingsRendering;

  source = ../../pkgs/mkVllmDetector/detector.py;
  containerScript = "${containerRuntimeDirectory}/detector.py";

  # Internal port the container binds to; the host port is published onto it.
  containerPort = 8000;

  # The script takes exactly one of these, so anything else fails evaluation
  # rather than the unit.
  configFlags = [
    "watermark-config"
    "watermark-config-file"
  ];
  checkedSettings =
    detector:
    lib.throwIfNot (lib.count (flag: detector.settings ? ${flag}) configFlags == 1)
      "services.llmhop: watermark detector `${detector.name}` needs exactly one of `settings.watermark-config` and `settings.watermark-config-file`, the configuration used for generation."
      detector.settings;

  managed = detector: { inherit (detector) tokenizer; };

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
      defaultText = lib.literalMD "the server built by `mkVllmDetector`";
      description = ''
        Detector server run by the detector's Python interpreter.
        It receives `--tokenizer`, the listener flags (`--host` and `--port`,
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
        watermark-config = {
          algorithm = "gumbel";
          key = 123456789;
        };
        p-value-threshold = 0.01;
      };
      description = ''
        Arguments passed to the detector script.
        It takes exactly one of `watermark-config`, the attribute set given to
        the generating `vllm serve` under the same name, and
        `watermark-config-file`, a file holding that configuration as JSON,
        typically a `''${cred:…}` reference.
        `p-value-threshold` is the only detection-side setting.
        `tokenizer` and the listener (`host`, `port`, `uds`) are derived from
        the options and always win over entries set here.

        An inline `watermark-config` lands its `key` in the Nix store and in
        the process command line.
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
      let
        mkVllmDetector = pkgs.callPackage ../../pkgs/mkVllmDetector/package.nix { };
      in
      detectors.mkNativeSubmodule {
        backend = "vllm";
        inherit cfg socketDirectory;
        options = options "vllm" (config: mkVllmDetector config.package);
      };

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
        command = [
          (lib.getExe' detector.package "python")
          detector.script
        ];
        managed = managed detector;
        settings = checkedSettings detector;
      };
  };

  quadlet = {
    registry = detectors.registry "vllm-quadlet";

    mkSubmodule =
      { socketDirectory }:
      detectors.mkQuadletSubmodule {
        backend = "vllm-quadlet";
        inherit socketDirectory;
        options = options "vllm-quadlet" (_config: source);
      };

    mkContainer =
      {
        cfg,
        config,
        detector,
      }:
      detectors.mkQuadletContainer {
        backend = "vllm-quadlet";
        inherit
          cfg
          config
          detector
          containerPort
          ;
        arguments = [ containerScript ];
        managed = managed detector;
        settings = checkedSettings detector;
        containerConfig.Entrypoint = lib.toJSON [ "python" ];
        mounts = [ "${detector.script}:${containerScript}:ro" ];
      };
  };
}
