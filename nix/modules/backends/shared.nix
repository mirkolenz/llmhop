# Directories, fetchers, server environment and the configuration that the
# native and the Quadlet backends share.
lib:
let
  util = import ../lib.nix lib;
in
rec {
  # A workload without a `port` binds `socketName` in a `RuntimeDirectory=` of
  # its own below `services.llmhop.socketDirectory`. See "Unix sockets" in the
  # module internals documentation.
  socketName = "http.sock";
  # Keeps group write, which the kernel would otherwise mask off the socket
  # and thereby off its group or ACL.
  socketUMask = "0007";

  # The cache directory of `workload`, which no other workload shares, holding
  # the hub cache its fetcher writes in `hub/` beside the runtime caches of
  # its server, at the same path in a container. See "Directory layout" in the
  # module internals documentation.
  cacheDirectory = cfg: workload: "${cfg.cache.directory}/${workload.name}";
  hubDirectory = cfg: workload: "${cacheDirectory cfg workload}/hub";
  # The hub cache exists only for a workload that fetches.
  hubDirectories = cfg: workload: lib.optional (fetches workload) (hubDirectory cfg workload);

  # Every server runs offline from its hub cache, which the fetcher
  # `<unit>-fetch` fills before it. See "Fetching" in the module internals
  # documentation.
  fetches = workload: workload.repositories != [ ];
  fetchUnit = unit: "${unit}-fetch";
  # The fetcher a server `Wants=` and starts after.
  fetcherUnits = workload: lib.optional (fetches workload) "${fetchUnit workload.unit}.service";

  # Enabled workloads of `collection` sorted by ascending `name`, the order
  # servers are emitted and chained in.
  sortedWorkloads =
    collection:
    lib.pipe collection [
      (lib.filterAttrs (_: w: w.enable))
      lib.attrValues
      (lib.sortOn (w: w.name))
    ];

  # The units the sorted `models` start after, each its predecessor while
  # `chained`, so GPU memory profiling never overlaps. See "Lifecycle" in the
  # module internals documentation.
  predecessors =
    chained: models:
    lib.imap0 (
      index: _: lib.optional (chained && index > 0) "${(lib.elemAt models (index - 1)).unit}.service"
    ) models;

  # The fetcher of `workload`, downloading its repositories with the engine's
  # `fetcher` into its hub cache, with the fetch credentials in
  # `credentialDirectory`, before the unit `server` starts. See "Fetching" in
  # the module internals documentation.
  #
  # After a complete download, `hub-cache.py` prunes the hub cache
  # unprivileged and records it with full privileges, since a native fetcher's
  # user may not manage units, restarting the server on a change. Whenever the
  # fetcher stops, it points the refs back to the recorded download, which
  # only an interrupted one changed, and the server starts only from a cache
  # matching that record.
  fetcher =
    {
      pkgs,
      engine,
      cfg,
      workload,
      server,
      fetcher,
      credentialDirectory,
    }:
    let
      # The fingerprint covers it, so a changed one invalidates the cache.
      # huggingface_hub records the default branch as `main`, while llama.cpp
      # names it after the branch but pins no revision, so null keeps every ref.
      specification = lib.toJSON {
        hub = hubDirectory cfg workload;
        repositories = map (
          repository:
          repository
          // {
            name = "models--${
              lib.replaceStrings [ "/" ] [ "--" ] (lib.head (lib.splitString ":" repository.repo))
            }";
            revision = if engine.revisions then lib.defaultTo "main" (repository.revision or null) else null;
          }
        ) workload.repositories;
      };
      state = "${engine.name}/${fetchUnit workload.name}";
      completed = "/var/lib/${state}/completed";
      # `+` runs a command with full privileges.
      run =
        prefix: arguments:
        prefix
        + lib.escapeShellArgs (
          [
            pkgs.python3Minimal.interpreter
            "${pkgs.callPackage ../../pkgs/hub-cache/package.nix { }}"
          ]
          ++ arguments
          ++ [ specification ]
        );
    in
    {
      serviceConfig = util.credentialServiceConfig cfg.fetch.credentials // {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
        StateDirectory = state;
        StateDirectoryMode = "0700";
        ExecStartPost = [
          (run "" [ "prune" ])
          (run "+" [
            "apply"
            server
            completed
          ])
        ];
        ExecStopPost = run "" [
          "restore"
          completed
        ];
      };
      serverServiceConfig = lib.optionalAttrs (fetches workload) {
        ExecStartPre = run "+" [
          "load"
          completed
        ];
      };
      environment = {
        HF_HOME = cacheDirectory cfg workload;
      }
      // util.resolveCredentialRefs credentialDirectory cfg.fetch.credentials cfg.fetch.environment;
      environmentFile = lib.optional (cfg.fetch.environmentFile != null) cfg.fetch.environmentFile;
      script =
        "set -e\n"
        + lib.concatMapStrings (repository: ''
          ${lib.escapeShellArgs (engine.fetch fetcher repository)}
        '') workload.repositories;
    };

  # `[Service]` settings of the server of every workload, granting its
  # credentials and holding its socket. See "Lifecycle" in the module
  # internals documentation.
  serverServiceConfig =
    cfg: workload:
    {
      TimeoutStartSec = 3600;
      RestartSec = 30;
      Restart = "always";
      LimitNOFILE = cfg.openFilesLimit;
    }
    // util.credentialServiceConfig workload.credentials
    # The directory holding the socket, search only, since clients know the name.
    // lib.optionalAttrs (workload.socket != null) {
      RuntimeDirectory = [ (lib.removePrefix "/run/" (dirOf workload.socket)) ];
      RuntimeDirectoryMode = "0710";
    };

  # Keep the transports of tensor parallelism on loopback and off any
  # InfiniBand fabric. Gloo would otherwise bind the address the hostname
  # resolves to, such as `127.0.0.2`, which the IP address filter of an
  # offline server drops. Applied as environment defaults of every model, so
  # a deployer can still override them.
  distributedEnvironment = {
    GLOO_SOCKET_IFNAME = "lo";
    NCCL_SOCKET_IFNAME = "lo";
    NCCL_IB_DISABLE = "1";
  };

  # The environment of the server of `workload`, layered under `environment`,
  # the backend's and the workload's own. It reads its hub cache and keeps
  # its runtime caches beside it rather than in the read-only or ephemeral
  # `$HOME`.
  serverEnvironment =
    {
      engine,
      cfg,
      workload,
      environment,
    }:
    let
      cache = cacheDirectory cfg workload;
    in
    {
      HF_HOME = cache;
      # Only the fetcher writes the hub, so even a server with network access
      # never downloads into it.
      HF_HUB_OFFLINE = "1";
      HF_HUB_DISABLE_TELEMETRY = "1";
      DO_NOT_TRACK = "1";
      XDG_CACHE_HOME = cache;
      TRITON_CACHE_DIR = "${cache}/triton";
      TORCHINDUCTOR_CACHE_DIR = "${cache}/inductor";
      MIOPEN_USER_DB_PATH = "${cache}/miopen";
      MIOPEN_CUSTOM_CACHE_DIR = "${cache}/miopen";
      SYCL_CACHE_PERSISTENT = "1";
      SYCL_CACHE_DIR = "${cache}/sycl";
      NEO_CACHE_PERSISTENT = "1";
      NEO_CACHE_DIR = "${cache}/neo";
    }
    // engine.environment
    // environment
    // lib.optionalAttrs (!workload.unlisted) distributedEnvironment
    // cfg.environment
    // workload.environment;

  # `EnvironmentFile=` layering shared by every workload: the backend-wide file
  # first, so the per-workload one overrides its entries.
  environmentFiles =
    cfg: workload:
    lib.optional (cfg.environmentFile != null) cfg.environmentFile
    ++ lib.optional (workload.environmentFile != null) workload.environmentFile;

  # Configuration every backend emits for its `workloads`: their endpoints,
  # their firewall ports, their cache directories owned by `cacheOwner`, the
  # update unit and the claims of all of them.
  #
  # The update unit `<engine>-update` is the counterpart of
  # `podman auto-update` for models: it restarts the fetcher of every
  # workload, each of which restarts its server if the model changed. It
  # exists only with anything to fetch. The fetchers run one at a time in
  # startup order, so the server restarts queue in that order too and keep to
  # the startup chain, and a failed one leaves the others alone.
  backendConfig =
    {
      pkgs,
      engine,
      backend,
      cfg,
      cacheOwner,
      workloads,
    }:
    let
      fetchers = lib.concatMap fetcherUnits workloads;
      update = fetchers != [ ];
      directories = lib.concatMap (w: [ (cacheDirectory cfg w) ] ++ hubDirectories cfg w) workloads;
      # The routing key, the units and the port of a workload.
      workloadClaims =
        workload:
        {
          model.${workload.name} = [ workload.owner ];
          unit = {
            ${workload.unit} = [ workload.owner ];
          }
          // lib.optionalAttrs (fetches workload) { ${fetchUnit workload.unit} = [ workload.owner ]; };
        }
        // lib.optionalAttrs (workload.port != null) {
          port.${toString workload.port} = [ workload.owner ];
        };
    in
    {
      services.llmhop.claims = lib.mkMerge (
        lib.optional update { unit."${engine.name}-update" = [ "services.llmhop.${backend}" ]; }
        ++ map workloadClaims workloads
      );
      # Keyed by the unique owner, so a clash of names reaches the claims
      # assertion rather than failing the merge.
      services.llmhop.endpoints = lib.genAttrs' workloads (
        workload:
        lib.nameValuePair workload.owner {
          inherit (workload)
            name
            owner
            socket
            unlisted
            ;
          engine = engine.name;
          url =
            if workload.socket != null then
              "unix://${workload.socket}"
            else
              "http://${util.hostPort workload.host workload.port}";
          # Reachable other than through loopback or the socket.
          exposed = workload.socket == null && (workload.openFirewall || !util.isLoopback workload.host);
        }
      );
      networking.firewall.allowedTCPPorts = map (w: w.port) (
        lib.filter (w: w.socket == null && w.openFirewall) workloads
      );
      # A native backend and its Quadlet twin may share the root, since every
      # workload owns its own directory. Every rule of llmhop shares one file.
      systemd.tmpfiles.settings."10-llmhop" = lib.mkMerge (
        [ (util.rootDirectoryRule cfg.cache.directory) ]
        ++ map (util.directoryRule cacheOwner "0700") directories
      );
      systemd.services."${engine.name}-update" = lib.mkIf update {
        description = "Fetch the models of ${engine.name}";
        startAt = lib.optional (cfg.fetch.interval != null) cfg.fetch.interval;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = map (fetcher: "-${lib.getExe' pkgs.systemd "systemctl"} restart ${fetcher}") fetchers;
        };
      };
    };
}
