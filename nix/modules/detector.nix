# vLLM's upstream watermark detector, run as a standalone service beside the
# model workers. Shared by the native and Quadlet vLLM backends, which differ
# only in how the script and the Python interpreter are named.
lib:
let
  inherit (lib) mkOption types;

  llmhopLib = import ./lib.nix lib;
  inherit (llmhopLib)
    credentialDirectory
    credentialsOption
    modelLabel
    renderCliArgs
    renderCliArgsShell
    resolveCredentialRefs
    serviceConfigOption
    settingsRendering
    systemdCredentialDirectory
    unitConfigOption
    withManagedSettings
    ;

  unitName = detector: "vllm-detector-${detector.name}";

  # `host` differs between the backends: the container publishes its port
  # instead of binding loopback directly. `key` is required by the script but
  # belongs in `settings` beside the generation-side flags, so it is checked
  # here rather than left to fail at unit startup.
  detectorSettings =
    host: port: detector:
    lib.throwIfNot (detector.settings ? key)
      "services.llmhop: watermark detector `${detector.name}` needs `settings.key`, the key used for generation."
      withManagedSettings
      {
        inherit (detector) tokenizer;
        inherit host port;
      }
      detector.settings;

  # The upstream script serves no health endpoint, so readiness comes from
  # FastAPI's `/openapi.json`.
  healthPath = "/openapi.json";

  scriptPath = "examples/basic/online_serving/watermark_detection_server.py";

  # The wheel ships only the importable `vllm` packages, so the example server
  # comes out of the sdist that the same uv lock pins, which `mkUvEnv` exposes.
  # Extracting it here fails the build rather than the unit when the pinned
  # release predates the watermark detector.
  defaultNativeScript =
    pkgs: package:
    pkgs.runCommand (lib.baseNameOf scriptPath) { } ''
      tar -xzOf ${
        package.sdists.vllm
          or (throw "services.llmhop: `package` was not built by `mkUvEnv`, or its uv lock pins no `vllm` sdist, so the watermark detector script cannot be derived. Set `script` explicitly.")
      } --wildcards "*/${scriptPath}" > "$out"
    '';

  # Internal port the container binds to; the host port is published onto it.
  containerPort = 8000;

  baseOptions = name: {
    enable = lib.mkEnableOption "watermark detector ${name}" // {
      default = true;
    };
    name = mkOption {
      type = modelLabel;
      default = name;
      description = ''
        Canonical identifier for this detector. Used for the
        `vllm-detector-<name>` systemd unit and as the routing key clients send
        in the `model` field to reach `POST /detect`. Shares one namespace with
        every backend's model names, so a collision fails evaluation.
      '';
    };
    tokenizer = mkOption {
      type = types.str;
      example = "Qwen/Qwen3-8B";
      description = ''
        Tokenizer used to encode candidate text. It must exactly match the
        tokenizer used for watermarked generation.
      '';
    };
    port = mkOption {
      type = types.port;
      description = "Loopback port on which the upstream detector serves `/detect`.";
    };
    settings = mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        key = 123456789;
        context-width = 4;
      };
      description = ''
        Arguments passed to vLLM's upstream watermark detector server.
        Its current interface supports `key`, `prf`, `context-width`, and
        `p-value-threshold`. `key` is required, and it, `prf` and
        `context-width` must match the generation configuration.
        `tokenizer`, `host` and `port` are derived from the options of the same
        name and always win over entries set here.

        `key` has no file-based alternative upstream, so it lands in the Nix
        store and in the process command line. Treat it as public.
        ${settingsRendering "vllm"}
      '';
    };
    environment = mkOption {
      type = with types; attrsOf str;
      default = { };
      description = "Additional environment variables for this detector.";
    };
    environmentFile = mkOption {
      type = with types; nullOr path;
      default = null;
      description = "Additional environment file for this detector.";
    };
    credentials = credentialsOption;
  };
