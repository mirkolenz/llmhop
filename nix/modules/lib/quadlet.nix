# Units of the Quadlet backends.
lib: self:
let
  inherit (self)
    appendList
    containerRuntimeDirectory
    containerSocketDirectory
    containerSocketPath
    credentialDirectory
    enabledModels
    engine
    environmentFiles
    fetchEnvironment
    fetchScript
    fetchService
    fetchServiceConfig
    fetchUnit
    fetches
    hostPort
    hubDirectory
    mergeCredentialServiceConfig
    mkFetchHooks
    mkQuadletContainer
    mkQuadletImage
    mkQuadletImageOptions
    mkQuadletObjectOptions
    mkQuadletWorker
    mkQuadletWorkload
    mkSharedConfig
    mkUpdateService
    modelSettings
    distributedEnvironment
    quadletImageConfig
    quadletModelSubmodule
    quadletMountSuffix
    quadletOptions
    quadletService
    quadletServiceName
    quadletUid
    renderCliArgsWith
    serverEnvironment
    serverServiceConfig
    sharedUnitConfig
    socketDirectoryMode
    socketName
    socketRuntimeDirectory
    socketUMask
    sortedModels
    unitCacheDirectory
    updateUnit
    workloadFlags
    workloadUnit
    ;
in
{
  quadletMountSuffix =
    options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

  # The image unit pulling `image` for a workload at its mutually exclusive
  # `tag` or `digest`, else at `defaultTag`. `newer` keeps the local image
  # when the registry is unreachable, where Podman's default `always` would
  # fail its containers.
  mkQuadletImage =
    {
      cfg,
      image,
      defaultTag,
      workload,
      label,
    }:
    {
      uid = quadletUid cfg;
      imageConfig = {
        Image =
          if workload.tag != null && workload.digest != null then
            throw "${label}: `tag` and `digest` are mutually exclusive."
          else if workload.digest != null then
            "${image}@${workload.digest}"
          else
            "${image}:${lib.defaultTo defaultTag workload.tag}";
        Policy = "newer";
      };
    };

  # `[Container]` settings of a container running the image of the image unit
  # `image`, which pulls on its behalf. With `autoUpdate`, `podman auto-update`
  # keeps its tag current, restarting the container when the tag moved.
  quadletImageConfig =
    image: autoUpdate:
    {
      Image = image.ref;
      Pull = "never";
    }
    // lib.optionalAttrs autoUpdate { AutoUpdate = "registry"; };

  # The systemd service of the Quadlet container `unit`.
  quadletService =
    config: unit: "${config.virtualisation.quadlet.containers.${unit}.serviceName}.service";

  # The user manager owning a quadlet backend's units, or null for root.
  quadletUid = cfg: if cfg.quadlet.user != null then cfg.quadlet.user.uid else null;

  # Render a Quadlet container fragment with the backend's identity, minimal
  # hardening (podman handles the rest), the credential mount and the native
  # Quadlet section overrides, layered globally and then per container. The
  # rootfs stays writable; `/tmp` is a tmpfs for fast scratch.
  #
  # A container binding the host `socket` gets its directory mounted, which a
  # rootless one needs `podman` to clear. See "Unix sockets" in the module
  # internals documentation.
  #
  # A `companion` of a server, its fetcher, only takes the keys that
  # set who it runs as from the overrides, so that it sees the server's files
  # alike, while the overrides otherwise configure the server alone.
  mkQuadletContainer =
    {
      cfg,
      overrides,
      companion ? false,
      credentials ? { },
      socket ? null,
      podman ? null,
      mounts ? [ ],
      serviceConfig ? { },
      unitConfig ? { },
      containerConfig ? { },
    }:
    let
      rootless = cfg.quadlet.user != null;
      # The `[Container]` keys that set who a container runs as.
      identityKeys = [
        "User"
        "Group"
        "GroupAdd"
        "UserNS"
        "UIDMap"
        "GIDMap"
        "SubUIDMap"
        "SubGIDMap"
      ];
      scope =
        layer:
        if companion then
          {
            containerConfig = lib.filterAttrs (key: _: lib.elem key identityKeys) layer.containerConfig;
            serviceConfig = { };
            unitConfig = { };
            quadletConfig = { };
            extraConfig = { };
          }
        else
          layer;
      global = scope cfg.quadlet;
      own = scope overrides;
      # Appended after every override, so a user `Volume` cannot drop them.
      allMounts =
        mounts
        ++ lib.optional (
          socket != null
        ) "${dirOf socket}:${containerSocketDirectory}${quadletMountSuffix overrides.mountOptions.socket}"
        ++
          lib.optional (credentials != { })
            "%d:${credentialDirectory}${quadletMountSuffix ([ "ro" ] ++ overrides.mountOptions.credentials)}";
      mergedServiceConfig =
        lib.optionalAttrs (socket != null && rootless) {
          ExecStartPre = "${lib.getExe podman} unshare rm -f ${socket}";
        }
        // serviceConfig
        // global.serviceConfig
        // own.serviceConfig;
      mergedContainerConfig = {
        NoNewPrivileges = true;
        DropCapability = "all";
        Tmpfs = [ "/tmp" ];
      }
      // containerConfig
      // global.containerConfig
      // own.containerConfig;
    in
    {
      uid = quadletUid cfg;
      serviceConfig = mergeCredentialServiceConfig (
        mergedServiceConfig
        // lib.optionalAttrs (!rootless) (socketRuntimeDirectory mergedServiceConfig socket)
      ) credentials;
      unitConfig = sharedUnitConfig // unitConfig // global.unitConfig // own.unitConfig;
      quadletConfig = global.quadletConfig // own.quadletConfig;
      extraConfig = lib.recursiveUpdate global.extraConfig own.extraConfig;
      containerConfig =
        mergedContainerConfig
        // lib.optionalAttrs (allMounts != [ ]) {
          Volume = appendList mergedContainerConfig "Volume" allMounts;
        }
        # Quadlet's own `Umask=` is newer than podman 6.1.
        // lib.optionalAttrs (socket != null) {
          PodmanArgs = appendList mergedContainerConfig "PodmanArgs" [ "--umask=${socketUMask}" ];
        };
    };

  # A long-running `mkQuadletContainer` with an HTTP readiness probe.
  #
  # The server binds the host `socket` mounted into the container, else
  # `containerPort`, published on the host `port` unless that is null (host
  # networking). The health probe reaches a server bound to `bindAddress`,
  # through loopback for a wildcard.
  mkQuadletWorker =
    args@{
      cfg,
      containerPort,
      port ? null,
      socket ? null,
      bindAddress ? "localhost",
      healthTLS ? false,
      healthStartPeriod ? "30m",
      serviceConfig ? { },
      containerConfig ? { },
      ...
    }:
    let
      healthScheme = if healthTLS then "https" else "http";
      healthHost =
        {
          "0.0.0.0" = "127.0.0.1";
          "::" = "::1";
        }
        .${bindAddress} or bindAddress;
    in
    mkQuadletContainer (
      removeAttrs args [
        "containerPort"
        "port"
        "bindAddress"
        "healthTLS"
        "healthStartPeriod"
      ]
      // {
        serviceConfig =
          serverServiceConfig cfg
          // {
            # `Restart = "always"` overrides quadlet-nix's `on-failure` default;
            # see the module internals documentation.
            Restart = "always";
          }
          // serviceConfig;
        containerConfig = {
          Notify = "healthy";
          HealthCmd = "curl --fail --silent --show-error ${lib.optionalString healthTLS "--insecure "}${
            if socket != null then
              "--unix-socket ${containerSocketPath} ${healthScheme}://localhost"
            else
              "${healthScheme}://${hostPort healthHost containerPort}"
          }/health";
          HealthStartPeriod = healthStartPeriod;
          HealthInterval = "10s";
          HealthTimeout = "5s";
        }
        // lib.optionalAttrs (port != null) {
          PublishPort = [ "127.0.0.1:${toString port}:${toString containerPort}" ];
        }
        // containerConfig;
      }
    );

  # The NixOS configuration of one workload of a quadlet backend, named after
  # `unit`: its offline server, which runs `arguments` followed by `settings`
  # rendered as `backend`'s flags under `managed` and the listener, its
  # fetcher, the image unit pulling for both, and the server's own cache
  # directory, which systemd-tmpfiles hands to `cache.user` rather than
  # `CacheDirectory=` to the user running Podman. `collection` is the attribute of
  # `services.llmhop.<backend>` holding the workload, so models and auxiliaries
  # such as watermark detectors share it. `after` orders the server after
  # other units.
  #
  # A server on a socket runs without a network, one on a port stays in
  # Podman's default network. See "Offline servers" in the module internals
  # documentation.
  mkQuadletWorkload =
    {
      backend,
      cfg,
      config,
      pkgs,
      unit,
      collection,
      workload,
      containerPort,
      settings,
      managed ? { },
      arguments ? [ ],
      environment ? { },
      containerConfig ? { },
      mounts ? [ ],
      serviceConfig ? { },
      after ? [ ],
    }:
    let
      inherit (engine backend) executable;
      inherit (config.virtualisation.quadlet) containers images podman;
      serviceName = quadletServiceName backend;
      hub = hubDirectory cfg;
      cache = unitCacheDirectory unit;
      # Where a fetcher container finds its script.
      fetchScriptPath = "${containerRuntimeDirectory}/fetch.sh";
      # A host directory mounted at the same path.
      cacheMount =
        directory: options:
        "${directory}:${directory}${quadletMountSuffix (options ++ cfg.cache.mountOptions)}";
      # The listener in the shape `listenSettings` takes, on `containerPort`
      # or the mounted socket.
      listen = {
        host = "0.0.0.0";
        port = containerPort;
        socket = if workload.socket != null then containerSocketPath else null;
      };
      fetcherService = lib.optional (fetches workload) (fetchService unit);
      fetch = fetchEnvironment {
        inherit cfg;
        directory = credentialDirectory;
      };
      # Named after its tag or digest, so that workloads sharing an image share
      # the unit.
      imageName = "${serviceName}-${
        if workload.digest != null then
          lib.substring 0 12 (lib.last (lib.splitString ":" workload.digest))
        else
          lib.defaultTo cfg.tag workload.tag
      }";
    in
    {
      systemd.tmpfiles.settings."10-${serviceName}".${cache}.d = {
        inherit (cfg.cache) user group;
        mode = "0700";
      };
      # Defined alike by every workload that shares the image.
      virtualisation.quadlet.images.${imageName} = mkQuadletImage {
        inherit cfg workload;
        inherit (cfg) image;
        defaultTag = cfg.tag;
        label = "services.llmhop.${backend}.${collection}.${workload.name}";
      };
      virtualisation.quadlet.containers = {
        ${unit} = mkQuadletWorker {
          inherit
            cfg
            mounts
            podman
            serviceConfig
            ;
          inherit (workload) credentials port socket;
          overrides = workload.quadlet;
          inherit containerPort;
          bindAddress = listen.host;
          unitConfig = {
            Wants = fetcherService;
            After = fetcherService ++ after;
          };
          containerConfig =
            quadletImageConfig images.${imageName} (workload.digest == null)
            // {
              Volume = [
                (cacheMount cfg.cache.directory [ "ro" ])
                (cacheMount cache [ ])
              ];
              EnvironmentFile = environmentFiles cfg workload;
              Environment = serverEnvironment {
                inherit
                  backend
                  cfg
                  workload
                  unit
                  ;
                environment = (engine backend).containerEnvironment // environment;
              };
            }
            // lib.optionalAttrs (workload.socket != null && workload.offline) { Network = "none"; }
            // containerConfig
            // {
              Exec = lib.escapeShellArgs (
                arguments
                ++ renderCliArgsWith "=" backend (workloadFlags {
                  inherit
                    backend
                    managed
                    workload
                    settings
                    ;
                  directory = credentialDirectory;
                  inherit listen;
                })
              );
            };
        };
      }
      // lib.optionalAttrs (fetches workload) {
        ${fetchUnit unit} = mkQuadletContainer {
          inherit cfg;
          overrides = workload.quadlet;
          companion = true;
          credentials = cfg.fetch.credentials;
          mounts = [
            (cacheMount cfg.cache.directory [ ])
            "${
              builtins.toFile "fetch.sh" (fetchScript {
                inherit backend hub;
                inherit (workload) repositories;
                executable = executable.container;
              })
            }:${fetchScriptPath}:ro"
          ];
          serviceConfig =
            fetchServiceConfig
            // mkFetchHooks {
              inherit pkgs hub;
              inherit (workload) repositories;
              server = containers.${unit}.serviceName;
              user = cfg.quadlet.user != null;
            };
          containerConfig = quadletImageConfig images.${imageName} false // {
            Entrypoint = lib.toJSON [
              "/bin/sh"
              "-e"
              fetchScriptPath
            ];
            EnvironmentFile = fetch.environmentFile;
            Environment = fetch.environment;
          };
        };
      };
    };

  quadlet = {
    mkObjectOptions = mkQuadletObjectOptions;
    mkImage = mkQuadletImage;
    imageConfig = quadletImageConfig;
    mkWorker = mkQuadletWorker;
    mkWorkload = mkQuadletWorkload;

    # Merges the fragments of `mkWorkload`. Their number depends on the
    # configuration, so they merge below fixed attributes, since a `mkMerge`
    # at the top level would recurse into the configuration it defines.
    mergeWorkloads = fragments: {
      virtualisation.quadlet = lib.mkMerge (map (f: f.virtualisation.quadlet) fragments);
      systemd.tmpfiles.settings = lib.mkMerge (map (f: f.systemd.tmpfiles.settings) fragments);
    };
    mkImageOptions = mkQuadletImageOptions;
    mkOptions = quadletOptions;
    mkModelSubmodule = quadletModelSubmodule;
    service = quadletService;

    # The units of every enabled model of a quadlet backend, as a list of
    # NixOS configuration fragments: sorted by ascending `name`, each
    # server on its socket or loopback port and chained on its predecessor, and
    # with every `${cred:…}` in its settings already resolved.
    #
    # `container` builds a model's optional `mkWorkload` extras: `managed`,
    # flags beyond the engine's `modelSettings`, `arguments`, the positional
    # argv preceding them, `containerConfig`, its `[Container]` extras such as
    # `Entrypoint`, and `mounts`, its extra volumes.
    # `workerPort` is the container-side port of a server in its own network.
    mkModelWorkloads =
      {
        backend,
        cfg,
        config,
        pkgs,
        workerPort,
        container ? (_model: { }),
      }:
      let
        serviceName = quadletServiceName backend;
        models = sortedModels cfg;
      in
      lib.imap0 (
        index: model:
        let
          extras = container model;
        in
        mkQuadletWorkload (
          extras
          // {
            inherit
              backend
              cfg
              config
              pkgs
              ;
            unit = workloadUnit serviceName model;
            collection = "models";
            workload = model;
            containerPort = workerPort;
            managed = (engine backend).modelSettings model // extras.managed or { };
            settings = modelSettings cfg model;
            environment = distributedEnvironment;
            containerConfig = {
              AddDevice = model.devices;
              ShmSize = model.shmSize;
              Ulimit = "host";
            }
            // extras.containerConfig or { };
            # Each server waits on its predecessor so GPU-memory profiling
            # never overlaps.
            after = lib.optional (cfg.startupOrdering && index > 0) (
              quadletService config (workloadUnit serviceName (lib.elemAt models (index - 1)))
            );
          }
        )
      ) models;

    # Cross-cutting NixOS config produced by every quadlet backend:
    # the quadlet-enabled assertion, llmhop registration, resource registries,
    # cache and socket directories, and the optional rootless account.
    #
    # `auxiliaries` describes the non-model services this backend runs; see
    # `mkSharedConfig`.
    mkConfig =
      {
        backend,
        cfg,
        config,
        pkgs,
        auxiliaries ? { },
      }:
      let
        serviceName = quadletServiceName backend;
        user = cfg.quadlet.user;
        # Enabled models and auxiliaries that bind a unix socket.
        sockets = lib.filter (w: w.socket or null != null) (
          lib.attrValues (enabledModels cfg) ++ lib.attrValues auxiliaries
        );
        update = mkUpdateService {
          inherit
            serviceName
            cfg
            pkgs
            auxiliaries
            ;
          user = user != null;
          # A rootless user's files belong to its subordinate IDs, which only
          # its user namespace may delete.
          pruneWrapper = lib.optionals (user != null) [
            (lib.getExe config.virtualisation.quadlet.podman)
            "unshare"
          ];
        };
      in
      lib.mkMerge [
        (mkSharedConfig {
          inherit
            backend
            serviceName
            cfg
            auxiliaries
            ;
          cacheOwner = cfg.cache;
        })
        (lib.mkIf (user == null && update != null) {
          systemd.services.${updateUnit serviceName} = update;
        })
        (lib.mkIf (user != null && update != null) {
          systemd.user.services.${updateUnit serviceName} = update // {
            unitConfig.ConditionUser = user.uid;
          };
          systemd.user.timers.${updateUnit serviceName} = lib.mkIf (cfg.fetch.interval != null) {
            unitConfig.ConditionUser = user.uid;
          };
        })
        {
          assertions = [
            {
              assertion = config.virtualisation.quadlet.enable;
              message = "services.llmhop.${backend} requires virtualisation.quadlet.enable.";
            }
            {
              # The unit registry only catches twins that also share a model
              # name. They collide at the backend level regardless: both emit
              # `${serviceName}-<model>` units and both own
              # `${cfg.cache.directory}`, which this backend hands to its own
              # (possibly root-owned) account with mode 0700.
              assertion = !config.services.llmhop.${serviceName}.enable;
              message = "services.llmhop.${backend} and services.llmhop.${serviceName} are mutually exclusive: they emit the same `${serviceName}-<model>` unit names and share the `${serviceName}` cache directory.";
            }
          ];

          # Rootless socket directories of every workload, see
          # `mkQuadletContainer`.
          systemd.tmpfiles.settings."10-${serviceName}" = lib.mkIf (user != null) (
            lib.listToAttrs (
              map (
                w:
                lib.nameValuePair (dirOf w.socket) {
                  d = {
                    inherit (user) group;
                    user = user.name;
                    mode = socketDirectoryMode;
                  };
                }
              ) sockets
            )
          );

          # A container maps to no host group known in advance, so its socket
          # is reachable through a default ACL on the root instead. See "Unix
          # sockets" in the module internals documentation.
          systemd.tmpfiles.settings."10-llmhop" = lib.mkIf (sockets != [ ]) {
            ${config.services.llmhop.socketDirectory}.a.argument =
              "default:user:${config.services.llmhop.user}:-wx";
          };
        }
        (lib.mkIf (user != null && user.manage) {
          users.users.${user.name} = {
            description = "${serviceName} container service user";
            inherit (user) uid group home;
            isSystemUser = true;
            createHome = true;
            linger = true;
            # Rootless Podman needs subordinate IDs; `mkDefault` leaves the
            # native `users.users.<name>.subUidRanges` route open.
            autoSubUidGidRange = lib.mkDefault true;
          };
          users.groups.${user.group}.gid = user.gid;
        })
      ];
  };

  # Where a container sees its socket directory. Beside, not over, the
  # credential mount.
  containerSocketDirectory = "${containerRuntimeDirectory}/socket";
  containerSocketPath = "${containerSocketDirectory}/${socketName}";
}
