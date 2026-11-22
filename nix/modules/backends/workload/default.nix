# The workloads of a backend, its models and watermark detectors: their
# submodules and records, and what the units of both runtimes share.
lib:
let
  util = import ../../lib lib;
in
lib.mergeAttrsList (
  map (file: import file lib) [
    ./detector.nix
    ./model.nix
    ./options.nix
    ./records.nix
  ]
)
// rec {
  # Every workload of every backend, detectors included.
  allWorkloads =
    llmhop:
    lib.concatMap (name: llmhop.${name}.workloads) (lib.attrNames (import ../../engines.nix lib));

  # `perWorkload` applied to each of `workloads` with the units it wants and
  # starts after: for one with a `gpu`, the one with a `gpu` before it while
  # `startupOrdering`, so GPU memory profiling never overlaps. See
  # "Lifecycle" in the module internals documentation.
  chain =
    startupOrdering: workloads: perWorkload:
    let
      chained = lib.filter (w: w.gpu != null) workloads;
    in
    lib.mkMerge (
      lib.imap0 (
        index: workload:
        perWorkload workload (
          lib.optional (startupOrdering && index > 0) "${(lib.elemAt chained (index - 1)).unit}.service"
        )
      ) chained
      ++ map (workload: perWorkload workload [ ]) (lib.filter (w: w.gpu == null) workloads)
    );

  # The environment of the server of `workload` of the backend `cfg`, with
  # its caches below `cache` and its credential references resolved by
  # `resolve`. It reads its hub cache and keeps its runtime
  # caches beside it rather than in the read-only or ephemeral `$HOME`. Later
  # layers override earlier ones: these defaults, the engine's `environment`,
  # `extra`, the engine's opt-out of its implicit config, then for a model
  # the transports of tensor parallelism, kept on loopback and off any
  # InfiniBand fabric since Gloo would otherwise bind the address the
  # hostname resolves to, such as `127.0.0.2`, which the IP address filter of
  # an offline server drops, and finally the backend's and the workload's own
  # environment.
  serverEnvironment =
    {
      engine,
      cfg,
      workload,
      cache,
      resolve,
      extra ? { },
    }:
    {
      HF_HOME = cache;
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
      # Device indices follow the slots, rather than CUDA's speed heuristic,
      # which vLLM and SGLang warn about, or Level Zero's discrete devices
      # first. ROCm has no such switch.
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
      ZE_ENABLE_PCI_ID_DEVICE_ORDER = "1";
    }
    // engine.environment
    // extra
    // engine.implicitConfig.environment
    // lib.optionalAttrs (workload.gpu != null) {
      GLOO_SOCKET_IFNAME = "lo";
      NCCL_SOCKET_IFNAME = "lo";
      NCCL_IB_DISABLE = "1";
    }
    // resolve (cfg.environment // workload.environment);

  # The backend-wide file first, so the per-workload one overrides its entries.
  environmentFiles =
    cfg: workload:
    lib.optional (cfg.environmentFile != null) cfg.environmentFile
    ++ lib.optional (workload.environmentFile != null) workload.environmentFile;

  # Seconds a stopped server of the backend `cfg` has to drain its requests
  # and exit before it is killed.
  stopTimeout = cfg: cfg.shutdownTimeoutSeconds + 10;

  # `[Service]` settings of the server of `workload` of the backend `cfg`,
  # granting its credentials. See "Lifecycle" in the module internals
  # documentation. `Restart = "always"` also overrides quadlet-nix's
  # `on-failure` default.
  serverServiceConfig =
    cfg: workload:
    {
      TimeoutStartSec = 3600;
      TimeoutStopSec = stopTimeout cfg;
      RestartSec = 30;
      Restart = "always";
      LimitNOFILE = cfg.openFilesLimit;
    }
    // util.credentialServiceConfig workload.credentials;

  # The cache directory of every native workload of the backend `cfg`,
  # which no other workload shares, holding the hub cache its fetcher writes
  # in `hub/` beside the runtime caches of its server, and the names of the
  # units fetching into it. See "Directory layout" and "Fetching" in the
  # module internals documentation.
  nativeCache = cfg: rec {
    cacheDirectory = workload: "${cfg.cache.directory}/${workload.name}";
    hubDirectory = workload: "${cacheDirectory workload}/hub";
    hubDirectories = workload: lib.optional workload.fetches (hubDirectory workload);
    fetchUnit = workload: "${workload.unit}-fetch";
    refreshUnit = workload: "${workload.unit}-refresh";
    # The fetcher a server `Wants=`.
    fetchServices = workload: lib.optional workload.fetches "${fetchUnit workload}.service";
    # The units a server starts after: its fetcher, and the refresh that a
    # successful download triggers, which thereby finds the server still
    # waiting rather than restarting it.
    fetchOrder =
      workload: fetchServices workload ++ lib.optional workload.fetches "${refreshUnit workload}.service";
  };
}
