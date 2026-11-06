# The directories, fetchers, server environment, startup chain and
# maintenance units of the backend of the engine `name`, which its native
# and container units share.
{
  config,
  lib,
  pkgs,
  utils,
  engine,
}:
let
  util = import ../lib.nix lib;
  wl = import ./workload.nix lib;
  llmhop = config.services.llmhop;
  inherit (engine) name;
  inherit (llmhop) systemctl;
in
rec {
  inherit name engine;
  owner = "services.llmhop.${name}";
  cfg = llmhop.${name};
  native = cfg.runtime == "native";

  # Keeps group write, which the kernel would otherwise mask off the socket
  # and thereby off its group or ACL.
  socketUMask = "0007";

  defaultCacheDirectory = "/var/cache/${name}";

  # The cache directory of `workload`, which no other workload shares, holding
  # the hub cache its fetcher writes in `hub/` beside the runtime caches of
  # its server, at the same path in a container, where it is the named volume
  # `<unit>` without `cache.directory`. See "Directory layout" in the module
  # internals documentation.
  cacheDirectory =
    workload: "${lib.defaultTo defaultCacheDirectory cfg.cache.directory}/${workload.name}";
  hubDirectory = workload: "${cacheDirectory workload}/hub";

  # With `fetch.enable`, every server runs offline from its hub cache, which
  # the fetcher `<unit>-fetch` fills before it, and which exists only for a
  # workload that `fetches`. See "Fetching" in the module internals
  # documentation.
  hubDirectories = workload: lib.optional workload.fetches (hubDirectory workload);
  fetchUnit = workload: "${workload.unit}-fetch";
  refreshUnit = workload: "${workload.unit}-refresh";
  # The fetcher a server `Wants=`.
  fetchServices = workload: lib.optional workload.fetches "${fetchUnit workload}.service";
  # The units a server starts after: its fetcher, and the refresh that a
  # successful download triggers, which thereby finds the server still waiting
  # rather than restarting it.
  fetchOrder =
    workload:
    fetchServices workload ++ lib.optional workload.fetches "${refreshUnit workload}.service";

  # The file of the hub cache of `workload` and the cache `name` and
  # `revision` of each of its repositories. huggingface_hub records the
  # default branch as `main`, while llama.cpp names it after the branch but
  # pins no revision, so null keeps every ref.
  hubSpecification =
    workload:
    pkgs.writeText "${workload.unit}-hub.json" (
      lib.toJSON {
        hub = hubDirectory workload;
        repositories = map (repository: {
          name = "models--${
            lib.replaceStrings [ "/" ] [ "--" ] (lib.head (lib.splitString ":" repository.repo))
          }";
          revision = if engine.revisions then lib.defaultTo "main" repository.revision else null;
        }) workload.repositories;
      }
    );

  credentialDirectory =
    if native then util.credentialDirectory else util.containerCredentialDirectory;

  # The fetcher of `workload`, downloading its repositories with the engine's
  # fetcher into its hub cache, with the fetch credentials, before its server
  # starts. Every start or restart also starts the refresh, which runs only
  # once this succeeded.
  fetch = workload: {
    unitConfig.Wants = [ "${refreshUnit workload}.service" ];
    serviceConfig = util.credentialServiceConfig cfg.fetch.credentials // {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "infinity";
    };
    environment = {
      HF_HOME = cacheDirectory workload;
    }
    // util.resolveCredentialRefs credentialDirectory cfg.fetch.credentials cfg.fetch.environment;
    environmentFile = lib.optional (cfg.fetch.environmentFile != null) cfg.fetch.environmentFile;
    # The token's value, since llama.cpp reads no token file.
    script =
      "set -e\n"
      + lib.optionalString (cfg.fetch.hfTokenCredential != null) ''
        token="$CREDENTIALS_DIRECTORY"/${lib.escapeShellArg cfg.fetch.hfTokenCredential}
        if [ -r "$token" ]; then
          HF_TOKEN=$(cat "$token")
          export HF_TOKEN
        fi
      ''
      + lib.concatMapStrings (repository: ''
        ${lib.escapeShellArgs (
          engine.fetch (
            if native then engine.native.fetcher workload.package else engine.quadlet.fetcher
          ) repository
        )}
      '') workload.repositories;
  };

  # `[Service]` settings of the server of every workload, granting its
  # credentials and holding its socket, the directory search only, since
  # clients know the name. See "Lifecycle" in the module internals
  # documentation. `Restart = "always"` also overrides quadlet-nix's
  # `on-failure` default.
  serverServiceConfig =
    workload:
    {
      TimeoutStartSec = 3600;
      RestartSec = 30;
      Restart = "always";
      LimitNOFILE = cfg.openFilesLimit;
    }
    // util.credentialServiceConfig workload.credentials
    // lib.optionalAttrs (workload.socket != null) {
      RuntimeDirectory = [ (lib.removePrefix "/run/" (dirOf workload.socket)) ];
      RuntimeDirectoryMode = "0710";
    };

  # The environment of the server of `workload`. It reads its hub cache and
  # keeps its runtime caches beside it rather than in the read-only or
  # ephemeral `$HOME`. Later layers override earlier ones: these defaults,
  # `engine.environment`, `environment`, then for a listed model the
  # transports of tensor parallelism, kept on loopback and off any InfiniBand
  # fabric since Gloo would otherwise bind the address the hostname resolves
  # to, such as `127.0.0.2`, which the IP address filter of an offline server
  # drops, and finally the backend's and the workload's own environment.
  serverEnvironment =
    workload: environment:
    let
      cache = cacheDirectory workload;
    in
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
    }
    # Only the fetchers write the hub, so even a server with network access
    # never downloads into it.
    // lib.optionalAttrs cfg.fetch.enable { HF_HUB_OFFLINE = "1"; }
    // engine.environment
    // environment
    // lib.optionalAttrs (workload.kind == "model") {
      GLOO_SOCKET_IFNAME = "lo";
      NCCL_SOCKET_IFNAME = "lo";
      NCCL_IB_DISABLE = "1";
    }
    // util.resolveCredentialRefs credentialDirectory workload.credentials (
      cfg.environment // workload.environment
    );

  # The backend-wide file first, so the per-workload one overrides its entries.
  environmentFiles =
    workload:
    lib.optional (cfg.environmentFile != null) cfg.environmentFile
    ++ lib.optional (workload.environmentFile != null) workload.environmentFile;

  models = wl.sortedWorkloads cfg.models;
  detectors = if name == "vllm" then wl.sortedWorkloads cfg.detectors else [ ];
  workloads = models ++ detectors;
  sockets = lib.any (w: w.socket != null) workloads;

  # `perWorkload` applied to each of the sorted `models` with the units it
  # starts after, its predecessor while `startupOrdering` so GPU memory
  # profiling never overlaps, and to each detector with none.
  # See "Lifecycle" in the module internals documentation.
  chain =
    perWorkload:
    lib.mkMerge (
      lib.imap0 (
        index: model:
        perWorkload model (
          lib.optional (cfg.startupOrdering && index > 0) "${(lib.elemAt models (index - 1)).unit}.service"
        )
      ) models
      ++ map (workload: perWorkload workload [ ]) detectors
    );

  fetchers = lib.concatMap fetchServices workloads;

  # The routing key, the units and the port of a workload.
  workloadClaims =
    workload:
    {
      model.${workload.name} = [ workload.owner ];
      unit = {
        ${workload.unit} = [ workload.owner ];
      }
      // lib.optionalAttrs workload.fetches {
        ${fetchUnit workload} = [ workload.owner ];
        ${refreshUnit workload} = [ workload.owner ];
      };
    }
    // lib.optionalAttrs (workload.port != null) {
      port.${toString workload.port} = [ workload.owner ];
    };

  # After every successful fetch, `<unit>-refresh` prunes the hub cache, which
  # the fetcher controls, in the sandbox of its owner, and restarts the server
  # with `systemctl` alone, the one step running as root.
  #
  # The update unit `<name>-update` is the counterpart of `podman auto-update`
  # for models: it restarts the fetcher of every workload, each of which
  # restarts its running server once it succeeded. It exists only with
  # anything to fetch. The fetchers run one at a time in startup order, so the
  # server restarts queue in that order too and keep to the startup chain, and
  # a failed one leaves the others alone.
  maintenanceServices =
    lib.genAttrs' (lib.filter (w: w.fetches) workloads) (
      workload:
      lib.nameValuePair (refreshUnit workload) {
        description = "Refresh ${workload.unit} after a successful fetch";
        # Only after a complete download.
        requires = fetchServices workload;
        after = fetchServices workload;
        serviceConfig = util.hubSandbox cfg (hubDirectory workload) // {
          Type = "oneshot";
          ExecStartPre = utils.escapeSystemdExecArgs [
            (lib.getExe llmhop.package)
            "internal"
            "hub-prune"
            (hubSpecification workload)
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
      }
    )
    // lib.optionalAttrs (fetchers != [ ]) {
      "${name}-update" = {
        description = "Fetch the models of ${name}";
        startAt = lib.optional (cfg.fetch.schedule != null) cfg.fetch.schedule;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = map (fetcher: "-${systemctl} restart ${fetcher}") fetchers;
        };
      };
    };
}
