# The native systemd backend of the engine `name` under
# `services.llmhop.<name>`. Every workload runs its internal `command`,
# followed by its settings, as a hardened service beside its fetcher.
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
  inherit (engine.native) uv;
  cfg = config.services.llmhop.${name};

  # A model's relaxations for GPUs and for NCCL in tensor-parallel inference,
  # and its own state directory. See "GPU relaxations" and "NCCL relaxations"
  # in the module internals documentation.
  gpuServiceConfig = workload: {
    PrivateDevices = false;
    SupplementaryGroups = [
      "render"
      "video"
    ];
    PrivateUsers = "identity";
    MemoryDenyWriteExecute = false;
    LimitMEMLOCK = "infinity";
    ProcSubset = "all";
    RestrictAddressFamilies = util.hardenedServiceConfig.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
    SocketBindAllow = "tcp";
    KillSignal = "SIGINT";
    TasksMax = 4096;
    StateDirectory = "${name}/${workload.name}";
    WorkingDirectory = "/var/lib/${name}/${workload.name}";
  };

  # An auxiliary service works in its cache directory and may bind only its
  # own port.
  auxiliaryServiceConfig =
    workload:
    {
      WorkingDirectory = shared.cacheDirectory cfg workload;
    }
    // lib.optionalAttrs (workload.port != null) {
      SocketBindAllow = "tcp:${toString workload.port}";
    };

  # The units of `workload`: its offline server, started after `after`, and the
  # fetcher it starts after. See "Offline servers" and "Python backends built
  # from wheels" in the module internals documentation.
  units =
    workload: after:
    let
      inherit (workload) unit;
      cache = shared.cacheDirectory cfg workload;
      fetch = shared.fetchUnitConfig {
        inherit
          engine
          cfg
          workload
          ;
        inherit (util) credentialDirectory;
        fetcher = engine.native.fetcher workload.package;
      };
      offline = lib.optionalAttrs workload.offline;
      # A socket's own network namespace, or else loopback only, unless
      # the server listens beyond it.
      network =
        if workload.socket != null then
          { UMask = shared.socketUMask; } // offline { PrivateNetwork = true; }
        else
          {
            UMask = "0077";
          }
          // lib.optionalAttrs (workload.offline && util.isLoopback workload.host) {
            IPAddressDeny = "any";
            # Not `localhost`, whose `127.0.0.0/8` includes the resolver
            # stub of systemd-resolved.
            IPAddressAllow = [
              "127.0.0.1"
              "::1"
            ];
          };
    in
    {
      ${unit} = {
        inherit (workload) description;
        path = lib.optionals uv (
          with pkgs;
          [
            stdenv.cc
            ninja
            bash
          ]
        );
        wantedBy = [ "multi-user.target" ];
        wants = shared.fetchServices workload;
        after = shared.fetchOrder workload ++ after;
        environment = shared.serverEnvironment {
          inherit engine cfg workload;
          inherit (util) credentialDirectory;
          environment = {
            HOME = cache;
          }
          // lib.optionalAttrs uv {
            LD_LIBRARY_PATH = "/run/opengl-driver/lib";
            TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
          };
        };
        unitConfig = util.startLimitConfig;
        serviceConfig =
          shared.serverServiceConfig cfg workload
          # Its group owns the worker socket, which every client joins.
          // util.accountServiceConfig cfg
          // {
            ReadWritePaths = [ cache ];
            ReadOnlyPaths = shared.hubDirectories cfg workload;
            EnvironmentFile = shared.environmentFiles cfg workload;
          }
          // offline {
            InaccessiblePaths = [
              "-/run/nscd"
              "-/run/systemd/resolve"
            ];
          }
          // network
          // (if workload.unlisted then auxiliaryServiceConfig workload else gpuServiceConfig workload)
          // {
            Type = "exec";
            ExecStart = util.execStart utils workload.credentials (
              workload.command ++ util.renderCliArgs engine workload.settings
            );
            # Holds the unit in `activating` until the server answers
            # `/health`, and fails it once the server exits before that.
            ExecStartPost = utils.escapeSystemdExecArgs [
              (lib.getExe (util.package pkgs))
              "wait-healthy"
              (util.probeUrl workload)
            ];
          };
      };
    }
    # The fetcher shares its server's identity and cache, with network access
    # and the backend's `fetch` credentials.
    // lib.optionalAttrs (shared.fetches workload) {
      ${shared.fetchUnit unit} = {
        description = "Fetch the models of ${unit}";
        inherit (fetch) unitConfig;
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment = fetch.environment // {
          HOME = "/tmp";
        };
        serviceConfig =
          util.accountServiceConfig cfg
          // fetch.serviceConfig
          // {
            ReadWritePaths = [ cache ];
            UMask = "0077";
            EnvironmentFile = fetch.environmentFile;
            ExecStart = pkgs.writeShellScript (shared.fetchUnit unit) fetch.script;
          };
      };
    };

  models = shared.sortedWorkloads cfg.models;
  workloads = models ++ cfg.extraWorkloads;
in
{
  options.services.llmhop.${name} =
    opts.backendOptions engine
    // util.identityOptions {
      inherit name cfg;
      prefix = "services.llmhop.${name}";
    }
    // {
      package =
        if uv then
          mkOption {
            type = types.package;
            description = ''
              Package providing ${engine.native.packageEntry}, built from
              a uv workspace with the flake's `mkUvEnv`, as in
              `inputs.llmhop.legacyPackages.''${pkgs.system}.mkUvEnv { workspaceRoot = ./${name}-env; }`.
            '';
          }
        else
          lib.mkPackageOption pkgs name { };

      models =
        opts.modelsOption
          {
            inherit engine;
            description = ''
              Models to serve, each as the hardened system service
              `${name}-<name>` beside its fetcher `${name}-<name>-fetch`.
            '';
          }
          [
            (opts.workloadModule {
              inherit engine;
              noun = "model";
              inherit (config.services.llmhop) socketDirectory;
              listener = lib.id;
              derivedSettings = engine.modelSettings;
              defaults = cfg.modelSettings;
            })
            (opts.modelModule {
              inherit engine;
              extraRepositories = engine.native.repositories;
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
    }
    // lib.optionalAttrs uv {
      startupOrdering = opts.startupOrderingOption "via `environment`, e.g. `CUDA_VISIBLE_DEVICES`";
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        systemd.services = lib.mkMerge (
          lib.zipListsWith units models (shared.predecessors (uv && cfg.startupOrdering) models)
          ++ map (workload: units workload [ ]) cfg.extraWorkloads
        );
        # Every socket client joins `group`, which owns the worker sockets.
        users.users = lib.mkIf (lib.any (w: w.socket != null) workloads) (
          lib.genAttrs config.services.llmhop.socketClients (_: {
            extraGroups = [ cfg.group ];
          })
        );
      }
      (shared.backendConfig {
        systemd = config.systemd.package;
        inherit
          pkgs
          utils
          engine
          cfg
          workloads
          ;
        backend = name;
        cacheOwner = cfg;
      })
      (util.identityConfig { inherit name cfg; })
    ]
  );
}
