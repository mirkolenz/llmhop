# vLLM watermarking, configured declaratively apart from the key, and the
# detectors serving `POST /detect` beside the workers, as modules extending
# both vLLM backends. Each watermark names the systemd credential of its key,
# imported from the system credential store unless a workload's `credentials`
# names a file, which `mkVllmWatermark`'s script merges into the configuration
# in-process, so it enters neither the Nix store nor a command line.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  shared = import ./shared.nix lib;
  opts = import ./options.nix lib;
  engine = (import ../engines.nix lib).vllm;

  source = ../../pkgs/mkVllmWatermark/watermark.py;
  containerScript = "${util.containerRuntimeDirectory}/watermark.py";

  # The container of a workload running `script` with the image's Python.
  scriptContainer = script: arguments: {
    entrypoint = [ "python" ];
    arguments = [ containerScript ] ++ arguments;
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
          vLLM's `WatermarkConfig` without `key`, which a detector profile must
          repeat, and the `credential` holding the key.
        '';
      };
      config = lib.mkIf (config.watermark != null) {
        credentials = keyCredentials [ config.watermark ];
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

  # A detector, an unlisted workload whose `script` default each backend sets.
  detectorModule =
    { socketDirectory, listener }:
    { config, ... }:
    {
      imports = [
        (opts.workloadModule {
          inherit engine socketDirectory listener;
          noun = "watermark detector";
          derivedSettings = detector: {
            profiles = lib.mapAttrs (_: profile: {
              inherit (profile) tokenizer revision;
              key_file = keyReference profile.watermark;
              config = watermarkConfig profile.watermark;
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
      config = {
        unlisted = true;
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

  # The `models` and `detectors` options of a backend, extended by the
  # submodules `model` and `detector`.
  backendOptions =
    {
      socketDirectory,
      listener,
      model,
      detector,
    }:
    {
      models = mkOption {
        type = types.attrsOf (
          types.submodule [
            modelModule
            model
          ]
        );
      };
      detectors = mkOption {
        type = types.attrsOf (
          types.submodule [
            (detectorModule { inherit socketDirectory listener; })
            detector
          ]
        );
        default = { };
        description = ''
          Standalone watermark detection services. The llmhop gateway routes
          them as unlisted models, while every other gateway leaves them to
          direct clients.
        '';
      };
    };

  # Serves the detectors of `backend` beside its models, and rejects an inline
  # key, which would enter the Nix store and the command line.
  backendConfig =
    backend: cfg:
    let
      inlineKey =
        workload: watermarks:
        lib.any (config: lib.isAttrs config && config ? key) (
          watermarks ++ [ (workload.settings.watermark-config or null) ]
        )
        || lib.any (lib.hasPrefix "watermark-config.") (lib.attrNames workload.settings);
      inlineKeyAssertion = path: workload: watermarks: {
        assertion = !inlineKey workload watermarks;
        message = "services.llmhop.${backend}: `${path}` configures the watermark key inline, which its `credential` provides.";
      };
    in
    lib.mkIf cfg.enable {
      services.llmhop.${backend}.extraWorkloads = shared.sortedWorkloads cfg.detectors;
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
          message = "services.llmhop.${backend}: detector `${name}` has no `profiles`.";
        }) cfg.detectors;
    };
in
{
  # The native backend. A detector runs in its own vLLM environment, which
  # checks the default script at build time.
  native =
    { config, pkgs, ... }:
    let
      cfg = config.services.llmhop.vllm;
      mkScript = pkgs.callPackage ../../pkgs/mkVllmWatermark/package.nix { };
    in
    {
      options.services.llmhop.vllm = backendOptions {
        inherit (config.services.llmhop) socketDirectory;
        listener = lib.id;
        model =
          { config, ... }:
          {
            config.command = lib.mkIf (config.watermark != null) [
              (lib.getExe' config.package "python")
              (mkScript config.package)
              "serve"
              config.model
            ];
          };
        detector =
          { config, ... }:
          {
            options = {
              package = mkOption {
                type = types.package;
                default = cfg.package;
                defaultText = lib.literalExpression "config.services.llmhop.vllm.package";
                description = "Environment this detector runs in.";
              };
              command = mkOption {
                type = with types; listOf (either str package);
                internal = true;
                default = [
                  (lib.getExe' config.package "python")
                  config.script
                  "detect"
                ];
                description = "Command of this detector's server, followed by its settings.";
              };
            };
            config.script = lib.mkDefault (mkScript config.package);
          };
      };
      config = backendConfig "vllm" cfg;
    };

  # The Quadlet backend. The script is mounted into the image and run
  # unchecked with its Python, since the image is opaque to the build.
  quadlet =
    { config, ... }:
    {
      options.services.llmhop.vllm-quadlet = backendOptions {
        inherit (config.services.llmhop) socketDirectory;
        listener = opts.quadletListener engine;
        model =
          { config, ... }:
          {
            config.container = lib.mkIf (config.watermark != null) (
              scriptContainer source [
                "serve"
                config.model
              ]
            );
          };
        detector =
          { config, ... }:
          {
            options = {
              container = mkOption {
                type = types.attrs;
                internal = true;
                default = scriptContainer config.script [ "detect" ];
                description = "The `entrypoint`, `arguments` and `mounts` of this detector's container.";
              };
            };
            config.script = lib.mkDefault source;
          };
      };
      config = backendConfig "vllm-quadlet" config.services.llmhop.vllm-quadlet;
    };
}
