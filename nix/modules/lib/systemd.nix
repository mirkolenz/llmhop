# Units of the native systemd backends.
lib: self:
let
  inherit (self)
    enabledModels
    engine
    environmentFiles
    fetchEnvironment
    fetchScript
    fetchService
    fetchServiceConfig
    fetchUnit
    fetches
    gpuServiceConfig
    hardenedServiceConfig
    hubDirectory
    identityConfig
    mergeCredentialServiceConfig
    mkFetchHooks
    mkModelServices
    mkNativeFetchService
    mkNativeModelService
    mkNativeService
    mkSharedConfig
    mkUpdateService
    modelSettings
    nativeCredentialDirectory
    nativeModelSubmodule
    nativeOptions
    nativeServiceConfig
    nativeWorkloadArgs
    distributedEnvironment
    ncclServiceConfig
    renderCliArgs
    serverEnvironment
    serverServiceConfig
    sharedUnitConfig
    socketRuntimeDirectory
    socketUMask
    sortedModels
    unitCacheDirectory
    unitStateDirectory
    updateUnit
    uvModelSubmodule
    uvOptions
    withUv
    workerUrl
    workloadFlags
    workloadUnit
    ;
in
{

  # The hardened baseline of every native unit, llmhop's own included, running
  # as the identity of `cfg` and binding no IP socket.
  nativeServiceConfig =
    cfg:
    hardenedServiceConfig
    // {
      User = cfg.user;
      Group = cfg.group;
      SocketBindDeny = "any";
    };

  # The fetcher of a native workload: its server's identity and hub, with
  # network access and the backend's `fetch` credentials, but no device.
  mkNativeFetchService =
    {
      serviceName,
      unitName,
      cfg,
      pkgs,
      workload,
    }:
    let
      inherit (engine serviceName) executable;
      hub = hubDirectory cfg;
      # `%d` names the credential directory in `Environment=` too.
      fetch = fetchEnvironment {
        inherit cfg;
        directory = "%d";
      };
    in
    lib.nameValuePair (fetchUnit unitName) {
      description = "Fetch the models of ${unitName}";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = fetch.environment // {
        HOME = "/tmp";
      };
      serviceConfig = mergeCredentialServiceConfig (
        nativeServiceConfig cfg
        // fetchServiceConfig
        // mkFetchHooks {
          inherit pkgs hub;
          inherit (workload) repositories;
          server = unitName;
        }
        // {
          ReadWritePaths = [ cfg.cache.directory ];
          UMask = "0077";
          EnvironmentFile = fetch.environmentFile;
          ExecStart = pkgs.writeShellScript (fetchUnit unitName) (
            "set -e\n"
            + fetchScript {
              inherit hub;
              inherit (workload) repositories;
              backend = serviceName;
              executable = executable.native (workload.package or cfg.package);
            }
          );
        }
      ) cfg.fetch.credentials;
    };

  # The units of any workload of a native backend: its server, with its own
  # cache directory and the shared hardening and readiness baseline, and the
  # fetcher it starts after. Model workers and auxiliary services share it.
  #
  # The server runs offline: one on a socket in a network namespace of its own,
  # one on a port restricted to loopback, and neither with a resolver.
  # `llmhop-notify` keeps the unit activating until `/health` answers.
  mkNativeService =
    {
      serviceName,
      unitName,
      description,
      cfg,
      pkgs,
      utils,
      workload,
      execStart,
      after ? [ ],
      path ? [ ],
      environment ? { },
      serviceConfig ? { },
    }:
    let
      fetcher = lib.optional (fetches workload) (fetchService unitName);
      # `llmhop-notify` is resolved from this flake rather than from
      # `services.llmhop.package`; see the module internals documentation.
      notify = lib.getExe' (pkgs.callPackage ../../package.nix { }) "llmhop-notify";
      offline = lib.optionalAttrs workload.offline;
      mergedServiceConfig =
        serverServiceConfig cfg
        # Its group owns the worker socket, see `systemd.mkConfig`.
        // nativeServiceConfig cfg
        // {
          Restart = "on-failure";
          CacheDirectory = unitName;
          WorkingDirectory = unitCacheDirectory unitName;
          EnvironmentFile = environmentFiles cfg workload;
        }
        // offline {
          InaccessiblePaths = [
            "-/run/nscd"
            "-/run/systemd/resolve"
          ];
        }
        // (
          if workload.socket != null then
            { UMask = socketUMask; } // offline { PrivateNetwork = true; }
          else
            {
              UMask = "0077";
              SocketBindAllow = "tcp:${toString workload.port}";
            }
            // offline {
              IPAddressDeny = "any";
              # Not `localhost`, whose `127.0.0.0/8` includes the resolver
              # stub of systemd-resolved.
              IPAddressAllow = [
                "127.0.0.1"
                "::1"
              ];
            }
        )
        // serviceConfig
        # Last, so the per-workload escape hatch wins over every default.
        // workload.serviceConfig;
    in
    [
      (lib.nameValuePair unitName {
        inherit description path;
        wantedBy = [ "multi-user.target" ];
        wants = fetcher;
        after = fetcher ++ after;
        environment = serverEnvironment {
          inherit cfg workload;
          backend = serviceName;
          unit = unitName;
          environment = {
            HOME = unitCacheDirectory unitName;
          }
          // environment;
        };
        # The lifecycle settings come last, since they implement the readiness
        # supervision.
        serviceConfig = mergeCredentialServiceConfig (
          mergedServiceConfig
          // socketRuntimeDirectory mergedServiceConfig workload.socket
          // {
            KillMode = "control-group";
            Type = "notify";
            ExecStart = lib.replaceStrings [ nativeCredentialDirectory ] [ "%d" ] (
              utils.escapeSystemdExecArgs (
                [
                  notify
                  "-url"
                  (workerUrl workload)
                  "-health-path"
                  "/health"
                ]
                ++ execStart
              )
            );
          }
        ) workload.credentials;
        unitConfig = sharedUnitConfig // workload.unitConfig;
      })
    ]
    ++ lib.optional (fetches workload) (mkNativeFetchService {
      inherit
        serviceName
        unitName
        cfg
        pkgs
        workload
        ;
    });

  # `mkNativeService` for a GPU model worker: device access, the NCCL/RCCL
  # environment, and its own `StateDirectory` for non-regenerable state.
  # `previous` is the preceding model in the ascending startup chain, or null
  # when the backend does not chain.
  mkNativeModelService =
    {
      serviceName,
      cfg,
      pkgs,
      utils,
      model,
      execStart,
      previous ? null,
      path ? [ ],
      environment ? { },
      serviceConfig ? { },
    }:
    let
      unitName = workloadUnit serviceName model;
    in
    mkNativeService {
      inherit
        serviceName
        unitName
        cfg
        pkgs
        utils
        execStart
        path
        ;
      description = "${serviceName} server for ${model.name}";
      workload = model;
      after = lib.optional (previous != null) "${workloadUnit serviceName previous}.service";
      environment = environment // distributedEnvironment;
      serviceConfig = {
        KillSignal = "SIGINT";
        TasksMax = 4096;
        StateDirectory = unitName;
        WorkingDirectory = unitStateDirectory unitName;
      }
      // gpuServiceConfig
      // ncclServiceConfig
      // serviceConfig;
    };

  # The flags a native workload's server receives, the host-side twin of the
  # `Exec` that `mkQuadletWorkload` renders.
  nativeWorkloadArgs =
    {
      backend,
      workload,
      managed,
      settings,
    }:
    renderCliArgs backend (workloadFlags {
      inherit
        backend
        managed
        workload
        settings
        ;
      directory = nativeCredentialDirectory;
      listen = {
        host = "127.0.0.1";
        inherit (workload) port socket;
      };
    });

  # Shared body of `systemd.mkServices`/`mkUvServices`. `wrap` layers a backend
  # flavour (currently `withUv`) onto every worker's args and `previous`
  # resolves the startup chain, or stays null for a backend that does not chain.
  #
  # `command` builds the argv preceding the flags, executable included, and
  # `managed` any managed flags of a model beyond the engine's own
  # `modelSettings`, as `container` does for `quadlet.mkModelWorkloads`.
  mkModelServices =
    {
      serviceName,
      cfg,
      pkgs,
      utils,
      command,
      managed ? (_model: { }),
      models,
      previous ? (_index: null),
      wrap ? lib.id,
      environment ? { },
      serviceConfig ? { },
    }:
    lib.listToAttrs (
      lib.concatLists (
        lib.imap0 (
          index: model:
          mkNativeModelService (wrap {
            inherit
              serviceName
              cfg
              pkgs
              utils
              model
              environment
              serviceConfig
              ;
            previous = previous index;
            execStart =
              command model
              ++ nativeWorkloadArgs {
                backend = serviceName;
                workload = model;
                managed = (engine serviceName).modelSettings model // managed model;
                settings = modelSettings cfg model;
              };
          })
        ) models
      )
    );

  # The `PATH` and environment a backend built from Python wheels
  # needs, layered onto any `mkNativeService`/`mkNativeModelService` arguments.
  # See the module internals documentation for what each entry is for.
  withUv =
    args@{
      pkgs,
      environment ? { },
      ...
    }:
    args
    // {
      path = with pkgs; [
        stdenv.cc
        ninja
        bash
      ];
      environment = {
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
        TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
      }
      // environment;
    };

  systemd = {
    inherit
      nativeServiceConfig
      sharedUnitConfig
      ;

    # A single auxiliary unit of a from-wheel Python backend, for workloads
    # that are not model workers.
    mkUvService = args: mkNativeService (withUv args);

    mkOptions = nativeOptions;
    mkUvOptions = uvOptions;
    mkModelSubmodule = nativeModelSubmodule;
    mkUvModelSubmodule = uvModelSubmodule;

    # One unit per enabled model. Owning the unit name also lets this own the
    # credential directory derived from it, so every `${cred:…}` is resolved
    # here and backends never spell a credential path themselves.
    mkServices = args: mkModelServices (args // { models = lib.attrValues (enabledModels args.cfg); });

    # `mkServices` for a from-wheel Python backend: the uv environment, and
    # workers emitted and chained by ascending `name`.
    mkUvServices =
      args:
      let
        models = sortedModels args.cfg;
      in
      mkModelServices (
        args
        // {
          inherit models;
          wrap = withUv;
          previous =
            index: if args.cfg.startupOrdering && index > 0 then lib.elemAt models (index - 1) else null;
          # These frameworks trap SIGINT to drain the engine and then exit 0, so
          # `on-failure` would leave a crashed worker dead.
          serviceConfig = {
            Restart = "always";
          }
          // args.serviceConfig or { };
        }
      );

    # Cross-cutting NixOS config produced by a systemd backend: registry
    # entries, socket directories, llmhop registration and the update unit.
    # llmhop also joins `group`, which owns the worker sockets.
    # Units are named after the backend itself, and run as its identity.
    mkConfig =
      {
        backend,
        cfg,
        pkgs,
        auxiliaries ? { },
      }:
      let
        update = mkUpdateService {
          inherit cfg pkgs auxiliaries;
          serviceName = backend;
          serviceConfig = nativeServiceConfig cfg // {
            ReadWritePaths = [ cfg.cache.directory ];
            PrivateNetwork = true;
          };
        };
      in
      lib.mkMerge [
        {
          systemd.services.${updateUnit backend} = lib.mkIf (update != null) update;
        }
        (mkSharedConfig {
          inherit
            backend
            cfg
            auxiliaries
            ;
          serviceName = backend;
          cacheOwner = cfg;
        })
        (identityConfig {
          inherit cfg;
          name = backend;
        })
        { services.llmhop.supplementaryGroups = [ cfg.group ]; }
      ];
  };

  # Universal systemd-exec(5) hardening shared between the llmhop reverse proxy
  # and the native model workers. Quadlet workers skip this layer — podman
  # handles isolation at the container level. `SocketBind*` is intentionally
  # absent: it pairs with a per-unit `SocketBindAllow` that only workers set.
  hardenedServiceConfig = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    NoNewPrivileges = true;
    PrivateIPC = true;
    PrivateMounts = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    MemoryDenyWriteExecute = true;
    LockPersonality = true;
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    SystemCallErrorNumber = "EPERM";
    ProtectProc = "invisible";
    ProtectHostname = true;
    ProcSubset = "pid";
  };

  # Relaxations NCCL needs to initialise for multi-GPU / tensor-parallel
  # inference; see the module internals documentation.
  ncclServiceConfig = {
    RestrictAddressFamilies = hardenedServiceConfig.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
    SocketBindAllow = "tcp";
  };

  # Relaxations a GPU worker needs on top of the hardened baseline; the
  # rationale for each is in the module internals documentation.
  gpuServiceConfig = {
    PrivateDevices = false;
    SupplementaryGroups = [
      "render"
      "video"
    ];
    PrivateUsers = "identity";
    MemoryDenyWriteExecute = false;
    LimitMEMLOCK = "infinity";
    ProcSubset = "all";
  };

  # A native unit's credential directory as `${cred:…}` resolves to it. It
  # survives `utils.escapeSystemdExecArgs`, which would turn systemd's `%d`
  # specifier into a literal, and `mkNativeService` swaps it for `%d`
  # afterwards, whichever manager runs the unit.
  nativeCredentialDirectory = "@llmhopCredentialsDirectory@";
}
