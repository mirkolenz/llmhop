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
  refreshUnit = unit: "${unit}-refresh";
  # The fetcher a server `Wants=`.
  fetchServices = workload: lib.optional (fetches workload) "${fetchUnit workload.unit}.service";
  # The units a server starts after: its fetcher, and the refresh that a
  # successful download triggers, which thereby finds the server still waiting
  # rather than restarting it.
  fetchOrder =
    workload:
    fetchServices workload ++ lib.optional (fetches workload) "${refreshUnit workload.unit}.service";

  # The hub cache of `workload` and the cache `name` and `revision` of each of
  # its repositories. huggingface_hub records the default branch as `main`,
  # while llama.cpp names it after the branch but pins no revision, so null
  # keeps every ref.
  hubSpecification = engine: cfg: workload: {
    hub = hubDirectory cfg workload;
    repositories = map (repository: {
      name = "models--${
        lib.replaceStrings [ "/" ] [ "--" ] (lib.head (lib.splitString ":" repository.repo))
      }";
      revision = if engine.revisions then lib.defaultTo "main" (repository.revision or null) else null;
    }) workload.repositories;
  };

  # The sandbox of a unit running as `owner` on the hub cache `hub`, which the
  # fetcher controls, so it writes nothing else and opens no socket, since
  # an `owner` that is root could reach systemd or Podman through one.
  hubSandbox =
    owner: hub:
    util.accountServiceConfig owner
    // {
      PrivateNetwork = true;
      SystemCallFilter = util.hardenedServiceConfig.SystemCallFilter ++ [ "~@network-io" ];
      ReadWritePaths = [ hub ];
    };

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
  # `credentialDirectory`, before its server starts. See "Fetching" in the
  # module internals documentation.
  fetchUnitConfig =
    {
      engine,
      cfg,
      workload,
      fetcher,
      credentialDirectory,
    }:
    {
      # Every start or restart also starts the refresh, which runs only once
      # this succeeded.
      unitConfig.Wants = [ "${refreshUnit workload.unit}.service" ];
      serviceConfig = util.credentialServiceConfig cfg.fetch.credentials // {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
      };
      environment = {
        HF_HOME = cacheDirectory cfg workload;
      }
      // util.resolveCredentialRefs credentialDirectory cfg.fetch.credentials cfg.fetch.environment;
      environmentFile = lib.optional (cfg.fetch.environmentFile != null) cfg.fetch.environmentFile;
      # The token's value, since llama.cpp reads no token file.
      script =
        "set -e\n"
        + lib.optionalString (cfg.fetch.tokenCredential != null) ''
          token="$CREDENTIALS_DIRECTORY"/${lib.escapeShellArg cfg.fetch.tokenCredential}
          if [ -r "$token" ]; then
            HF_TOKEN=$(cat "$token")
            export HF_TOKEN
          fi
        ''
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
      credentialDirectory,
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
    // util.resolveCredentialRefs credentialDirectory workload.credentials (
      cfg.environment // workload.environment
    );

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
  # After every successful fetch, `<unit>-refresh` prunes the hub cache as
  # the cache owner and restarts the server, the one step running as root,
  # with `systemctl` alone.
  #
  # The update unit `<backend>-update` is the counterpart of
  # `podman auto-update` for models: it restarts the fetcher of every
  # workload, each of which restarts its running server once it succeeded. It
  # exists only with anything to fetch. The fetchers run one at a time in
  # startup order, so the server restarts queue in that order too and keep to
  # the startup chain, and a failed one leaves the others alone.
  backendConfig =
    {
      pkgs,
      utils,
      systemd,
      engine,
      backend,
      cfg,
      cacheOwner,
      workloads,
    }:
    let
      systemctl = lib.getExe' systemd "systemctl";
      fetching = lib.filter fetches workloads;
      fetchers = lib.concatMap fetchServices workloads;
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
          // lib.optionalAttrs (fetches workload) {
            ${fetchUnit workload.unit} = [ workload.owner ];
            ${refreshUnit workload.unit} = [ workload.owner ];
          };
        }
        // lib.optionalAttrs (workload.port != null) {
          port.${toString workload.port} = [ workload.owner ];
        };
      # The refresh unit that every fetch starts.
      refreshUnitConfig =
        workload:
        let
          specification = hubSpecification engine cfg workload;
        in
        lib.nameValuePair (refreshUnit workload.unit) {
          description = "Refresh ${workload.unit} after a successful fetch";
          # Only after a complete download.
          requires = fetchServices workload;
          after = fetchServices workload;
          # A bundle drops this `PATH=` for the host's.
          path = [ pkgs.python3Minimal ];
          serviceConfig = hubSandbox cacheOwner specification.hub // {
            Type = "oneshot";
            ExecStartPre = utils.escapeSystemdExecArgs [
              (lib.getExe (pkgs.callPackage ../../pkgs/hub-prune/package.nix { }))
              (lib.toJSON specification)
            ];
            # `+` runs them as root outside the sandbox, which `systemctl` needs.
            # A planned restart does not count towards the start limit, and a
            # stopped or failed server stays down. `-` tolerates a stopped server
            # that systemd already unloaded.
            ExecStart = [
              "+-${systemctl} reset-failed ${workload.unit}.service"
              "+${systemctl} try-restart --no-block ${workload.unit}.service"
            ];
          };
        };
    in
    {
      services.llmhop.claims = lib.mkMerge (
        lib.optional update { unit."${backend}-update" = [ "services.llmhop.${backend}" ]; }
        ++ map workloadClaims workloads
      );
      services.llmhop.${backend}.fetch.credentials = lib.mkIf (cfg.fetch.tokenCredential != null) {
        ${cfg.fetch.tokenCredential} = lib.mkDefault null;
      };
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
      systemd = {
        # A native backend and its Quadlet twin may share the root, since
        # every workload owns its own directory. Every rule of llmhop
        # shares one file.
        tmpfiles.settings."10-llmhop" = lib.mkMerge (
          [ (util.rootDirectoryRule cfg.cache.directory) ]
          ++ map (util.directoryRule cacheOwner "0700") directories
        );
        services = lib.genAttrs' fetching refreshUnitConfig // {
          "${backend}-update" = lib.mkIf update {
            description = "Fetch the models of ${backend}";
            startAt = lib.optional (cfg.fetch.interval != null) cfg.fetch.interval;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = map (fetcher: "-${systemctl} restart ${fetcher}") fetchers;
            };
          };
        };
      };
    };
}
