# The native units of the backend `backend` of `common.nix`, each workload a
# hardened system service beside its fetcher.
{
  backend,
  config,
  lib,
  pkgs,
  utils,
}:
let
  util = import ../lib.nix lib;
  llmhop = config.services.llmhop;
  inherit (backend)
    name
    engine
    cfg
    socketUMask
    cacheDirectory
    hubDirectories
    fetchUnit
    fetchServices
    fetchOrder
    fetch
    serverServiceConfig
    serverEnvironment
    environmentFiles
    ;
  inherit (engine.native) uv;

  # The services of `workload`: its offline server, started after `after`, and
  # the fetcher it starts after, which shares its identity and cache, with
  # network access and the backend's `fetch` credentials. See "Offline
  # servers" and "Python backends built from wheels" in the module internals
  # documentation.
  services =
    workload: after:
    let
      inherit (workload) unit;
      cache = cacheDirectory workload;
      fetcher = fetch workload;
      offline = lib.optionalAttrs workload.offline;
      # Only a server with network access waits for it, to download at
      # runtime or to bind beyond loopback.
      online = lib.optional (!workload.offline) "network-online.target";
      # A model's relaxations for GPUs and for NCCL in tensor-parallel inference,
      # and its own state directory, while an auxiliary service works in its
      # cache directory and may bind only its own port. See "GPU relaxations" and
      # "NCCL relaxations" in the module internals documentation.
      relaxations =
        if workload.kind == "detector" then
          {
            WorkingDirectory = cacheDirectory workload;
          }
          // lib.optionalAttrs (workload.port != null) {
            SocketBindAllow = "tcp:${toString workload.port}";
          }
        else
          {
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
          }
          // lib.optionalAttrs (workload.native.devices != null) {
            DevicePolicy = "closed";
            DeviceAllow = workload.native.devices;
          };
      # Offline, a socket's own network namespace, or else loopback only, which
      # `isolable` guarantees the port is bound to. Not `localhost`, whose
      # `127.0.0.0/8` includes the resolver stub of systemd-resolved.
      network =
        if workload.socket != null then
          { UMask = socketUMask; } // offline { PrivateNetwork = true; }
        else
          {
            UMask = "0077";
          }
          // offline {
            IPAddressDeny = "any";
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
        wants = fetchServices workload ++ online;
        after = fetchOrder workload ++ after ++ online;
        environment = serverEnvironment workload (
          {
            HOME = cache;
          }
          // lib.optionalAttrs uv {
            LD_LIBRARY_PATH = "/run/opengl-driver/lib";
            TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
          }
        );
        unitConfig = util.startLimitConfig;
        serviceConfig =
          serverServiceConfig workload
          # Its group owns the worker socket, which every client joins.
          // util.accountServiceConfig cfg
          // {
            ReadWritePaths = [ cache ];
            ReadOnlyPaths = hubDirectories workload;
            EnvironmentFile = environmentFiles workload;
          }
          // offline {
            InaccessiblePaths = [
              "-/run/nscd"
              "-/run/systemd/resolve"
            ];
          }
          // network
          // relaxations
          // {
            Type = "exec";
            ExecStart = util.execStart utils workload.credentials (
              workload.command ++ util.renderCliArgs engine workload.settings
            );
            # Holds the unit in `activating` until the server answers its health
            # path, and fails it once the server exits before that. systemd
            # expands `$MAINPID`, which escaping would turn into a literal.
            ExecStartPost = "${
              utils.escapeSystemdExecArgs [
                (lib.getExe llmhop.package)
                "internal"
                "wait-healthy"
              ]
            } $MAINPID ${
              utils.escapeSystemdExecArgs [
                (util.probeUrl workload)
                util.healthPath
              ]
            }";
          };
      };
    }
    // lib.optionalAttrs workload.fetches {
      ${fetchUnit workload} = {
        description = "Fetch the models of ${unit}";
        inherit (fetcher) unitConfig;
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment = fetcher.environment // {
          HOME = "/tmp";
        };
        serviceConfig =
          util.accountServiceConfig cfg
          // fetcher.serviceConfig
          // {
            ReadWritePaths = [ cache ];
            UMask = "0077";
            EnvironmentFile = fetcher.environmentFile;
            ExecStart = pkgs.writeShellScript (fetchUnit workload) fetcher.script;
          };
      };
    };
in
{
  config = lib.mkIf (cfg.enable && backend.native) (
    lib.mkMerge [
      {
        systemd.services = backend.chain services;
        # Every socket client joins `group`, which owns the worker sockets.
        users.users = lib.mkIf backend.sockets (
          lib.genAttrs llmhop.socketClients (_: {
            extraGroups = [ cfg.group ];
          })
        );
      }
      (util.identityConfig { inherit name cfg; })
    ]
  );
}
