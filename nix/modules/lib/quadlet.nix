# Units and options of the Quadlet backends.
lib: common:
let
  inherit (lib) mkOption types;
  inherit (common)
    backendOptions
    cacheDirectoryRule
    chainEntries
    engines
    environmentFiles
    fetchUnit
    fetcherOf
    fetches
    healthTarget
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
    unitCacheDirectory
    workloadArgs
    ;

  # Root of everything llmhop mounts into a container. Its socket directory
  # sits beside, not over, the credential mount.
  containerRuntimeDirectory = "/run/llmhop";
  credentialDirectory = "${containerRuntimeDirectory}/credentials";
  containerSocketDirectory = "${containerRuntimeDirectory}/socket";

  mountSuffix = options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

  # The listener of a server container, on the engine's port or the mounted
  # socket.
  listen = engine: workload: {
    host = "0.0.0.0";
    inherit (engine.quadlet) port;
    socket = if workload.socket != null then "${containerSocketDirectory}/${socketName}" else null;
  };

  # Options of a workload's container. `socket` adds the options of a
  # container that may bind a unix socket.
  workloadOptions =
    { noun, socket }:
    {
      tag = mkOption {
        type = with types; nullOr str;
        default = null;
        description = "Tag of the container image of this ${noun}, instead of the backend's `tag`. Mutually exclusive with `digest`.";
      };
      digest = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "sha256:a73fb0b9046fee099f7c1829d2548e6cc1740f4c2776a6855fa659ae5d0deb49";
        description = "Immutable digest of the container image of this ${noun}. Mutually exclusive with `tag`.";
      };
      mountOptions = {
        credentials = mkOption {
          type = with types; listOf str;
          default = [ ];
          example = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
          description = ''
            Podman volume options appended to the credential mount of this
            ${noun}'s server. Use an `idmap` mapping when `[Container] User=`
            selects a non-root identity. The mount is always read-only.
          '';
        };
      }
      // lib.optionalAttrs socket {
        socket = mkOption {
          type = with types; listOf str;
          default = [ "U" ];
          example = [
            "U"
            "z"
          ];
          description = ''
            Podman volume options of the socket directory mount of this
            ${noun}'s server. `U` hands the directory to whatever host UID the
            container user maps to, so the socket works under any `User=` and
            `UserNS=`. Add `z` on SELinux hosts.
          '';
        };
      };
    };

  # The NixOS module of the Quadlet backend of the engine `name`, under
  # `services.llmhop.<name>-quadlet`. Each model runs its internal
  # `container`, which another module may replace, and the internal `entries`
  # add further workloads, each `{ workload, unlisted }` plus the `arguments`,
  # `containerConfig` and `mounts` of its container.
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
      inherit (config.virtualisation.quadlet) containers images;
      inherit (engine.quadlet) port;
      entry =
        e:
        {
          unlisted = false;
          after = [ ];
          arguments = [ ];
          mounts = [ ];
          environment = { };
          containerConfig = { };
        }
        // e;
      modelEntry =
        model:
        let
          container = entry model.container;
        in
        container
        // {
          workload = model;
          environment = distributedEnvironment;
          containerConfig = {
            AddDevice = model.devices;
            ShmSize = model.shmSize;
            Ulimit = "host";
          }
          // container.containerConfig;
        };
      entries =
        chainEntries cfg.startupOrdering (e: "${containers.${e.workload.unit}.serviceName}.service") (
          map modelEntry (sortedWorkloads cfg.models)
        )
        ++ map entry cfg.entries;
      base = backendOptions {
        serviceName = name;
        inherit engine;
      };

      fetchScriptPath = "${containerRuntimeDirectory}/fetch.sh";
      # A host directory mounted at the same path.
      cacheMount =
        directory: options: "${directory}:${directory}${mountSuffix (options ++ cfg.cache.mountOptions)}";
      # Minimal hardening, Podman isolates the rest. The rootfs stays writable,
      # `/tmp` is a tmpfs for fast scratch.
      baseContainerConfig = {
        NoNewPrivileges = true;
        DropCapability = "all";
        Tmpfs = [ "/tmp" ];
      };

      # The Quadlet configuration of the workload of `entry`: its offline
      # server, which runs the `arguments` of `entry` followed by its settings,
      # its fetcher, and the image unit pulling for both. See "Offline servers"
      # in the module internals documentation.
      quadletConfig =
        entry:
        let
          inherit (entry) workload;
          inherit (workload) unit;
          fetcher = fetcherOf workload;
          fetch = mkFetcher {
            inherit
              engine
              cfg
              pkgs
              workload
              credentialDirectory
              ;
            inherit (engine.quadlet) fetcher;
            server = containers.${unit}.serviceName;
          };
          tag =
            if workload.tag != null && workload.digest != null then
              throw "services.llmhop.${backend}: `${workload.name}` sets both `tag` and `digest`."
            else
              lib.defaultTo cfg.tag workload.tag;
          # Named after its tag or digest, so that workloads sharing an image
          # share the unit.
          imageName = "${name}-${
            if workload.digest != null then
              lib.substring 0 12 (lib.last (lib.splitString ":" workload.digest))
            else
              tag
          }";
          imageConfig =
            autoUpdate:
            {
              Image = images.${imageName}.ref;
              Pull = "never";
            }
            // lib.optionalAttrs autoUpdate { AutoUpdate = "registry"; };
          credentialMount =
            credentials:
            lib.optional (credentials != { })
              "%d:${credentialDirectory}${mountSuffix ([ "ro" ] ++ workload.mountOptions.credentials)}";
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
              { PublishPort = [ "127.0.0.1:${toString workload.port}:${toString port}" ]; };
        in
        {
          # `newer` keeps the local image when the registry is unreachable,
          # where Podman's default `always` would fail its containers. Defined
          # alike by every workload that shares the image.
          images.${imageName}.imageConfig = {
            Image =
              if workload.digest != null then "${cfg.image}@${workload.digest}" else "${cfg.image}:${tag}";
            Policy = "newer";
          };
          containers = {
            ${unit} = {
              # `Restart = "always"` overrides quadlet-nix's `on-failure` default.
              serviceConfig = serverServiceConfig cfg workload;
              unitConfig = sharedUnitConfig // {
                Wants = fetcher;
                After = fetcher ++ entry.after;
              };
              containerConfig =
                baseContainerConfig
                // imageConfig (workload.digest == null)
                // {
                  Notify = "healthy";
                  HealthCmd = "curl --fail --silent --show-error ${healthTarget (listen engine workload)}";
                  HealthStartPeriod = "30m";
                  HealthInterval = "10s";
                  HealthTimeout = "5s";
                  Volume = [
                    (cacheMount cfg.cache.directory [ "ro" ])
                    (cacheMount (unitCacheDirectory unit) [ ])
                  ]
                  ++ entry.mounts
                  ++ lib.optional (
                    workload.socket != null
                  ) "${dirOf workload.socket}:${containerSocketDirectory}${mountSuffix workload.mountOptions.socket}"
                  ++ credentialMount workload.credentials;
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
                // imageConfig false
                // {
                  Entrypoint = lib.toJSON [
                    "/bin/sh"
                    fetchScriptPath
                  ];
                  Volume = [
                    (cacheMount cfg.cache.directory [ ])
                    "${builtins.toFile "fetch.sh" fetch.script}:${fetchScriptPath}:ro"
                  ]
                  ++ credentialMount cfg.fetch.credentials;
                  EnvironmentFile = fetch.environmentFile;
                  Environment = fetch.environment;
                };
            };
          };
        };
    in
    {
      options.services.llmhop.${backend} = base // {
        image = mkOption {
          type = types.str;
          default = engine.quadlet.image;
          description = "Container image of every server.";
        };
        tag = mkOption {
          type = types.str;
          example = engine.quadlet.tagExample;
          description = "Tag of the container image of every model that sets neither `tag` nor `digest`.";
        };
        cache = base.cache // {
          mountOptions = mkOption {
            type = with types; listOf str;
            default = [ ];
            example = [ "idmap" ];
            description = ''
              Options appended to the Quadlet `Volume=` entries of
              `cache.directory` and of each server's own cache directory, for
              Podman ownership mechanisms such as `idmap` or SELinux
              relabeling.
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
                    noun = "model";
                    socket = engine.socketSettings != null;
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
        entries = mkOption {
          type = with types; listOf attrs;
          internal = true;
          default = [ ];
          description = "Workloads served beside the models.";
        };
      };

      config = lib.mkIf cfg.enable (
        lib.mkMerge [
          {
            # Their number depends on the configuration, so they merge below
            # fixed attributes, since a `mkMerge` at the top level would
            # recurse into the configuration it defines.
            virtualisation.quadlet = lib.mkMerge (map quadletConfig entries);
            systemd.tmpfiles.settings."10-${name}" = lib.mkMerge (
              map (e: cacheDirectoryRule cfg.cache (unitCacheDirectory e.workload.unit)) entries
            );
          }
          (sharedConfig {
            inherit
              engine
              backend
              cfg
              pkgs
              entries
              ;
            serviceName = name;
            cacheOwner = cfg.cache;
          })
          {
            assertions = [
              {
                assertion = config.virtualisation.quadlet.enable;
                message = "services.llmhop.${backend} requires virtualisation.quadlet.enable.";
              }
            ];

            # A container maps to no host group known in advance, so its socket
            # is reachable through a default ACL on the root instead. See "Unix
            # sockets" in the module internals documentation.
            systemd.tmpfiles.settings."10-llmhop" = lib.mkIf (lib.any (e: e.workload.socket != null) entries) {
              ${config.services.llmhop.socketDirectory}.a.argument =
                "default:user:${config.services.llmhop.user}:-wx";
            };
          }
        ]
      );
    };
in
{
  inherit
    containerRuntimeDirectory
    listen
    mkBackend
    workloadOptions
    ;
}