in
{
  inherit unitName;

  # Folded into `mkConfig`, so each detector joins the global uniqueness checks
  # and llmhop reverse-proxies `/detect` to it.
  registry = detectors: {
    auxiliaries = lib.mapAttrs' (
      name: d:
      lib.nameValuePair "detectors.${name}" {
        inherit (d) port;
        unit = unitName d;
        model = d.name;
      }
    ) detectors;
  };

  mkNativeSubmodule =
    { cfg, pkgs }:
    { name, config, ... }:
    {
      options = baseOptions name // {
        script = mkOption {
          type = types.path;
          default = defaultNativeScript pkgs config.package;
          defaultText = lib.literalMD "`${scriptPath}` from the sdist of the `vllm` release that `package` locks";
          description = ''
            Path to vLLM's upstream `watermark_detection_server.py`.
            It defaults to the copy in the sdist of the `vllm` release pinned by
            this detector's `package`, so the script and the runtime follow one
            another from a single `uv lock`.
            Set it to use a script from elsewhere, such as a vendored or patched
            one.
          '';
        };
        package = mkOption {
          type = types.package;
          default = cfg.package;
          defaultText = lib.literalExpression "config.services.llmhop.vllm.package";
          description = "vLLM Python environment used by this detector.";
        };
        serviceConfig = serviceConfigOption { serviceName = "vllm-detector"; };
        unitConfig = unitConfigOption { serviceName = "vllm-detector"; };
      };
    };

  mkQuadletSubmodule =
    { name, ... }:
    {
      options = baseOptions name // {
        script = mkOption {
          type = types.str;
          default = "/vllm-workspace/${scriptPath}";
          description = ''
            Path inside the selected image to vLLM's upstream
            `watermark_detection_server.py`.
            The default is where the official vLLM image keeps its examples.
          '';
        };
        tag = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Container image tag for this detector.";
        };
        digest = mkOption {
          type = with types; nullOr str;
          default = null;
          description = "Immutable container image digest for this detector.";
        };
        quadlet = llmhopLib.quadlet.mkObjectOptions { description = "this detector container"; };
      };
    };

  # An auxiliary service rather than a model worker: no GPU device access and
  # no `StateDirectory`.
  mkNativeService =
    {
      cfg,
      pkgs,
      utils,
      detector,
    }:
    llmhopLib.systemd.mkUvService {
      inherit
        cfg
        pkgs
        utils
        healthPath
        ;
      unitName = unitName detector;
      description = "vLLM watermark detector ${detector.name}";
      subdir = "vllm/detector-${detector.name}";
      workload = detector;
      execStart = [
        (lib.getExe' detector.package "python")
        detector.script
      ]
      ++ renderCliArgs "vllm" (
        resolveCredentialRefs (systemdCredentialDirectory (unitName detector)) detector.credentials (
          detectorSettings "127.0.0.1" detector.port detector
        )
      );
    };

  mkQuadletContainer =
    { cfg, detector }:
    lib.nameValuePair (unitName detector) (
      llmhopLib.quadlet.mkWorker {
        inherit cfg healthPath;
        inherit (detector) credentials;
        overrides = detector.quadlet;
        healthPort = containerPort;
        containerConfig =
          llmhopLib.quadlet.mkContainerRuntime cfg detector
          // llmhopLib.quadlet.mkImageArgs {
            inherit (cfg) image;
            defaultTag = cfg.tag;
            workload = detector;
            label = "services.llmhop.vllm-quadlet.detectors.${detector.name}";
          }
          // {
            PublishPort = [ "127.0.0.1:${toString detector.port}:${toString containerPort}" ];
            Entrypoint = lib.toJSON [ "python" ];
            Exec = "${lib.escapeShellArg detector.script} ${
              renderCliArgsShell "vllm" (
                resolveCredentialRefs credentialDirectory detector.credentials (
                  detectorSettings "0.0.0.0" containerPort detector
                )
              )
            }";
          };
        serviceConfig.Restart = "on-failure";
      }
    );
}
