# vLLM watermarking, configured declaratively apart from the key, and the
# detectors serving `POST /detect` beside the workers, as modules extending
# both vLLM backends. Each watermark names the systemd credential of its key,
# imported from the system credential store unless a workload's `credentials`
# names a file, which `mkVllmWatermark`'s script merges into the configuration
# in-process, so it enters neither the Nix store nor a command line.
lib:
{
  common,
  native,
  quadlet,
}:
let
  inherit (lib) mkOption types;
  inherit (common)
    engines
    isRepository
    repositoriesOption
    sortedWorkloads
    workloadModule
    ;

  engine = engines.vllm;
  source = ../../pkgs/mkVllmWatermark/watermark.py;
  containerScript = "${quadlet.containerRuntimeDirectory}/watermark.py";

  # Runs the script with the image's Python.
  containerCommand = script: arguments: {
    arguments = [ containerScript ] ++ arguments;
    entrypoint = [ "python" ];
    mounts = [ "${script}:${containerScript}:ro" ];
  };

  # vLLM's `WatermarkConfig` without `key`, beside the `credential` holding
  # it, so a model's watermark can be copied into a detector profile.
  watermarkType = types.submodule {
    freeformType = with types; attrsOf anything;
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
    algorithm = "dual_key_gumbel";
    credential = "vllm.watermark-key.2026-10";
  };

  # The `WatermarkConfig` of `watermark` and the reference to its key.
  watermarkConfig = watermark: removeAttrs watermark [ "credential" ];
  keyReference = watermark: "\${cred:${watermark.credential}}";

  # Files of a repository that a tokenizer may need.
  tokenizerFiles = [
    "*.json"
    "*.jinja"
    "*.model"
    "*.py"
    "*.tiktoken"
    "*.txt"
  ];

  # Adds the internal `watermarks` of a workload, derived from its config by
  # `watermarks`, and grants their keys.
  watermarksModule =
    watermarks:
    { config, ... }:
    {
      options.watermarks = mkOption {
        internal = true;
        readOnly = true;
        type = with types; listOf attrs;
        default = watermarks config;
        description = "Watermarks whose keys this workload is granted.";
      };
      config.credentials = lib.genAttrs (map (watermark: watermark.credential) config.watermarks) (
        _: lib.mkDefault null
      );
    };

  # Adds the optional `watermark` of a model worker.
  modelWatermarkModule =
    { config, ... }:
    {
      imports = [ (watermarksModule (model: lib.optional (model.watermark != null) model.watermark)) ];
      options.watermark = mkOption {
        type = types.nullOr watermarkType;
        default = null;
        example = watermarkExample;
        description = ''
          vLLM's `WatermarkConfig` without `key`, which a detector profile must
          repeat, and the `credential` holding the key.
        '';
      };
      config = lib.mkIf (config.watermark != null) {
        # Flags `mkVllmWatermark`'s script reads, which win like derived ones.
        settings = lib.mapAttrs (_: lib.mkForce) {
          watermark-config = watermarkConfig config.watermark;
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

  # Options of a detector, whose `script` default each backend sets.
  detectorModule =
    { socketDirectory, listen }:
    { config, ... }:
    {
      imports = [
        (workloadModule {
          inherit engine socketDirectory listen;
          unitPrefix = "vllm";
          noun = "watermark detector";
          derivedSettings = detector: {
            profiles = lib.mapAttrs (_: profile: {
              inherit (profile) tokenizer revision;
              key_file = keyReference profile.watermark;
              config = watermarkConfig profile.watermark;
            }) detector.profiles;
          };
        })
        (watermarksModule (detector: map (profile: profile.watermark) (lib.attrValues detector.profiles)))
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
        repositories = repositoriesOption (
          lib.unique (
            map (profile: {
              repo = profile.tokenizer;
              inherit (profile) revision;
              include = tokenizerFiles;
            }) (lib.filter (profile: isRepository profile.tokenizer) (lib.attrValues config.profiles))
          )
        );
        script = mkOption {
          type = types.path;
          defaultText = lib.literalMD "the script built by `mkVllmWatermark`";
          description = ''
            Detector server run by the detector's Python interpreter. It
            receives `detect` and `settings`, the `profiles` among them as
            JSON, and must serve `GET /health` and `POST /detect`.
            `p-value-threshold` is the only detection-side setting of the
            default.
          '';
        };
      };
    };

  # A backend's `models`, watermarked and extended by `module`.
  modelsOption =
    module:
    mkOption {
      type = types.attrsOf (
        types.submodule [
          modelWatermarkModule
          module
        ]
      );
    };

  # The standalone detectors of a backend, extended by `module`.
  detectorsOption =
    {
      socketDirectory,
      listen,
      module,
    }:
    mkOption {
      type = types.attrsOf (
        types.submodule [
          (detectorModule { inherit socketDirectory listen; })
          module
        ]
      );
      default = { };
      description = ''
        Standalone watermark detection services. The llmhop gateway routes
        them as unlisted models, while every other gateway leaves them to
        direct clients.
      '';
    };

  # Configuration of `backend` shared by both kinds: its detectors routed as
  # unlisted `entries`, each completed by `detectorEntry`, and the rejection
  # of an inline key, which would enter the Nix store and the command line.
  backendConfig =
    {
      backend,
      cfg,
      detectorEntry,
    }:
    lib.mkIf cfg.enable {
      services.llmhop.${backend}.entries = map (
        detector:
        {
          workload = detector;
          unlisted = true;
        }
        // detectorEntry detector
      ) (sortedWorkloads cfg.detectors);
      assertions =
        lib.mapAttrsToList
          (name: workload: {
            assertion =
              !lib.any (config: lib.isAttrs config && config ? key) (
                workload.watermarks ++ [ (workload.settings.watermark-config or null) ]
              )
              && !lib.any (lib.hasPrefix "watermark-config.") (lib.attrNames workload.settings);
            message = "services.llmhop.${backend}: `${name}` configures the watermark key inline, which its `credential` provides.";
          })
          (
            lib.mapAttrs' (name: lib.nameValuePair "models.${name}") cfg.models
            // lib.mapAttrs' (name: lib.nameValuePair "detectors.${name}") cfg.detectors
          )
        ++ lib.mapAttrsToList (name: detector: {
          assertion = detector.profiles != { };
          message = "services.llmhop.${backend}: detector `${name}` has no `profiles`.";
        }) cfg.detectors;
    };
in
{
  # The module of the native backend. A detector runs in its own vLLM
  # environment, which checks the default script at build time.
  native =
    { config, pkgs, ... }:
    let
      cfg = config.services.llmhop.vllm;
      mkScript = pkgs.callPackage ../../pkgs/mkVllmWatermark/package.nix { };
    in
    {
      options.services.llmhop.vllm = {
        models = modelsOption (
          { config, ... }:
          {
            config.command = lib.mkIf (config.watermark != null) [
              (lib.getExe' config.package "python")
              (mkScript config.package)
              "serve"
              config.model
            ];
          }
        );
        detectors = detectorsOption {
          inherit (native) listen;
          inherit (config.services.llmhop) socketDirectory;
          module =
            { config, ... }:
            {
              options.package = mkOption {
                type = types.package;
                default = cfg.package;
                defaultText = lib.literalExpression "config.services.llmhop.vllm.package";
                description = "Environment this detector runs in.";
              };
              config.script = lib.mkDefault (mkScript config.package);
            };
        };
      };
      config = backendConfig {
        backend = "vllm";
        inherit cfg;
        detectorEntry = detector: {
          description = "vLLM watermark detector ${detector.name}";
          command = [
            (lib.getExe' detector.package "python")
            detector.script
            "detect"
          ];
        };
      };
    };

  # The module of the Quadlet backend. The script is mounted into the image
  # and run unchecked with its Python, since the image is opaque to the build.
  quadlet =
    { config, ... }:
    let
      cfg = config.services.llmhop.vllm-quadlet;
    in
    {
      options.services.llmhop.vllm-quadlet = {
        models = modelsOption (
          { config, ... }:
          {
            config.container = lib.mkIf (config.watermark != null) (
              containerCommand source [
                "serve"
                config.model
              ]
            );
          }
        );
        detectors = detectorsOption {
          listen = quadlet.listen engine;
          inherit (config.services.llmhop) socketDirectory;
          module = {
            options = quadlet.workloadOptions {
              inherit cfg;
              backend = "vllm-quadlet";
              noun = "detector";
            };
            config.script = lib.mkDefault source;
          };
        };
      };
      config = backendConfig {
        backend = "vllm-quadlet";
        inherit cfg;
        detectorEntry = detector: containerCommand detector.script [ "detect" ];
      };
    };
}
