# The Quadlet backend of the engine `name` under
# `services.llmhop.<name>-quadlet`. Every workload runs its internal
# `container`, an `entrypoint` with `arguments` followed by its settings and
# further `mounts`, in the backend's image beside its fetcher.
lib: name:
{
  config,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  shared = import ./shared.nix lib;
  opts = import ./options.nix lib;
  engine = (import ../engines.nix lib).${name};
  backend = "${name}-quadlet";
  cfg = config.services.llmhop.${backend};
  inherit (config.virtualisation) quadlet;

  fetchScriptPath = "${util.containerRuntimeDirectory}/fetch.sh";

  # The image unit `<name>-image`, shared by every workload.
  image = util.imageUnit {
    inherit (quadlet) images;
    inherit name;
    inherit (cfg) image;
    owner = "services.llmhop.${backend}";
  };

  # The containers of `workload`: its offline server, started after `after`,
  # and its fetcher. See "Offline servers" in the module internals
  # documentation.
  containers =
    workload: after:
    let
      inherit (workload) unit;
      # A host directory mounted at the same path.
      cacheMount =
        directory: options:
        "${directory}:${directory}${util.mountSuffix (options ++ cfg.mountOptions.cache)}";
      cache = cacheMount (shared.cacheDirectory cfg workload) [ ];
      credentialDirectory = util.containerCredentialDirectory;
      fetch = shared.fetcher {
        inherit
          engine
          cfg
          workload
          credentialDirectory
          ;
        inherit (engine.quadlet) fetcher;
      };
      credentials = util.credentialMount cfg.mountOptions.credentials;
      # A socket in a mounted directory and, offline, no network, or else
      # the published port.
      network =
        if workload.socket != null then
          {
            # Quadlet's own `Umask=` is newer than podman 6.1.
            PodmanArgs = [ "--umask=${shared.socketUMask}" ];
          }
          // lib.optionalAttrs workload.offline { Network = "none"; }
        else
          {
            PublishPort = [
              "${util.hostPort workload.host workload.port}:${toString engine.quadlet.port}"
            ];
          };
    in
    {
      ${unit} = {
        # `Restart = "always"` overrides quadlet-nix's `on-failure` default.
        serviceConfig = shared.serverServiceConfig cfg workload;
        unitConfig = util.startLimitConfig // {
          Wants = shared.fetcherUnits workload;
          After = shared.fetchOrder workload ++ after;
        };
        containerConfig =
          util.baseContainerConfig
          // image.containerConfig
          // {
            Entrypoint = lib.toJSON workload.container.entrypoint;
            Notify = "healthy";
            HealthCmd = "curl --fail --silent --show-error ${util.healthTarget (opts.quadletListener engine workload)}";
            HealthStartPeriod = "30m";
            HealthInterval = "10s";
            HealthTimeout = "5s";
            Volume = [
              cache
            ]
            # The server only reads the hub cache.
            ++ map (directory: cacheMount directory [ "ro" ]) (shared.hubDirectories cfg workload)
            ++ workload.container.mounts
            # `U` hands the directory to whatever host UID the container
            # user maps to, so the socket works under any `User=` and
            # `UserNS=`.
            ++ lib.optional (
              workload.socket != null
            ) "${dirOf workload.socket}:${util.containerSocketDirectory}:U"
            ++ credentials workload.credentials;
            EnvironmentFile = shared.environmentFiles cfg workload;
            Environment =
              shared.serverEnvironment {
                inherit
                  engine
                  cfg
                  workload
                  credentialDirectory
                  ;
                inherit (engine.quadlet) environment;
              }
              // util.credentialEnvironment workload.credentials;
            Exec = lib.escapeShellArgs (
              workload.container.arguments
              ++ util.renderCliArgs engine (
                util.resolveCredentialRefs credentialDirectory workload.credentials workload.settings
              )
            );
          }
          // network
          // lib.optionalAttrs (!workload.unlisted) {
            AddDevice = workload.devices;
            ShmSize = workload.shmSize;
            Ulimit = "host";
          }
          // cfg.containerConfig;
      };
    }
    // lib.optionalAttrs (shared.fetches workload) {
      ${shared.fetchUnit unit} = {
        inherit (fetch) serviceConfig;
        unitConfig = util.startLimitConfig;
        containerConfig =
          util.baseContainerConfig
          // image.containerConfig
          // {
            AutoUpdate = "disabled";
            Entrypoint = lib.toJSON [
              "/bin/sh"
              fetchScriptPath
            ];
            Volume = [
              cache
              "${builtins.toFile "fetch.sh" fetch.script}:${fetchScriptPath}:ro"
            ]
            ++ credentials cfg.fetch.credentials;
            EnvironmentFile = fetch.environmentFile;
            Environment = fetch.environment // util.credentialEnvironment cfg.fetch.credentials;
          }
          // cfg.containerConfig;
      };
    };

  models = shared.sortedWorkloads cfg.models;
  workloads = models ++ cfg.extraWorkloads;
  baseOptions = opts.backendOptions engine;
