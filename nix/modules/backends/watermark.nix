# vLLM watermarking, configured declaratively apart from the key, and the
# detectors serving `POST /detect` beside the workers, extending the vLLM
# backend. Each watermark names the systemd credential of its key, imported
# from the system credential store unless a workload's `credentials` names a
# file, which `mkVllmWatermark`'s script merges into the configuration
# in-process, so it enters neither the Nix store nor a command line.
#
# Natively, the script runs in the workload's vLLM environment, which checks
# the default one at build time. A container mounts it into the image and runs
# it unchecked with the image's Python, since the image is opaque to the build.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  wl = import ./workload.nix lib;
  engine = (import ../engines.nix lib).vllm;
  inherit (config.services.llmhop) socketDirectory;
  cfg = config.services.llmhop.vllm;
  native = cfg.runtime == "native";

  mkScript = pkgs.callPackage ../../pkgs/mkVllmWatermark/package.nix { };
  source = ../../pkgs/mkVllmWatermark/watermark.py;
  # The script built for `package`, or else the source the image runs.
  defaultScript = package: if native then mkScript package else source;
  containerScript = "${util.containerRuntimeDirectory}/watermark.py";

  # The `command` and `mounts` of a workload running `script` with `arguments`
  # in the Python of `package` or of the image.
  scriptInvocation = package: script: arguments: {
    command =
      (if native then [ (lib.getExe' package "python") ] else [ "python" ])
      ++ [ (if native then script else containerScript) ]
      ++ arguments;
    mounts = lib.optional (!native) "${script}:${containerScript}:ro";
  };

  # vLLM's `WatermarkConfig` without `key` as `settings`, beside the
  # `credential` holding it, so a model's watermark can be copied into a
  # detector profile.
  watermarkType = types.submodule {
    options.settings = mkOption {
      type = with types; attrsOf json;
      default = { };
      description = "vLLM's `WatermarkConfig` without `key`.";
    };
    options.credential = mkOption {
      type = types.str;
      default = "vllm.watermark-key";
      example = "vllm.watermark-key.2026-10";
      description = ''
        Credential holding the key, an unsigned 64-bit integer, imported from
        the system credential store unless the service's `credentials` names
        a file for it. A new name per key, such as a date suffix, restarts
        every service using it when the key is rotated.
      '';
    };
  };
  watermarkExample = {
    credential = "vllm.watermark-key.2026-10";
    settings.algorithm = "dual_key_gumbel";
  };

  # The reference to the key of `watermark`.
  keyReference = watermark: "\${cred:${watermark.credential}}";

  # Imports the key of every one of `watermarks` unless `credentials` names a
  # file for it.
  keyCredentials =
    watermarks:
    lib.genAttrs' watermarks (watermark: lib.nameValuePair watermark.credential (lib.mkDefault null));

  # The watermarks of every profile of `detector`.
  profileWatermarks = detector: lib.mapAttrsToList (_: profile: profile.watermark) detector.profiles;

  # Extends a model with its optional `watermark`.
  modelModule =
    { config, ... }:
    {
      options.watermark = mkOption {
        type = types.nullOr watermarkType;
        default = null;
        example = watermarkExample;
        description = ''
          The `settings` of vLLM's `WatermarkConfig` without `key`, which a
          detector profile must repeat, and the `credential` holding the key.
        '';
      };
      config = lib.mkIf (config.watermark != null) {
        inherit
          (scriptInvocation config.package (defaultScript config.package) [
            "serve"
            config.model
          ])
          command
          mounts
          ;
        credentials = keyCredentials [ config.watermark ];
        # Flags `mkVllmWatermark`'s script reads, which win like derived ones.
        settings = lib.mapAttrs (_: lib.mkForce) {
          watermark-config = config.watermark.settings;
          watermark-key-file = keyReference config.watermark;
        };
      };
    };

  # A generation configuration a detector tests.
  profileModule = {
    options = {
      tokenizer = mkOption {
        type = types.str;
        example = "Qwen/Qwen3-8B";
        description = ''
          Tokenizer used to encode candidate text, a Hugging Face repository or
          an absolute path. It must exactly match the tokenizer used for
          watermarked generation. The fetcher downloads only the files of a
          repository that a tokenizer may need, not its weights.
        '';
      };
      revision = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "main";
        description = ''
          Branch, tag or commit of `tokenizer`, which must match the
          `revision` of the generating model, or its
          `settings.tokenizer-revision`. `null` follows the default branch.
        '';
      };
      watermark = mkOption {
        type = watermarkType;
        default = { };
        example = watermarkExample;
        description = "The `watermark` of the generating model.";
      };
    };
  };

  # A detector, an unlisted workload.
  detectorModule =
    { config, ... }:
    {
      imports = [
        (wl.workloadModule {
          inherit engine;
          inherit (cfg) runtime;
          inherit socketDirectory;
          kind = "detector";
          derivedSettings = detector: {
            profiles = lib.mapAttrs (_: profile: {
              inherit (profile) tokenizer revision;
              key_file = keyReference profile.watermark;
              config = profile.watermark.settings;
            }) detector.profiles;
          };
        })
      ];
      options = {
        profiles = mkOption {
          type = types.attrsOf (types.submodule profileModule);
          example = lib.literalExpression ''
            {
              qwen = {
                tokenizer = "Qwen/Qwen3-8B";
                inherit (config.services.llmhop.vllm.models.qwen) revision watermark;
              };
            }
          '';
          description = ''
            Generation configurations to test, keyed by the name a response
            reports as `profile`. Profiles sharing a tokenizer and revision
            share its encoding of the text, and the reported p-value is that
            of the most significant profile multiplied by their number.
          '';
        };
        package = mkOption {
          type = types.package;
          default = cfg.package;
          defaultText = lib.literalExpression "config.services.llmhop.vllm.package";
          description = "Environment this detector runs in. Only used if the backend's `runtime` is `\"native\"`.";
        };
        script = mkOption {
          type = types.path;
          default = defaultScript config.package;
          defaultText = lib.literalMD "the script of `mkVllmWatermark`, built for `package` if the backend's `runtime` is `\"native\"`";
          description = ''
            Detector server run by the detector's Python interpreter. It
            receives `detect` and `settings`, the `profiles` among them as
            JSON, and must serve `GET /health` and `POST /detect`.
            `p-value-threshold` is the only detection-side setting of the
            default.
          '';
        };
      };
      config = {
        inherit (scriptInvocation config.package config.script [ "detect" ]) command mounts;
        credentials = keyCredentials (profileWatermarks config);
        # Only the files of a repository that a tokenizer may need.
        repositories = lib.pipe config.profiles [
          lib.attrValues
          (lib.filter (profile: util.isRepository profile.tokenizer))
          (map (profile: {
            repo = profile.tokenizer;
            inherit (profile) revision;
            include = [
              "*.json"
              "*.jinja"
              "*.model"
              "*.py"
              "*.tiktoken"
              "*.txt"
            ];
          }))
          lib.unique
        ];
      };
    };

  # Rejects an inline key of `workload` at `path` or of its `watermarks`, which
  # would enter the Nix store and the command line.
  inlineKeyAssertion = path: workload: watermarks: {
    assertion =
      !lib.any (config: lib.isAttrs config && config ? key) (
        map (watermark: watermark.settings) watermarks ++ [ (workload.settings.watermark-config or null) ]
      )
      && !lib.any (lib.hasPrefix "watermark-config.") (lib.attrNames workload.settings);
    message = "services.llmhop.vllm: `${path}` configures the watermark key inline, which its `credential` provides.";
  };
in
{
  options.services.llmhop.vllm = {
    models = mkOption { type = types.attrsOf (types.submodule modelModule); };
    detectors = mkOption {
      type = types.attrsOf (types.submodule detectorModule);
      default = { };
      description = ''
        Standalone watermark detection services. The llmhop gateway routes
        them as unlisted models, while every other gateway leaves them to
        direct clients.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.mapAttrsToList (
        name: model:
        inlineKeyAssertion "models.${name}" model (lib.optional (model.watermark != null) model.watermark)
      ) cfg.models
      ++ lib.mapAttrsToList (
        name: detector: inlineKeyAssertion "detectors.${name}" detector (profileWatermarks detector)
      ) cfg.detectors
      ++ lib.mapAttrsToList (name: detector: {
        assertion = detector.profiles != { };
        message = "services.llmhop.vllm: detector `${name}` has no `profiles`.";
      }) cfg.detectors;
  };
}
