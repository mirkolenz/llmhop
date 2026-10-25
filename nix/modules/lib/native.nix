# Units and options of the native systemd backends.
lib: common:
let
  inherit (lib) mkOption types;
  inherit (common)
    backendOptions
    chainEntries
    engines
    environmentFiles
    fetchUnit
    fetcherOf
    fetches
    healthTarget
    identityConfig
    identityOptions
    mkFetcher
    modelModule
    modelsOption
    distributedEnvironment
    serverEnvironment
    serverServiceConfig
    sharedConfig
    sharedUnitConfig
    socketUMask
    sortedWorkloads
    startupOrderingOption
    unitCacheDirectory
    workloadArgs
    ;

  # Universal systemd-exec(5) hardening shared between the llmhop reverse proxy
  # and the native workers. See "Worker hardening" in the module internals
  # documentation.
  hardenedServiceConfig = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    NoNewPrivileges = true;
    PrivateDevices = true;
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

  # A model worker's relaxations for GPUs and for NCCL in tensor-parallel
  # inference, and its own state directory.
  gpuServiceConfig = unit: {
    PrivateDevices = false;
    SupplementaryGroups = [
      "render"
      "video"
    ];
    PrivateUsers = "identity";
    MemoryDenyWriteExecute = false;
    LimitMEMLOCK = "infinity";
    ProcSubset = "all";
    RestrictAddressFamilies = hardenedServiceConfig.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
    SocketBindAllow = "tcp";
    KillSignal = "SIGINT";
    TasksMax = 4096;
    StateDirectory = unit;
    WorkingDirectory = "/var/lib/${unit}";
  };

  # A native unit's credential directory as `${cred:…}` resolves to it. It
  # survives `utils.escapeSystemdExecArgs`, which would turn systemd's `%d`
  # specifier into a literal, and is swapped for `%d` afterwards.
  credentialPlaceholder = "@llmhopCredentialsDirectory@";

  # The hardened baseline of every native unit, llmhop's own included, running
  # as the identity of `cfg` and binding no IP socket.
  serviceConfig =
    cfg:
    hardenedServiceConfig
    // {
      User = cfg.user;
      Group = cfg.group;
      SocketBindDeny = "any";
    };

  # The listener of a native server, on loopback or its socket.
  listen = workload: {
    host = "127.0.0.1";
    inherit (workload) port socket;
  };

  # The NixOS module of the native backend of the engine `name`. Each model
  # runs its internal `command`, which another module may replace, and the
  # internal `entries` add further workloads, each
  # `{ workload, description, command, unlisted }`.
  mkBackend =
    name:
    {
      config,
      pkgs,
      utils,
      ...
    }:
    let
      engine = engines.${name};
      inherit (engine.native) uv;
      cfg = config.services.llmhop.${name};
      entry =
        e:
        {
          unlisted = false;
          after = [ ];
          environment = { };
          # The working directory of a worker and the only port it may bind,
          # unless `gpuServiceConfig` replaces it.
          serviceConfig = {
            WorkingDirectory = unitCacheDirectory e.workload.unit;
          }
          // lib.optionalAttrs (e.workload.port != null) {
            SocketBindAllow = "tcp:${toString e.workload.port}";
          };
        }
        // e;
      modelEntry =
        model:
        entry {
          workload = model;
          description = "${engine.displayName} server for ${model.name}";
          inherit (model) command;
          environment = distributedEnvironment;
          serviceConfig = gpuServiceConfig model.unit;
        };
      entries =
        chainEntries (uv && cfg.startupOrdering) (e: "${e.workload.unit}.service") (
          map modelEntry (sortedWorkloads cfg.models)
        )
        ++ map entry cfg.entries;

      # The units of the workload of `entry`: its offline server and the
      # fetcher it starts after. The `environment` and `serviceConfig` of
      # `entry` extend the server's. See "Offline servers" and "Python
      # backends built from wheels" in the module internals documentation.
      units =
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
              ;
            server = unit;
            fetcher = engine.native.fetcher workload.package;
            # `%d` names the credential directory in `Environment=` too.
            credentialDirectory = "%d";
          };
          offline = lib.optionalAttrs workload.offline;
          # A socket's own network namespace, or else loopback only.
          network =
            if workload.socket != null then
              { UMask = socketUMask; } // offline { PrivateNetwork = true; }
            else
              {
                UMask = "0077";
              }
              // offline {
                IPAddressDeny = "any";
                # Not `localhost`, whose `127.0.0.0/8` includes the resolver
                # stub of systemd-resolved.
                IPAddressAllow = [
                  "127.0.0.1"
                  "::1"
                ];
              };
        in
        [
          (lib.nameValuePair unit {
            inherit (entry) description;
            path = lib.optionals uv (
              with pkgs;
              [
                stdenv.cc
                ninja
                bash
              ]
            );
            wantedBy = [ "multi-user.target" ];
            wants = fetcher;
            after = fetcher ++ entry.after;
            environment = serverEnvironment {
              inherit engine cfg workload;
              environment = {
                HOME = unitCacheDirectory unit;
              }
              // lib.optionalAttrs uv {
                LD_LIBRARY_PATH = "/run/opengl-driver/lib";
                TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
              }
              // entry.environment;
            };
            # Holds the unit in `activating` until the server answers `/health`
            # with 200, and fails it once the server exits before that.
            postStart = ''
              while kill -0 "$MAINPID" 2>/dev/null; do
                status=$(${lib.getExe pkgs.curl} --silent --output /dev/null --write-out '%{http_code}' --max-time 10 ${healthTarget (listen workload)} || true)
                if [[ $status == 200 ]]; then
                  exit 0
                fi
                sleep 1
              done
              echo "the server exited before it answered /health" >&2
              exit 1
            '';
            unitConfig = sharedUnitConfig;
            serviceConfig =
              serverServiceConfig cfg workload
              # Its group owns the worker socket, which llmhop joins.
              // serviceConfig cfg
              // {
                CacheDirectory = unit;
                EnvironmentFile = environmentFiles cfg workload;
              }
              // offline {
                InaccessiblePaths = [
                  "-/run/nscd"
                  "-/run/systemd/resolve"
                ];
              }
              // network
              // entry.serviceConfig
              // {
                Type = "exec";
                ExecStart = lib.replaceStrings [ credentialPlaceholder ] [ "%d" ] (
                  utils.escapeSystemdExecArgs (entry.command ++ workloadArgs engine credentialPlaceholder workload)
                );
              };
          })
        ]
        # The fetcher shares its server's identity and hub, with network access
        # and the backend's `fetch` credentials.
        ++ lib.optional (fetches workload) (
          lib.nameValuePair (fetchUnit unit) {
            description = "Fetch the models of ${unit}";
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];
            environment = fetch.environment // {
              HOME = "/tmp";
            };
            serviceConfig =
              serviceConfig cfg
              // fetch.serviceConfig
              // {
                ReadWritePaths = [ cfg.cache.directory ];
                UMask = "0077";
                EnvironmentFile = fetch.environmentFile;
                ExecStart = pkgs.writeShellScript (fetchUnit unit) fetch.script;
              };
          }
        );
    in
    {
      options.services.llmhop.${name} =
        backendOptions {
          serviceName = name;
          inherit engine;
        }
        // identityOptions {
          inherit name cfg;
          prefix = "services.llmhop.${name}";
        }
        // {
          package =
            if uv then
              mkOption {
                type = types.package;
                description = ''
                  Package providing ${engine.native.packageEntry}.

                  No default on purpose: ${engine.displayName} has no
                  one-derivation-fits-all, so build it from a uv workspace with
                  the flake's `mkUvEnv`, as in
                  `inputs.llmhop.legacyPackages.''${pkgs.system}.mkUvEnv { workspaceRoot = ./${name}-env; }`.
                '';
              }
            else
              lib.mkPackageOption pkgs name { };

          models = modelsOption {
            inherit engine;
            modules = [
              (modelModule {
                inherit engine listen;
                extraRepositories = engine.native.repositories;
                unitPrefix = name;
                socketDirectory = config.services.llmhop.socketDirectory;
                defaults = cfg.modelSettings;
              })
              (
                { config, ... }:
                {
                  options = {
                    package = mkOption {
                      type = types.package;
                      default = cfg.package;
                      defaultText = lib.literalExpression "config.services.llmhop.${name}.package";
                      description = ''
                        Package providing this model's server, overriding the
                        backend-wide `package`, e.g. a nightly build for a
                        just-released architecture.
                      '';
                    };
                    command = mkOption {
                      type = with types; listOf (either str package);
                      internal = true;
                      default = engine.native.command config;
                      description = "Command of this model's server, followed by its settings.";
                    };
                  };
                }
              )
            ];
            description = ''
              Models to serve, each as the hardened system service
              `${name}-<name>` beside its fetcher `${name}-<name>-fetch`.
            '';
          };

          entries = mkOption {
            type = with types; listOf attrs;
            internal = true;
            default = [ ];
            description = "Workloads served beside the models.";
          };
        }
        // lib.optionalAttrs uv {
          startupOrdering = startupOrderingOption "via `environment`, e.g. `CUDA_VISIBLE_DEVICES`";
        };

      config = lib.mkIf cfg.enable (
        lib.mkMerge [
          { systemd.services = lib.listToAttrs (lib.concatMap units entries); }
          # llmhop joins `group`, which owns the worker sockets.
          {
            systemd.services.llmhop.serviceConfig.SupplementaryGroups = lib.mkIf config.services.llmhop.enable [
              cfg.group
            ];
          }
          (sharedConfig {
            inherit
              engine
              cfg
              pkgs
              entries
              ;
            backend = name;
            serviceName = name;
            cacheOwner = cfg;
            updateServiceConfig = serviceConfig cfg // {
              ReadWritePaths = [ cfg.cache.directory ];
              PrivateNetwork = true;
            };
          })
          (identityConfig { inherit name cfg; })
        ]
      );
    };
in
{
  inherit listen mkBackend serviceConfig;
}