in
{
  options.services.llmhop.${backend} = baseOptions // {
    image = util.imageOption // {
      example = engine.quadlet.imageExample;
    };
    cache = baseOptions.cache // {
      user = mkOption {
        type = types.str;
        default = "root";
        description = ''
          Host owner of the cache directories. Override it for a cache on a
          filesystem without idmapped mounts, such as NFS, with the host ID
          that `UIDMap=` gives the container user.
        '';
      };
      group = mkOption {
        type = types.str;
        default = "root";
        description = "Host group of the cache directories.";
      };
    };
    containerConfig = util.containerConfigOption "this backend, servers, fetchers and detectors alike";
    mountOptions = {
      cache = mkOption {
        type = with types; listOf str;
        default = [ ];
        example = [ "idmap" ];
        description = ''
          Podman volume options of the cache mounts below `cache.directory`,
          such as `idmap` so a user namespace owns them, or SELinux
          relabeling.
        '';
      };
      credentials = util.credentialMountOptionsOption "this backend";
    };
    startupOrdering = opts.startupOrderingOption "via its own `devices`";
    devices = mkOption {
      type = with types; listOf str;
      default =
        if config.hardware.nvidia-container-toolkit.enable or false then [ "nvidia.com/gpu=all" ] else [ ];
      defaultText = lib.literalExpression ''
        if config.hardware.nvidia-container-toolkit.enable then [ "nvidia.com/gpu=all" ] else [ ]
      '';
      example = [ "amd.com/gpu=all" ];
      description = ''
        Devices exposed to every model container as Quadlet `AddDevice=`
        lines, CDI references such as `nvidia.com/gpu=all` or host device
        paths. Per-model `devices` replaces it.
      '';
    };
    models =
      opts.modelsOption
        {
          inherit engine;
          description = ''
            Models to serve, each as the container `${name}-<name>` beside its
            fetcher `${name}-<name>-fetch`. Override their units through
            `virtualisation.quadlet.containers.<unit>`.
          '';
        }
        [
          (opts.workloadModule {
            inherit engine;
            noun = "model";
            inherit (config.services.llmhop) socketDirectory;
            listener = opts.quadletListener engine;
            derivedSettings = engine.modelSettings;
            defaults = cfg.modelSettings;
          })
          (opts.modelModule {
            inherit engine;
            extraRepositories = [ ];
          })
          (
            { config, ... }:
            {
              options = {
                devices = mkOption {
                  type = with types; listOf str;
                  default = cfg.devices;
                  defaultText = lib.literalExpression "config.services.llmhop.${backend}.devices";
                  example = [ "nvidia.com/gpu=0" ];
                  description = "Devices exposed to this model's container, replacing the backend's `devices`.";
                };
                shmSize = mkOption {
                  type = types.str;
                  default = "32g";
                  example = "64g";
                  description = ''
                    Size of the container's private `/dev/shm` tmpfs, which
                    PyTorch uses for tensor-parallel inference.
                  '';
                };
                container = mkOption {
                  type = types.attrs;
                  internal = true;
                  default = {
                    inherit (engine.quadlet) entrypoint;
                    arguments = engine.quadlet.arguments config;
                    mounts = [ ];
                  };
                  description = "The `entrypoint`, `arguments` and `mounts` of this model's container.";
                };
              };
            }
          )
        ];
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [ (util.requireQuadlet config "services.llmhop.${backend}") ];
        virtualisation.quadlet = lib.mkIf (workloads != [ ]) {
          inherit (image) images;
          containers = lib.mkMerge (
            lib.zipListsWith containers models (shared.predecessors cfg.startupOrdering models)
            ++ map (workload: containers workload [ ]) cfg.extraWorkloads
          );
        };
        services.llmhop.claims = lib.mkIf (workloads != [ ]) image.claims;

        # A container maps to no host group known in advance, so its socket
        # is reachable through a default ACL on the root instead. See "Unix
        # sockets" in the module internals documentation.
        systemd.tmpfiles.settings."10-llmhop" =
          lib.mkIf (lib.any (w: w.socket != null) workloads && config.services.llmhop.socketClients != [ ])
            {
              ${config.services.llmhop.socketDirectory}.a.argument = lib.concatMapStringsSep "," (
                user: "default:user:${user}:-wx"
              ) config.services.llmhop.socketClients;
            };
      }
      (shared.backendConfig {
        inherit
          engine
          backend
          cfg
          workloads
          ;
        inherit pkgs utils;
        systemd = config.systemd.package;
        cacheOwner = cfg.cache;
      })
    ]
  );
}
