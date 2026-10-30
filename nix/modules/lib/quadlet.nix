# Units and options of the Quadlet backends.
lib: common:
let
  inherit (lib) mkOption types;
  inherit (common)
    backendOptions
    cacheDirectory
    chainEntries
    engines
    environmentFiles
    hubCache
    fetchUnit
    fetcherOf
    fetches
    healthTarget
    hostPort
    hubDirectories
    mkFetcher
    modelModule
    modelsOption
    distributedEnvironment
    serverEnvironment
    serverServiceConfig
    sharedConfig
    sharedUnitConfig
    socketName
    socketUMask
    sortedWorkloads
    startupOrderingOption
    workloadArgs
    ;

  # Root of everything llmhop mounts into a container. Its socket directory
  # sits beside, not over, the credential mount.
  containerRuntimeDirectory = "/run/llmhop";
  credentialDirectory = "${containerRuntimeDirectory}/credentials";
  containerSocketDirectory = "${containerRuntimeDirectory}/socket";
  fetchScriptPath = "${containerRuntimeDirectory}/fetch.sh";

  mountSuffix = options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

  # Minimal hardening, Podman isolates the rest. The rootfs stays writable,
  # `/tmp` is a tmpfs for fast scratch.
  baseContainerConfig = {
    NoNewPrivileges = true;
    DropCapability = "all";
    Tmpfs = [ "/tmp" ];
  };

  imageOption = mkOption {
    type = types.str;
    description = "Container image reference, including a tag or digest.";
  };

  # Hash the complete reference so workloads sharing an image share its unit.
  imageUnit =
    {
      images,
      prefix,
      image,
    }:
    let
      name = "${prefix}-${lib.hashString "sha256" image}";
    in
    {
      images.${name}.imageConfig.Image = image;
      containerConfig = {
        Image = images.${name}.ref;
        Pull = "never";
      }
      // lib.optionalAttrs (!lib.hasInfix "@" image) { AutoUpdate = "registry"; };
    };

  # Assertion that the module of `owner` has Quadlet enabled.
  requireEnabled = config: owner: {
    assertion = config.virtualisation.quadlet.enable;
    message = "${owner} requires virtualisation.quadlet.enable.";
  };

  # The read-only mount of a container's `credentials` with further `options`.
  credentialMount =
    options: credentials:
    lib.optional (credentials != { }) "%d:${credentialDirectory}${mountSuffix ([ "ro" ] ++ options)}";

  # The listener of a server container, on the engine's port or the mounted
  # socket.
  listen = engine: workload: {
    host = "0.0.0.0";
    inherit (engine.quadlet) port;
    socket = if workload.socket != null then "${containerSocketDirectory}/${socketName}" else null;
  };

  # Options of a workload's container.
  workloadOptions =
    {
      backend,
      cfg,
      noun,
    }:
    {
      image = imageOption // {
        default = cfg.image;
        defaultText = lib.literalExpression "config.services.llmhop.${backend}.image";
        description = "Image reference of this ${noun}, overriding the backend's `image`.";
      };
      mountOptions.credentials = mkOption {
        type = with types; listOf str;
        default = [ ];
        example = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
        description = ''
          Podman volume options appended to the credential mount of this
          ${noun}'s server. Use an `idmap` mapping when `[Container] User=`
          selects a non-root identity. The mount is always read-only.
        '';
      };
    };

  # The Quadlet configuration of the workload of `entry`: its offline
  # server, which runs the `arguments` of `entry` followed by its settings,
  # its fetcher, and the image unit pulling for both. See "Offline servers"
  # in the module internals documentation.
  quadletConfig =
    {
      name,
      engine,
      cfg,
      hubCache,
      quadlet,
    }:
    entry:
    let
      inherit (entry) workload;
      inherit (workload) unit;
      fetcher = fetcherOf workload;
      # A host directory mounted at the same path.
      cacheMount =
        directory: options: "${directory}:${directory}${mountSuffix (options ++ cfg.cache.mountOptions)}";
      cache = cacheMount (cacheDirectory cfg workload) [ ];
      fetch = mkFetcher {
        inherit
          engine
          cfg
          hubCache
          workload
          credentialDirectory
          ;
        inherit (engine.quadlet) fetcher;
        backend = name;
        server = quadlet.containers.${unit}.serviceName;
      };
      image = imageUnit {
        inherit (quadlet) images;
        inherit (workload) image;
        prefix = name;
      };
      credentials = credentialMount workload.mountOptions.credentials;
      # A socket in a mounted directory and, offline, no network, or else
      # the published port.
      network =
        if workload.socket != null then
          {
            # Quadlet's own `Umask=` is newer than podman 6.1.
            PodmanArgs = [ "--umask=${socketUMask}" ];
          }
          // lib.optionalAttrs workload.offline { Network = "none"; }
        else
          { PublishPort = [ "${hostPort workload.host workload.port}:${toString engine.quadlet.port}" ]; };
    in
    {
      # Defined alike by every workload that shares the image.
      inherit (image) images;
      containers = {
        ${unit} = {
          # `Restart = "always"` overrides quadlet-nix's `on-failure` default.
          serviceConfig = serverServiceConfig cfg workload // fetch.serverServiceConfig;
          unitConfig = sharedUnitConfig // {
            Wants = fetcher;
            After = fetcher ++ entry.after;
          };
          containerConfig =
            baseContainerConfig
            // image.containerConfig
            // {
              Entrypoint = lib.toJSON entry.entrypoint;
              Notify = "healthy";
              HealthCmd = "curl --fail --silent --show-error ${healthTarget (listen engine workload)}";
              HealthStartPeriod = "30m";
              HealthInterval = "10s";
              HealthTimeout = "5s";
              Volume = [
                cache
              ]
              # The server only reads the hub cache.
              ++ map (directory: cacheMount directory [ "ro" ]) (hubDirectories cfg workload)
              ++ entry.mounts
              # `U` hands the directory to whatever host UID the container
              # user maps to, so the socket works under any `User=` and
              # `UserNS=`.
              ++ lib.optional (workload.socket != null) "${dirOf workload.socket}:${containerSocketDirectory}:U"
              ++ credentials workload.credentials;
              EnvironmentFile = environmentFiles cfg workload;
              Environment = serverEnvironment {
                inherit engine cfg workload;
                environment = engine.quadlet.environment // entry.environment;
              };
              Exec = lib.escapeShellArgs (entry.arguments ++ workloadArgs engine credentialDirectory workload);
            }
            // network
            // entry.containerConfig;
        };
      }
      // lib.optionalAttrs (fetches workload) {
        ${fetchUnit unit} = {
          inherit (fetch) serviceConfig;
          unitConfig = sharedUnitConfig;
          containerConfig =
            baseContainerConfig
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
              Environment = fetch.environment;
            };
        };
      };
    };

  # The NixOS module of the Quadlet backend of the engine `name`, under
  # `services.llmhop.<name>-quadlet`. Each model runs its internal
  # `container`, which another module may replace, and the internal `entries`
  # add further workloads, each `{ workload, unlisted }` plus the
  # `entrypoint`, `arguments`, `containerConfig` and `mounts` of its container.
  mkBackend =
    name:
    {
      config,
      pkgs,
      ...
    }:
    let
      engine = engines.${name};
      backend = "${name}-quadlet";
      cfg = config.services.llmhop.${backend};
      inherit (config.virtualisation) quadlet;
      entry =
        e:
        {
          unlisted = false;
          after = [ ];
          inherit (engine.quadlet) entrypoint;
          arguments = [ ];
          mounts = [ ];
          environment = { };
          containerConfig = { };
        }
        // e;
      modelEntry =
        model:
        entry (
          model.container
          // {
            workload = model;
            environment = distributedEnvironment;
            containerConfig = {
              AddDevice = model.devices;
              ShmSize = model.shmSize;
              Ulimit = "host";
            }
            // model.container.containerConfig or { };
          }
        );
      entries =
        chainEntries cfg.startupOrdering (
          e: "${quadlet.containers.${e.workload.unit}.serviceName}.service"
        ) (map modelEntry (sortedWorkloads cfg.models))
        ++ map entry cfg.entries;
      base = backendOptions {
        serviceName = name;
        inherit engine;
      };
    in
    {
      options.services.llmhop.${backend} = base // {
        image = imageOption // {
          example = engine.quadlet.imageExample;
        };
        cache = base.cache // {
          mountOptions = mkOption {
            type = with types; listOf str;
            default = [ ];
            example = [ "idmap" ];
            description = ''
              Options appended to the Quadlet `Volume=` entries of the cache
              directories below `cache.directory`, for Podman ownership
              mechanisms such as `idmap` or SELinux relabeling.
            '';
          };
          user = mkOption {
            type = types.str;
            default = "root";
            description = ''
              Host owner of the cache directories. Override it when a
              `User=`, `UIDMap` or `idmap` makes the container see another owner.
            '';
          };
          group = mkOption {
            type = types.str;
            default = "root";
            description = "Host group of the cache directories.";
          };
        };
        startupOrdering = startupOrderingOption "via its own `devices`";
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
        models = modelsOption {
          inherit engine;
          modules = [
            (modelModule {
              inherit engine;
              extraRepositories = [ ];
              unitPrefix = name;
              socketDirectory = config.services.llmhop.socketDirectory;
              defaults = cfg.modelSettings;
              listen = listen engine;
            })
            (
              { config, ... }:
              {
                options =
                  workloadOptions {
                    inherit backend cfg;
                    noun = "model";
                  }
                  // {
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
                      default = engine.quadlet.container config;
                      description = "The `arguments`, `containerConfig` and `mounts` of this model's container.";
                    };
                  };
              }
            )
          ];
          description = ''
            Models to serve, each as the container `${name}-<name>` beside its
            fetcher `${name}-<name>-fetch`. Override their units through
            `virtualisation.quadlet.containers.<unit>`.
          '';
        };
      };

      config = lib.mkIf cfg.enable (
        lib.mkMerge [
          {
            # Their number depends on the configuration, so they merge below
            # fixed attributes, since a `mkMerge` at the top level would
            # recurse into the configuration it defines.
            virtualisation.quadlet = lib.mkMerge (
              map (quadletConfig {
                inherit
                  name
                  engine
                  cfg
                  quadlet
                  ;
                hubCache = hubCache pkgs;
              }) entries
            );
          }
          (sharedConfig {
            inherit
              backend
              cfg
              pkgs
              entries
              ;
            serviceName = name;
            cacheOwner = cfg.cache;
          })
          {
            assertions = [ (requireEnabled config "services.llmhop.${backend}") ];

            # A container maps to no host group known in advance, so its socket
            # is reachable through a default ACL on the root instead. See "Unix
            # sockets" in the module internals documentation.
            systemd.tmpfiles.settings."10-llmhop" =
              lib.mkIf
                (lib.any (e: e.workload.socket != null) entries && config.services.llmhop.socketClients != [ ])
                {
                  ${config.services.llmhop.socketDirectory}.a.argument = lib.concatMapStringsSep "," (
                    user: "default:user:${user}:-wx"
                  ) config.services.llmhop.socketClients;
                };
          }
        ]
      );
    };
in
{
  inherit
    baseContainerConfig
    containerRuntimeDirectory
    credentialDirectory
    credentialMount
    imageOption
    imageUnit
    listen
    mkBackend
    requireEnabled
    workloadOptions
    ;
}
