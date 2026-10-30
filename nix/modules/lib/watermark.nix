# vLLM watermarking, configured declaratively apart from the key, and the
# detectors serving `POST /detect` beside the workers, as modules extending
# both vLLM backends. The key is the systemd credential `vllm.watermark-key`,
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
  credential = "vllm.watermark-key";
  source = ../../pkgs/mkVllmWatermark/watermark.py;
  containerScript = "${quadlet.containerRuntimeDirectory}/watermark.py";

  # Runs the script with the image's Python.
  containerCommand = script: arguments: {
    arguments = [ containerScript ] ++ arguments;
    entrypoint = [ "python" ];
    mounts = [ "${script}:${containerScript}:ro" ];
  };

  # Adds `watermark` and grants its key, optional for model workers and always
  # set for detectors.
  watermarkModule =
    { optional }:
    { config, ... }:
    {
      options.watermark = mkOption {
        type = with types; if optional then nullOr (attrsOf anything) else attrsOf anything;
        default = if optional then null else { };
        example = {
          algorithm = "dual_key_gumbel";
          context_width = 4;
        };
        description = ''
          vLLM's `WatermarkConfig` without `key`, which a generating worker
          and its detector must share. The key is the credential
          `${credential}`, an unsigned 64-bit integer, imported from the
          system credential store unless `credentials."${credential}"` names a
          file.
        '';
      };
      config = lib.mkIf (config.watermark != null) {
        credentials.${credential} = lib.mkDefault null;
        # Flags `mkVllmWatermark`'s script reads, which win like derived ones.
        settings = lib.mapAttrs (_: lib.mkForce) {
          watermark-config = config.watermark;
          watermark-key-file = "\${cred:${credential}}";
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
          unitPrefix = "vllm-detector";
          noun = "watermark detector";
          derivedSettings = detector: { inherit (detector) tokenizer; };
        })
        (watermarkModule { optional = false; })
      ];
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
        repositories = repositoriesOption (
          lib.optional (isRepository config.tokenizer) {
            repo = config.tokenizer;
            include = [
              "*.json"
              "*.jinja"
              "*.model"
              "*.py"
              "*.tiktoken"
              "*.txt"
            ];
          }
        );
        script = mkOption {
          type = types.path;
          defaultText = lib.literalMD "the script built by `mkVllmWatermark`";
          description = ''
            Detector server run by the detector's Python interpreter. It
            receives `detect` and `settings`, and must serve `GET /health` and
            `POST /detect`. `p-value-threshold` is the only detection-side
            setting of the default.
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
          (watermarkModule { optional = true; })
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
  watermarkConfig =
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
              !(
                lib.isAttrs (workload.settings.watermark-config or null) && workload.settings.watermark-config ? key
              )
              && !lib.any (lib.hasPrefix "watermark-config.") (lib.attrNames workload.settings);
            message = "services.llmhop.${backend}: `${name}` configures the watermark key inline, which the `${credential}` credential provides.";
          })
          (
            lib.mapAttrs' (name: lib.nameValuePair "models.${name}") cfg.models
            // lib.mapAttrs' (name: lib.nameValuePair "detectors.${name}") cfg.detectors
          );
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
      config = watermarkConfig {
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
      config = watermarkConfig {
        backend = "vllm-quadlet";
        inherit cfg;
        detectorEntry = detector: containerCommand detector.script [ "detect" ];
      };
    };
}
