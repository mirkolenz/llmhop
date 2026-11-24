# The config of the native servers of a backend, each a hardened system
# service, which the fetchers of `fetch.nix` download for.
{
  lib,
  pkgs,
  utils,
  engine,
  llmhop,
  cfg,
  workloads,
}:
let
  inherit (engine) name;
  util = import ../lib lib;
  wl = import ./workload lib;
  inherit (wl.nativeCache cfg)
    cacheDirectory
    hubDirectories
    fetchServices
    fetchOrder
    ;
  sockets = lib.any (w: w.socket != null) workloads;

  # Keeps group write, which the kernel would otherwise mask off the socket
  # and thereby off its group.
  socketUMask = "0007";

  # The llmhop binary at a stable path, so that a changed binary leaves the
  # units of the servers, and thereby the servers, unchanged.
  etcExecutable = "llmhop/bin/llmhop";

  # The server of `workload`, started after `after` and after its fetcher,
  # which shares its identity and cache. See "Offline servers" and "Python
  # backends built from wheels" in the module internals documentation.
  services =
    workload: after:
    let
      inherit (workload) unit;
      cache = cacheDirectory workload;
      offline = lib.optionalAttrs workload.offline;
      # Only a server with network access waits for it, to download at
      # runtime or to bind beyond loopback.
      online = lib.optional (!workload.offline) "network-online.target";
      # A model's relaxations for GPUs and for NCCL in tensor-parallel
      # inference, and its own state directory, while a detector works in its
      # cache directory and may bind only its own port. See "GPU relaxations"
      # and "NCCL relaxations" in the module internals documentation.
      relaxations =
        if workload.gpu == null then
          {
            WorkingDirectory = cache;
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
            TasksMax = 4096;
            StateDirectory = "${name}/${workload.key}";
            WorkingDirectory = "/var/lib/${name}/${workload.key}";
          }
          // lib.optionalAttrs (workload.gpu.nativeDevices != null) {
            DevicePolicy = "closed";
            DeviceAllow = workload.gpu.nativeDevices;
          };
      # Offline, a socket's own network namespace, or else loopback only, which
      # `isolable` guarantees the port is bound to. Not `localhost`, whose
      # `127.0.0.0/8` includes the resolver stub of systemd-resolved.
      network =
        if workload.socket != null then
          {
            UMask = socketUMask;
            # The directory search only, since clients know the name.
            RuntimeDirectory = [ (lib.removePrefix "/run/" (dirOf workload.socket)) ];
            RuntimeDirectoryMode = "0710";
          }
          // offline { PrivateNetwork = true; }
        else
          {
            UMask = "0077";
          }
          // offline {
            IPAddressDeny = "any";
            IPAddressAllow = util.loopbackAddresses;
          };
    in
    {
      ${unit} = {
        inherit (workload) description;
        path = lib.optionals engine.uv (
          with pkgs;
          [
            stdenv.cc
            ninja
            bash
          ]
        );
        wantedBy = [ "multi-user.target" ];
        wants = fetchServices workload ++ after ++ online;
        after = fetchOrder workload ++ after ++ online;
        environment = wl.serverEnvironment {
          inherit
            engine
            cfg
            workload
            cache
            ;
          resolve = util.systemdEnvironment workload.credentials;
          extra = {
            HOME = cache;
          }
          # Only the fetchers write the hub, so even a server with network
          # access never downloads into it.
          // lib.optionalAttrs cfg.fetch.enable engine.offlineEnvironment
          // lib.optionalAttrs engine.uv {
            LD_LIBRARY_PATH = "/run/opengl-driver/lib";
            TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
          };
        };
        unitConfig = util.startLimitConfig;
        serviceConfig =
          wl.serverServiceConfig cfg workload
          # Its group owns the worker socket, which every client joins.
          // util.accountServiceConfig cfg
          // {
            ReadWritePaths = [ cache ];
            ReadOnlyPaths = hubDirectories workload;
            EnvironmentFile = util.environmentFiles [
              cfg
              workload
            ];
            InaccessiblePaths =
              util.optionalPaths engine.implicitConfig.paths
              ++ lib.optionals workload.offline (
                util.optionalPaths [
                  "/run/nscd"
                  "/run/systemd/resolve"
                ]
              );
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
                "/etc/${etcExecutable}"
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
    };
in
lib.mkMerge [
  {
    systemd.services = wl.chain cfg.startupOrdering workloads services;
    environment.etc.${etcExecutable}.source = lib.getExe llmhop.package;
    # Every workload owns its own directory below the root, and every
    # rule of llmhop shares one file. Its sockets share the root of every
    # socket. See "Unix sockets" in the module internals documentation.
    systemd.tmpfiles.settings."10-llmhop" = lib.mkMerge (
      [ (util.rootDirectoryRule cfg.cache.directory) ]
      ++ lib.optional sockets (util.rootDirectoryRule llmhop.socketDirectory)
      ++ map (w: util.directoryRule cfg "0700" (cacheDirectory w)) workloads
    );
    # Every socket client joins `group`, which owns the worker sockets.
    users.users = lib.mkIf sockets (
      lib.genAttrs llmhop.socketClients (_: {
        extraGroups = [ cfg.group ];
      })
    );
  }
  (util.identityConfig { inherit name cfg; })
]
