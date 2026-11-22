# The config of the native fetchers of a backend: each workload's fetcher
# downloading into its own cache, a refresh unit pruning that cache and
# restarting the server after a successful fetch, and `<name>-update`
# refetching everything. See "Fetching" in the module internals
# documentation.
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
  inherit (llmhop) systemctl;
  inherit (wl.nativeCache cfg)
    cacheDirectory
    hubDirectory
    fetchUnit
    refreshUnit
    ;
  owner = "services.llmhop.${name}";
  fetching = lib.filter (w: w.fetches) workloads;

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
          name = "models--${lib.replaceStrings [ "/" ] [ "--" ] repository.repo}";
          revision = if engine.revisions then lib.defaultTo "main" repository.revision else null;
        }) workload.repositories;
      }
    );

  # Downloads the repositories of `workload` with the engine's fetcher, with
  # the Hugging Face token while its credential exists, since llama.cpp
  # reads no token file.
  fetchScript =
    workload:
    "set -e\n"
    + lib.optionalString (cfg.fetch.hfTokenCredential != null) ''
      token="$CREDENTIALS_DIRECTORY"/${lib.escapeShellArg cfg.fetch.hfTokenCredential}
      if [ -r "$token" ]; then
        HF_TOKEN=$(cat "$token")
        export HF_TOKEN
      fi
    ''
    + lib.concatMapStrings (repository: ''
      ${lib.escapeShellArgs (engine.fetch workload.package repository)}
    '') workload.repositories;

  # The fetcher of `workload`, sharing its identity and cache, with network
  # access and the backend's `fetch` credentials, and its refresh.
  units =
    workload:
    let
      inherit (workload) unit;
      cache = cacheDirectory workload;
    in
    {
      # A oneshot its server wants but does not require, so a failed fetch
      # leaves a running server alone. Every start also starts the refresh.
      ${fetchUnit workload} = {
        description = "Fetch the models of ${unit}";
        wants = [
          "network-online.target"
          "${refreshUnit workload}.service"
        ];
        after = [ "network-online.target" ];
        environment = {
          HF_HOME = cache;
          HOME = "/tmp";
        }
        // engine.implicitConfig.environment
        // util.systemdEnvironment cfg.fetch.credentials cfg.fetch.environment;
        serviceConfig =
          util.accountServiceConfig cfg
          // util.credentialServiceConfig cfg.fetch.credentials
          // {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = "infinity";
            InaccessiblePaths = util.optionalPaths engine.implicitConfig.paths;
            ReadWritePaths = [ cache ];
            UMask = "0077";
            EnvironmentFile = util.environmentFiles [ cfg.fetch ];
            ExecStart = pkgs.writeShellScript (fetchUnit workload) (fetchScript workload);
          };
      };

      # After a successful fetch, the refresh prunes the hub cache, which the
      # fetcher controls, in the sandbox of its owner, and restarts the server
      # with `systemctl` alone, the one step running as root.
      ${refreshUnit workload} = {
        description = "Refresh ${unit} after a successful fetch";
        # Only after a complete download.
        requires = [ "${fetchUnit workload}.service" ];
        after = [ "${fetchUnit workload}.service" ];
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
            "+-${systemctl} reset-failed ${unit}.service"
            "+${systemctl} try-restart --no-block ${unit}.service"
          ];
        };
      };
    };

  # The fetchers in startup order, which `<name>-update` restarts one at a
  # time, so the server restarts keep to the startup chain, and a failed one
  # leaves the others alone.
  fetchers = map (w: "${fetchUnit w}.service") fetching;
in
lib.mkIf (fetching != [ ]) {
  services.llmhop.claims.unit = lib.mkMerge (
    [ { "${name}-update" = [ owner ]; } ]
    ++ map (w: {
      ${fetchUnit w} = [ w.owner ];
      ${refreshUnit w} = [ w.owner ];
    }) fetching
  );
  systemd.services = lib.mkMerge (
    map units fetching
    ++ [
      {
        "${name}-update" = {
          description = "Fetch the models of ${name}";
          startAt = lib.optional (cfg.fetch.schedule != null) cfg.fetch.schedule;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = map (fetcher: "-${systemctl} restart ${fetcher}") fetchers;
          };
        };
      }
    ]
  );
  systemd.tmpfiles.settings."10-llmhop" = lib.mkMerge (
    map (w: util.directoryRule cfg "0700" (hubDirectory w)) fetching
  );
}
