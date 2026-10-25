# Unit defaults, hardening, sockets and the registries every backend
# contributes to.
lib: self:
let
  inherit (self)
    appendList
    enabled
    enabledModels
    engine
    fetchUnit
    fetches
    hostPort
    socketDirectoryMode
    unitCacheDirectory
    updateUnit
    workerUrl
    workloadUnit
    ;
in
{
  # A workload without a `port` binds `socketName` in a `RuntimeDirectory=` of
  # its own below `services.llmhop.socketDirectory`, reachable by llmhop
  # through the unit's group, or through the root's default ACL for Quadlet.
  # See "Unix sockets" in the module internals documentation.
  socketName = "http.sock";

  # Keeps group write, which the kernel would otherwise mask off the socket
  # and thereby off its group or ACL.
  socketUMask = "0007";

  # Mode of the socket directory, search only: llmhop knows the name.
  socketDirectoryMode = "0710";

  # The `RuntimeDirectory=` holding `socket`, appended to whatever
  # `serviceConfig` already declares, since the socket depends on it. Its mode
  # stays a default the escape hatches may override.
  socketRuntimeDirectory =
    serviceConfig: socket:
    lib.optionalAttrs (socket != null) {
      RuntimeDirectory = appendList serviceConfig "RuntimeDirectory" [
        (lib.removePrefix "/run/" (dirOf socket))
      ];
      RuntimeDirectoryMode = serviceConfig.RuntimeDirectoryMode or socketDirectoryMode;
    };

  # Hard-fail after 3 errors/hour so journald surfaces the underlying error
  # instead of an endless restart loop.
  sharedUnitConfig = {
    StartLimitBurst = 3;
    StartLimitIntervalSec = 3600;
  };

  # `[Service]` settings of every server. An hour-long `TimeoutStartSec`
  # covers loading a large model plus GPU memory profiling, `RestartSec = 30`
  # debounces crash loops, and `always` restarts vLLM and SGLang, which shut
  # down gracefully and exit 0 when their engine dies.
  serverServiceConfig = cfg: {
    TimeoutStartSec = 3600;
    RestartSec = 30;
    Restart = "always";
    LimitNOFILE = cfg.openFilesLimit;
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

  # Enabled subset of any `attrsOf { enable; ... }` workload collection.
  enabled = lib.filterAttrs (_: w: w.enable);

  # Enabled-model subset shared by registry helpers and backend iteration.
  enabledModels = cfg: enabled cfg.models;

  # Enabled models sorted by ascending `name`, the order workers are emitted
  # and chained in.
  sortedModels =
    cfg:
    lib.pipe (enabledModels cfg) [
      lib.attrValues
      (lib.sortOn (m: m.name))
    ];

  # `EnvironmentFile=` layering shared by every workload: the backend-wide file
  # first, so the per-workload one overrides its entries.
  environmentFiles =
    cfg: workload:
    lib.optional (cfg.environmentFile != null) cfg.environmentFile
    ++ lib.optional (workload.environmentFile != null) workload.environmentFile;

  # Every backend binds the host loopback or a socket, and llmhop shares the host.
  # `workload` carries `port` and `socket`.
  workerUrl =
    workload:
    if workload.socket != null then
      "unix://${workload.socket}"
    else
      "http://${hostPort "127.0.0.1" workload.port}";

  # Cross-cutting NixOS fragment every backend emits: its llmhop models and its
  # contributions to the three registries `core.nix` asserts on. Registry keys
  # are the owning option path, so a collision names what to change.
  #
  # `auxiliaries` covers everything a backend runs that is not a model, as
  # `{ <label> = { port, socket ? null, unit ? null, model ? null,
  # repositories ? [ ] }; }`. One entry per service
  # rather than one map per registry, so a label cannot go missing from a
  # dimension it belongs to. `model` is the llmhop routing key, registered
  # `unlisted` so the service shares llmhop's auth but stays out of the catalog.
  # Sockets need no registry, since their paths derive from unit names.
  mkSharedConfig =
    {
      backend,
      serviceName,
      cfg,
      cacheOwner,
      auxiliaries ? { },
    }:
    let
      models = enabledModels cfg;
      unitName = workloadUnit serviceName;
      # An entry joins a registry only if it carries that field. `suffix`
      # names a unit beside the workload's own.
      mkRegistry =
        suffix: modelValue: auxValue:
        lib.filterAttrs (_: value: value != null) (
          lib.mapAttrs' (
            name: m: lib.nameValuePair "${backend}.models.${name}${suffix}" (modelValue m)
          ) models
          // lib.mapAttrs' (
            label: aux: lib.nameValuePair "${backend}.${label}${suffix}" (auxValue aux)
          ) auxiliaries
        );
      ifFetching = w: unit: if fetches w then fetchUnit unit else null;
      routed = lib.filterAttrs (_: aux: aux.model or null != null) auxiliaries;
    in
    {
      services.llmhop = {
        # Keyed by `name`, not the attribute: that is what the worker advertises
        # and what clients send, and the two differ when `name` is set.
        settings.models =
          lib.mapAttrs' (_: m: lib.nameValuePair m.name { url = workerUrl m; }) models
          // lib.mapAttrs' (
            _: aux:
            lib.nameValuePair aux.model {
              url = workerUrl aux;
              unlisted = true;
            }
          ) routed;
        portsRegistry = mkRegistry "" (m: m.port) (aux: aux.port);
        unitsRegistry =
          mkRegistry "" unitName (aux: aux.unit or null)
          // mkRegistry ".fetch" (m: ifFetching m (unitName m)) (aux: ifFetching aux aux.unit)
          // {
            "${backend}.update" = updateUnit serviceName;
          };
        modelsRegistry = mkRegistry "" (m: m.name) (aux: aux.model or null);
      };
      systemd.tmpfiles.settings."10-${serviceName}" = lib.mkIf cfg.cache.manage {
        ${cfg.cache.directory}.d = {
          inherit (cacheOwner) user group;
          mode = "0700";
        };
      };
    };

  # Global uniqueness check over a `<backend>/<component>` → resource registry
  # written by `mkSharedConfig`. Groups by resource so the message names every
  # owner of a contested one; `resource` is the singular noun used in the text.
  mkRegistryAssertion =
    { registry, resource }:
    let
      collisions = lib.pipe (lib.attrNames registry) [
        (lib.groupBy (name: toString registry.${name}))
        (lib.filterAttrs (_: owners: lib.length owners > 1))
      ];
    in
    {
      assertion = collisions == { };
      message =
        "services.llmhop: ${resource} collisions across backends:\n"
        + lib.concatStringsSep "\n" (
          map (value: "${resource} ${value} reserved by ${lib.concatStringsSep ", " collisions.${value}}") (
            lib.naturalSort (lib.attrNames collisions)
          )
        );
    };

  # The environment of the server of `workload` in `unit`, layered under
  # `environment`, the backend's and the workload's own. It reads the hub cache
  # of `cfg`, which keeps an offline server from reaching out on its own beside
  # each engine's own offline switch, and keeps its runtime caches in its own
  # cache directory rather than the read-only or ephemeral `$HOME`.
  serverEnvironment =
    {
      backend,
      cfg,
      workload,
      unit,
      environment ? { },
    }:
    let
      cache = unitCacheDirectory unit;
    in
    {
      HF_HOME = cfg.cache.directory;
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
    // lib.optionalAttrs workload.offline { HF_HUB_OFFLINE = "1"; }
    // (engine backend).environment
    // environment
    // cfg.environment
    // workload.environment;
}
