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
    containerListen
    hostListen
    listenSettings
    listenerOptions
    modelLabel
    renderCliArgs
    renderCliArgsShell
    resolveSettings
    serviceConfigOption
    settingsRendering
    systemdCredentialDirectory
    unitConfigOption
    workloadUnit
    ;

  unitName = workloadUnit "vllm-detector";

  # `listen` is `hostListen` or `containerListen`. `key` is required by the
  # script but belongs in `settings` beside the generation-side flags, so it
  # is checked here rather than left to fail at unit startup.
  detectorSettings =
    directory: listen: detector:
    lib.throwIfNot (detector.settings ? key)
      "services.llmhop: watermark detector `${detector.name}` needs `settings.key`, the key used for generation."
      resolveSettings
      directory
      detector.credentials
      ({ inherit (detector) tokenizer; } // listenSettings "vllm" listen)
      detector.settings;

  # The upstream script serves no health endpoint, so readiness comes from
  # FastAPI's `/openapi.json`.
  healthPath = "/openapi.json";

  scriptPath = "examples/basic/online_serving/watermark_detection_server.py";

  # The wheel ships only the importable `vllm` packages, so the example server
  # comes out of the sdist that the same uv lock pins, which `mkUvEnv` exposes.
  # Extracting it here fails the build rather than the unit when the pinned
  # release predates the watermark detector. The patch adds the `--uds` flag
  # upstream lacks, and fails the build too once upstream moves the lines.
  defaultNativeScript =
    pkgs: package:
    pkgs.runCommand (baseNameOf scriptPath) { } ''
      tar -xzOf ${
        package.sdists.vllm
          or (throw "services.llmhop: `package` was not built by `mkUvEnv`, or its uv lock pins no `vllm` sdist, so the watermark detector script cannot be derived. Set `script` explicitly.")
      } --wildcards "*/${scriptPath}" > "$out"
      patch "$out" ${../patches/vllm-watermark-detector-uds.patch}
    '';

  # Internal port the container binds to; the host port is published onto it.
  containerPort = 8000;

  baseOptions =
    {
      name,
      workload,
      socketCapable,
      socketDirectory ? null,
    }:
    {
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
    }
    // listenerOptions {
      inherit socketCapable socketDirectory workload;
      unitPrefix = "vllm-detector";
      portDescription = "Loopback port on which the upstream detector serves `/detect`.";
    }
    // {
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
          `tokenizer` and the listener (`host`, `port`, `uds`) are derived from
          the options and always win over entries set here.

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
        inherit (d) port socket;
        unit = unitName d;
        model = d.name;
      }
    ) detectors;
  };

  mkNativeSubmodule =
    {
      cfg,
      pkgs,
      socketDirectory,
    }:
    { name, config, ... }:
    {
      options =
        baseOptions {
          inherit name socketDirectory;
          workload = config;
          socketCapable = true;
        }
        // {
          script = mkOption {
            type = types.path;
            default = defaultNativeScript pkgs config.package;
            defaultText = lib.literalMD "`${scriptPath}` from the sdist of the `vllm` release that `package` locks";
            description = ''
              Path to vLLM's upstream `watermark_detection_server.py`.
              It defaults to the copy in the sdist of the `vllm` release pinned by
              this detector's `package`, so the script and the runtime follow one
              another from a single `uv lock`.
              It is patched to accept `--uds`, which a script set here also needs
              while `port` is null.
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

  # The script inside the image is unpatched, so it always takes a `port`.
  mkQuadletSubmodule =
    { name, config, ... }:
    {
      options =
        baseOptions {
          inherit name;
          workload = config;
          socketCapable = false;
        }
        // {
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
        detectorSettings (systemdCredentialDirectory (unitName detector)) (hostListen detector) detector
      );
    };

  mkQuadletContainer =
    { cfg, detector }:
    lib.nameValuePair (unitName detector) (
      llmhopLib.quadlet.mkWorker {
        inherit cfg healthPath;
        inherit (detector) port socket;
        inherit containerPort;
        inherit (detector) credentials;
        overrides = detector.quadlet;
        containerConfig =
          llmhopLib.quadlet.mkContainerRuntime cfg detector
          // llmhopLib.quadlet.mkImageArgs {
            inherit (cfg) image;
            defaultTag = cfg.tag;
            workload = detector;
            label = "services.llmhop.vllm-quadlet.detectors.${detector.name}";
          }
          // {
            Entrypoint = lib.toJSON [ "python" ];
            Exec = "${lib.escapeShellArg detector.script} ${
              renderCliArgsShell "vllm" (
                detectorSettings credentialDirectory (containerListen containerPort detector.socket) detector
              )
            }";
          };
        serviceConfig.Restart = "on-failure";
      }
    );
}
