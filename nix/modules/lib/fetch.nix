# Fetchers, which fill the hub cache an offline server reads, and the
# update unit that restarts them on a schedule.
lib: self:
let
  inherit (lib)
    mkOption
    types
    ;
  inherit (self)
    enabledModels
    engine
    fetchHook
    fetchService
    fetchUnit
    fetches
    hubDirectory
    pruneKeep
    repoCacheName
    resolveCredentialRefs
    workloadUnit
    ;
in
{
  # Every server runs offline from the hub cache of its backend, which the
  # fetcher `<unit>-fetch` fills before it. Both use `cache.directory` as
  # `HF_HOME`, at the same path in a container, which keeps the hub cache in
  # `hub`. See "Fetching" in the module internals documentation.
  hubDirectory = cfg: "${cfg.cache.directory}/hub";
  fetchUnit = unit: "${unit}-fetch";
  fetchService = unit: "${fetchUnit unit}.service";
  updateUnit = serviceName: "${serviceName}-update";

  # Directory of `repo` in a hub cache, with llama.cpp's `:<tag>` dropped.
  repoCacheName =
    repo: "models--${lib.replaceStrings [ "/" ] [ "--" ] (lib.head (lib.splitString ":" repo))}";

  # Whether `model` names a repository to fetch rather than a local path.
  isRepository = model: !lib.hasPrefix "/" model;

  # The internal option holding the repositories a workload's fetcher
  # downloads, each `{ repo, revision ? null, include ? [ ] }`, at `revision`
  # and limited to the files matching `include`, unless null and empty.
  repositoriesOption =
    repositories:
    mkOption {
      internal = true;
      readOnly = true;
      type = with types; listOf attrs;
      default = repositories;
      description = "Repositories the fetcher downloads.";
    };

  # The `Environment=` and `EnvironmentFile=` of a fetcher downloading into the
  # hub cache of `cfg`, with the fetch credentials in `directory`.
  fetchEnvironment =
    { cfg, directory }:
    {
      environment = {
        HF_HOME = cfg.cache.directory;
      }
      // resolveCredentialRefs directory cfg.fetch.credentials cfg.fetch.environment;
      environmentFile = lib.optional (cfg.fetch.environmentFile != null) cfg.fetch.environmentFile;
    };

  # Records the refs and snapshot files of the repository directories it is
  # given before a fetch (`save`), and afterwards (`apply`) restarts the
  # `server` if they changed, or starts it again if it failed. The rate limit
  # is reset first, so a planned restart does not count as a crash.
  fetchHook =
    pkgs:
    pkgs.writeShellApplication {
      name = "llmhop-fetch-hook";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.systemd
      ];
      text = ''
        mode=$1
        server=$2
        shift 2
        systemctl=(systemctl)
        if [[ ''${1:-} == --user ]]; then
          systemctl+=(--user)
          shift
        fi
        repos=("$@")
        # The files of every snapshot and the commit of every ref, missing until
        # the first download.
        fingerprint() {
          for repo in "''${repos[@]}"; do
            find "$repo/snapshots" -printf '%P %l\n' 2>/dev/null || true
            grep -r "" "$repo/refs" 2>/dev/null || true
          done | sort
        }
        state="$RUNTIME_DIRECTORY/fingerprint"
        if [[ $mode == save ]]; then
          fingerprint >"$state"
        elif [[ $(fingerprint) != "$(<"$state")" ]]; then
          if "''${systemctl[@]}" is-failed --quiet "$server"; then
            action=start
          else
            action=try-restart
          fi
          "''${systemctl[@]}" reset-failed "$server"
          "''${systemctl[@]}" "$action" --no-block "$server"
        fi
      '';
    };

  # `ExecStartPre=`/`ExecStartPost=` of the fetcher of `server` running
  # `fetchHook` over its repositories in `hub`, with full privileges, since a
  # native fetcher's user may not manage units. `user` selects the user
  # manager of a rootless Quadlet.
  mkFetchHooks =
    {
      pkgs,
      server,
      hub,
      repositories,
      user ? false,
    }:
    let
      exe = lib.getExe (fetchHook pkgs);
      args = lib.escapeShellArgs (
        [ "${server}.service" ]
        ++ lib.optional user "--user"
        ++ lib.unique (map ({ repo, ... }: "${hub}/${repoCacheName repo}") repositories)
      );
      hook = mode: "+${exe} ${mode} ${args}";
    in
    {
      RuntimeDirectory = fetchUnit server;
      ExecStartPre = hook "save";
      ExecStartPost = hook "apply";
    };

  # `[Service]` settings every fetcher shares. Like an image unit, it stays
  # active once it fetched, so a restarted server does not fetch again, and
  # downloads until done, however long that takes.
  fetchServiceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    TimeoutStartSec = "infinity";
  };

  # The script a fetcher runs with `sh -e`: every repository downloaded into
  # `hub` with the engine's `executable`, or, like an image pull with
  # `Policy=newer`, kept from the cache when that fails, such as offline.
  fetchScript =
    {
      backend,
      executable,
      hub,
      repositories,
    }:
    lib.concatMapStrings (repository: ''
      ${lib.escapeShellArgs ((engine backend).fetch executable repository)} || test -d ${hub}/${repoCacheName repository.repo}/snapshots
    '') repositories;

  # The `keep` arguments of `prune-hub` for `workloads`, every repository and
  # every pinned revision of them.
  pruneKeep =
    workloads:
    lib.unique (
      lib.concatMap (
        w:
        lib.concatMap (
          {
            repo,
            revision ? null,
            ...
          }:
          [ (repoCacheName repo) ] ++ lib.optional (revision != null) "${repoCacheName repo}/${revision}"
        ) w.repositories
      ) workloads
    );

  # `<serviceName>-update`, the counterpart of `podman auto-update` for models:
  # it restarts every fetcher of the enabled models and `auxiliaries` (those of
  # `mkSharedConfig`), each of which restarts its server if the model changed,
  # and afterwards, with `fetch.prune`, prunes the hub cache under
  # `serviceConfig`, prefixed by `pruneWrapper`. The restart runs with full
  # privileges and waits for the fetchers. `user` selects the user manager of
  # a rootless Quadlet. Null when there is neither anything to fetch nor to
  # prune.
  mkUpdateService =
    {
      serviceName,
      cfg,
      pkgs,
      auxiliaries,
      pruneWrapper ? [ ],
      user ? false,
      serviceConfig ? { },
    }:
    let
      workloads = lib.filter fetches (
        map (m: {
          unit = workloadUnit serviceName m;
          inherit (m) repositories;
        }) (lib.attrValues (enabledModels cfg))
        ++ lib.attrValues auxiliaries
      );
      fetchers = map (w: fetchService w.unit) workloads;
      prune = pruneWrapper ++ [
        "${pkgs.callPackage ../../pkgs/prune-hub/package.nix { }}"
        (hubDirectory cfg)
      ];
      commands =
        lib.optional (fetchers != [ ])
          "+${
            lib.escapeShellArgs (
              [ (lib.getExe' pkgs.systemd "systemctl") ]
              ++ lib.optional user "--user"
              ++ [ "restart" ]
              ++ fetchers
            )
          }"
        ++ lib.optional cfg.fetch.prune (lib.escapeShellArgs (prune ++ pruneKeep workloads));
    in
    if commands == [ ] then
      null
    else
      {
        description = "Fetch and prune the models of ${serviceName}";
        startAt = lib.optional (cfg.fetch.interval != null) cfg.fetch.interval;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = commands;
        }
        // serviceConfig;
      };

  # Whether `workload` has a repository to fetch.
  fetches = workload: workload.repositories or [ ] != [ ];
}
