# Backend-agnostic scaffolding of a watermark detector: a named service beside
# a backend's model workers that llmhop routes `POST /detect` to. `backend` is
# the option namespace, e.g. `vllm` or `vllm-quadlet`, and each backend's
# module supplies only its own options, managed flags and command.
lib:
let
  inherit (lib) mkOption types;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib)
    baseWorkloadOptions
    nativeWorkloadArgs
    quadletServiceName
    serviceConfigOption
    socketCapable
    unitConfigOption
    workloadUnit
    ;

  serviceName = backend: "${quadletServiceName backend}-detector";
  unitName = backend: workloadUnit (serviceName backend);

  baseOptions =
    {
      backend,
      name,
      workload,
      socketDirectory,
    }:
    baseWorkloadOptions {
      inherit
        backend
        name
        workload
        socketDirectory
        ;
      serviceName = serviceName backend;
      noun = "watermark detector";
      portDescription = "Loopback port on which the detector serves `/detect`.";
    };
in
{
  # Folded into `mkConfig`, so each detector joins the global uniqueness checks
  # and llmhop reverse-proxies `/detect` to it.
  registry = backend: detectors: {
    auxiliaries = lib.mapAttrs' (
      name: d:
      lib.nameValuePair "detectors.${name}" {
        inherit (d) port socket;
        unit = unitName backend d;
        model = d.name;
      }
    ) detectors;
  };

  # `options` builds the backend's own options from the detector's config.
  mkNativeSubmodule =
    {
      backend,
      cfg,
      socketDirectory,
      options,
    }:
    { name, config, ... }:
    {
      options =
        baseOptions {
          inherit backend name socketDirectory;
          workload = config;
        }
        // options config
        // {
          package = mkOption {
            type = types.package;
            default = cfg.package;
            defaultText = lib.literalExpression "config.services.llmhop.${backend}.package";
            description = "Environment this detector runs in.";
          };
          serviceConfig = serviceConfigOption { serviceName = serviceName backend; };
          unitConfig = unitConfigOption { serviceName = serviceName backend; };
        };
    };

  mkQuadletSubmodule =
    {
      backend,
      socketDirectory,
      options,
    }:
    { name, config, ... }:
    {
      options =
        baseOptions {
          inherit backend name socketDirectory;
          workload = config;
        }
        // options config
        // llmhopLib.quadlet.mkImageOptions { noun = "detector"; }
        // {
          quadlet = llmhopLib.quadlet.mkObjectOptions {
            description = "this detector container";
            socket = socketCapable backend;
          };
        };
    };

  # An auxiliary service rather than a model worker: no GPU device access and
  # no `StateDirectory`. `command` precedes the flags, executable included.
  mkNativeService =
    {
      backend,
      cfg,
      pkgs,
      utils,
      detector,
      command,
      managed,
      settings,
    }:
    llmhopLib.systemd.mkUvService {
      inherit cfg pkgs utils;
      unitName = unitName backend detector;
      description = "${backend} watermark detector ${detector.name}";
      subdir = "${backend}/detector-${detector.name}";
      workload = detector;
      execStart =
        command
        ++ nativeWorkloadArgs {
          inherit backend managed settings;
          workload = detector;
        };
    };

  mkQuadletContainer =
    {
      backend,
      cfg,
      config,
      detector,
      containerPort,
      arguments,
      managed,
      settings,
      containerConfig ? { },
      mounts ? [ ],
    }:
    lib.nameValuePair (unitName backend detector) (
      llmhopLib.quadlet.mkWorkloadContainer {
        inherit
          backend
          cfg
          config
          containerPort
          arguments
          managed
          settings
          containerConfig
          mounts
          ;
        collection = "detectors";
        workload = detector;
        serviceConfig.Restart = "on-failure";
      }
    );
}
