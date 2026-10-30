# Engines, options, credentials, fetchers and unit defaults shared by the
# native and the Quadlet backends.
lib:
let
  inherit (lib) mkOption types;
in
rec {
  # `host:port`, with IPv6 literals bracketed.
  hostPort =
    host: port:
    if lib.hasInfix ":" host then "[${host}]:${toString port}" else "${host}:${toString port}";

  # The cache directory of the server in `unit`, named after it like its
  # `CacheDirectory=`, at the same path in a container.
  unitCacheDirectory = unit: "/var/cache/${unit}";

  # A workload without a `port` binds `socketName` in a `RuntimeDirectory=` of
  # its own below `services.llmhop.socketDirectory`. See "Unix sockets" in the
  # module internals documentation.
  socketName = "http.sock";
  # Keeps group write, which the kernel would otherwise mask off the socket
  # and thereby off its group or ACL.
  socketUMask = "0007";

  # How each engine is driven, keyed by its service name.
  #
  # Its parser reads two `settings` shapes that have no portable rendering.
  # `negateBools` means the parser registers a `--no-<key>` twin for every
  # boolean, `listStyle` picks between `--key a b` ("values") and
  # `--key a --key b` ("repeat"). `socketSettings` renders the flags binding a
  # unix socket, or is null for a server that only listens on TCP.
  #
  # `fetch` renders the argv downloading one repository with the given
  # `fetcher` into the hub cache below `HF_HOME`. `modelSettings` are the
  # flags derived from a model and `environment` is set on every server.
  # `native` and `quadlet` hold what only one kind of backend needs.
  engines =
    let
      huggingFace = {
        listStyle = "values";
        revisions = true;
        environment = { };
        modelSettings = model: {
          served-model-name = model.name;
          inherit (model) revision;
        };
        fetch =
          hf:
          {
            repo,
            revision ? null,
            include ? [ ],
          }:
          [
            hf
            "download"
            repo
          ]
          ++ lib.optionals (revision != null) [
            "--revision"
            revision
          ]
          ++ lib.concatMap (pattern: [
            "--include"
            pattern
          ]) include;
      };
      native = {
        repositories = [ ];
        fetcher = package: lib.getExe' package "hf";
      };
      quadlet = {
        environment = { };
        fetcher = "hf";
        container = _model: { };
      };
    in
    {
      llama-cpp = {
        displayName = "llama.cpp";
        negateBools = true;
        listStyle = "repeat";
        # llama-server binds a unix socket when the host ends in `.sock`.
        socketSettings = path: {
          host = path;
          port = null;
        };
        revisions = false;
        environment = { };
        modelSettings =
          model:
          {
            alias = model.name;
            offline = true;
          }
          // (if isRepository model.model then { hf-repo = model.model; } else { inherit (model) model; });
        modelDescription = ''
          Hugging Face repository with an optional quantization tag, passed as
          `--hf-repo`, or an absolute path to a GGUF file, passed as `--model`.
        '';
        modelExample = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
        # `llama download` resolves a quantization tag, split files and the
        # mmproj as the server would, but pins no revision.
        fetch = llama: { repo, ... }: [
          llama
          "download"
          "-hf"
          repo
        ];
        native = native // {
          uv = false;
          fetcher = package: lib.getExe' package "llama";
          command = model: [ (lib.getExe' model.package "llama-server") ];
        };
        quadlet = quadlet // {
          imageExample = "ghcr.io/ggml-org/llama.cpp:server-cuda";
          entrypoint = [ "/app/llama-server" ];
          port = 8080;
          fetcher = "/app/llama";
        };
      };
      vllm = huggingFace // {
        displayName = "vLLM";
        negateBools = true;
        socketSettings = path: {
          uds = path;
          host = null;
          port = null;
        };
        modelDescription = "Hugging Face repository passed to `vllm serve`, or an absolute path.";
        modelExample = "Qwen/Qwen2.5-7B-Instruct";
        # vLLM otherwise derives the address of its distributed workers from
        # the route to a public one, which an offline server lacks.
        environment.VLLM_HOST_IP = "127.0.0.1";
        native = native // {
          uv = true;
          packageEntry = "the `vllm` CLI at `bin/vllm`";
          command = model: [
            (lib.getExe' model.package "vllm")
            "serve"
            model.model
          ];
        };
        quadlet = quadlet // {
          imageExample = "docker.io/vllm/vllm-openai:latest";
          entrypoint = [
            "vllm"
            "serve"
          ];
          port = 8000;
          # `vllm serve` takes the model as its positional argument.
          container = model: { arguments = [ model.model ]; };
        };
      };
      sglang = huggingFace // {
        displayName = "SGLang";
        negateBools = false;
        socketSettings = null;
        modelSettings = model: huggingFace.modelSettings model // { model-path = model.model; };
        modelDescription = "Hugging Face repository passed as `--model-path`, or an absolute path.";
        modelExample = "Qwen/Qwen3-8B";
        native = native // {
          uv = true;
          packageEntry = "the SGLang Python environment, launched as `bin/python -m sglang.launch_server`";
          # `python -m sglang.launch_server` is the entry point present in
          # every SGLang wheel, a top-level `sglang` console script is not.
          command = model: [
            (lib.getExe' model.package "python")
            "-m"
            "sglang.launch_server"
          ];
          # Without the lockfile of its images, SGLang loads these kernels
          # from the hub at this revision.
          repositories = [
            {
              repo = "kernels-community/sgl-flash-attn3";
              revision = "v1";
            }
          ];
        };
        quadlet = quadlet // {
          imageExample = "docker.io/lmsysorg/sglang:latest";
          entrypoint = [
            "sglang"
            "serve"
          ];
          port = 30000;
          # The images ship their flash-attention kernels in their own hub
          # cache, which the mounted `HF_HOME` replaces.
          environment.KERNELS_CACHE = "/root/.cache/huggingface/hub";
        };
      };
    };

  # Strings, paths and derivations render verbatim, everything else through JSON.
  cliValue = value: if lib.isStringLike value then toString value else lib.toJSON value;

  # Render `settings` into the argv `engine`'s parser expects, flag and value
  # as separate entries. See "CLI dialects" in the module internals
  # documentation.
  renderCliArgs =
    engine: attrs:
    let
      # `false` becomes `--no-<key>` (and `no-<key> = false` becomes `--<key>`)
      # for the backends whose parsers auto-register the negated twin.
      flipBoolFlags = lib.mapAttrs' (
        name: value:
        if value == false then
          lib.nameValuePair (
            if lib.hasPrefix "no-" name then lib.removePrefix "no-" name else "no-${name}"
          ) true
        else
          lib.nameValuePair name value
      );
      render =
        name: value:
        if value == null || value == false then
          [ ]
        else if value == true then
          [ "--${name}" ]
        else if !lib.isList value then
          [
            "--${name}"
            (cliValue value)
          ]
        else if engine.listStyle == "values" then
          lib.optionals (value != [ ]) ([ "--${name}" ] ++ map cliValue value)
        else
          lib.concatMap (element: [
            "--${name}"
            (cliValue element)
          ]) value;
    in
    lib.concatLists (
      lib.mapAttrsToList render (if engine.negateBools then flipBoolFlags attrs else attrs)
    );

  # One-sentence dialect summary appended to every `settings` description.
  settingsRendering =
    engine:
    "Rendered as `--<key> <value>`, with ${
      if engine.negateBools then
        "`false` as `--no-<key>`"
      else
        "`false` dropped, since this CLI pairs `--enable-X` with `--disable-X`"
    } and a list ${
      if engine.listStyle == "values" then "handed to a single flag" else "repeating the flag"
    }. See [settings rendering](../README.md#settings-rendering) for the full rules.";

  credentialsOption = mkOption {
    type = with types; attrsOf (nullOr externalPath);
    default = { };
    # A credential name becomes a systemd credential ID, a plain file name
    # under `$CREDENTIALS_DIRECTORY`, so anything systemd would reject is
    # caught here.
    apply = lib.mapAttrs (
      name:
      lib.throwIfNot (lib.match "[[:alnum:]_][[:alnum:]_.-]{0,254}" name != null)
        "services.llmhop: `${name}` is not a valid systemd credential name. Start with an alphanumeric character or `_`, continue with those plus `.` and `-`, and stay within 255 characters."
    );
    example = lib.literalExpression ''
      {
        api-keys = "/run/secrets/api-keys";
        "llmhop.hf-token" = null;
      }
    '';
    description = ''
      Credentials granted exclusively to this service. A path outside the
      Nix store is loaded with `LoadCredential=`, while `null` imports the
      credential of the same name from the system credential store with
      `ImportCredential=`. Reference the read-only file from `settings` as
      `''${cred:<name>}`.
    '';
  };

  # The `[Service]` settings granting `credentials`. `toString` keeps a path
  # value from being copied into the Nix store.
  credentialServiceConfig = credentials: {
    LoadCredential = lib.mapAttrsToList (name: source: "${name}:${toString source}") (
      lib.filterAttrs (_: source: source != null) credentials
    );
    ImportCredential = lib.attrNames (lib.filterAttrs (_: source: source == null) credentials);
  };

  # Apply `f` to every string of a settings tree.
  mapStrings =
    f:
    let
      walk =
        value:
        if lib.isString value then
          f value
        else if lib.isList value then
          map walk value
        else if lib.isAttrs value && !lib.isDerivation value then
          lib.mapAttrs (_: walk) value
        else
          value;
    in
    walk;

  # Rewrite every `${cred:<name>}` reference in a settings tree to the path the
  # credential is mounted at, so secrets reach the server as a file name rather
  # than a value on the command line.
  resolveCredentialRefs =
    directory: credentials:
    mapStrings (
      value:
      let
        names = lib.attrNames credentials;
        replaced = lib.replaceStrings (map (name: "\${cred:${name}}") names) (map (
          name: "${directory}/${name}"
        ) names) value;
      in
      if lib.hasInfix "\${cred:" replaced then
        throw "unknown credential reference in `${value}`"
      else
        replaced
    );

  # The flags a workload's server receives: its `settings` with every
  # `${cred:…}` resolved against the credential `directory`.
  workloadArgs =
    engine: directory: workload:
    renderCliArgs engine (resolveCredentialRefs directory workload.credentials workload.settings);

  isLoopback =
    host:
    lib.elem host [
      "127.0.0.1"
      "::1"
    ];

  # The curl target of the `/health` of a server listening on `socket`, or else
  # on its bind address, using loopback for wildcard listeners.
  healthTarget =
    {
      socket,
      host,
      port,
    }:
    let
      probeHost =
        if host == "0.0.0.0" then
          "127.0.0.1"
        else if host == "::" then
          "::1"
        else
          host;
    in
    (
      if socket != null then
        "--unix-socket ${lib.escapeShellArg socket} http://localhost"
      else
        "http://${hostPort probeHost port}"
    )
    + "/health";

  # Whether `model` names a repository to fetch rather than a local path.
  isRepository = model: !lib.hasPrefix "/" model;

  # Whether `workload` has a repository to fetch.
  fetches = workload: workload.repositories != [ ];

  # Every server runs offline from the hub cache of its backend, which the
  # fetcher `<unit>-fetch` fills before it. See "Fetching" in the module
  # internals documentation.
  hubDirectory = cfg: "${cfg.cache.directory}/hub";
  fetchUnit = unit: "${unit}-fetch";

  # The fetcher a server `Wants=` and starts after.
  fetcherOf = workload: lib.optional (fetches workload) "${fetchUnit workload.unit}.service";

  # Directory of `repo` in a hub cache, with llama.cpp's `:<tag>` dropped.
  repoCacheName =
    repo: "models--${lib.replaceStrings [ "/" ] [ "--" ] (lib.head (lib.splitString ":" repo))}";

  # The internal option holding the repositories a workload's fetcher
  # downloads, each `{ repo, revision ? null, include ? [ ] }`.
  repositoriesOption =
    repositories:
    mkOption {
      internal = true;
      readOnly = true;
      type = with types; listOf attrs;
      default = repositories;
      description = "Repositories the fetcher downloads.";
    };

  # The revision a fetch of `repository` caches, a ref or a commit snapshot.
  # huggingface_hub records the default branch as `main`. llama.cpp names it
  # after the branch, but pins no revision, so null keeps every ref.
  cachedRevision =
    engine: repository:
    if engine.revisions then lib.defaultTo "main" (repository.revision or null) else null;

  # Directory of `repository` in the hub cache of `cfg`.
  repoDirectory = cfg: repository: "${hubDirectory cfg}/${repoCacheName repository.repo}";

  # A shell test passing if the hub cache of `cfg` holds the revision of
  # `repository`, or any ref without one.
  cachedTest =
    engine: cfg: repository:
    let
      directory = repoDirectory cfg repository;
      revision = cachedRevision engine repository;
    in
    if revision == null then
      "test -d ${lib.escapeShellArg "${directory}/refs"}"
    else
      "test -e ${lib.escapeShellArg "${directory}/refs/${revision}"} || test -d ${lib.escapeShellArg "${directory}/snapshots/${revision}"}";

  # The hub cache entries pruning keeps for `repository`, its directory and
  # the revision it caches.
  pruneEntries =
    engine: repository:
    let
      name = repoCacheName repository.repo;
      revision = cachedRevision engine repository;
    in
    [ name ] ++ lib.optional (revision != null) "${name}/${revision}";

  # The hook of every fetcher, built once per backend. See `mkFetcher`.
  fetchHook =
    pkgs:
    lib.getExe (
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
            if systemctl is-failed --quiet "$server"; then
              action=start
            else
              action=try-restart
            fi
            systemctl reset-failed "$server"
            systemctl "$action" --no-block "$server"
          fi
        '';
      }
    );

  # The fetcher of `workload`, downloading its repositories with the engine's
  # `fetcher` into the hub cache of `cfg`, with the fetch credentials in
  # `credentialDirectory`, before the unit `server` starts. See "Fetching" in
  # the module internals documentation.
  #
  # Its `serviceConfig` holds the fetch credentials and keeps it active once
  # it fetched, like an image unit, so a restarted server does not fetch
  # again. It downloads until done and runs a hook with full privileges, since
  # a native fetcher's user may not manage units. The hook records the refs
  # and snapshot files of the repositories before a fetch (`save`), and
  # afterwards (`apply`) restarts the server if they changed, or starts it
  # again if it failed. The rate limit is reset first, so a planned restart
  # does not count as a crash.
  #
  # Its `script` downloads every repository or keeps it from the cache when
  # that fails, such as offline, as long as it holds the revision.
  mkFetcher =
    {
      engine,
      cfg,
      hook,
      workload,
      server,
      fetcher,
      credentialDirectory,
    }:
    let
      args = lib.escapeShellArgs (
        [ "${server}.service" ] ++ lib.unique (map (repoDirectory cfg) workload.repositories)
      );
    in
    {
      serviceConfig = credentialServiceConfig cfg.fetch.credentials // {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "infinity";
        RuntimeDirectory = fetchUnit server;
        ExecStartPre = "+${hook} save ${args}";
        ExecStartPost = "+${hook} apply ${args}";
      };
      environment = {
        HF_HOME = cfg.cache.directory;
      }
      // resolveCredentialRefs credentialDirectory cfg.fetch.credentials cfg.fetch.environment;
      environmentFile = lib.optional (cfg.fetch.environmentFile != null) cfg.fetch.environmentFile;
      script =
        "set -e\n"
        + lib.concatMapStrings (repository: ''
          ${lib.escapeShellArgs (engine.fetch fetcher repository)} || ${cachedTest engine cfg repository}
        '') workload.repositories;
    };

  # The tmpfiles rule of the root of every socket, which anyone may pass but
  # not list. See "Unix sockets" in the module internals documentation.
  socketRootRule = directory: {
    ${directory}.d = {
      mode = "0711";
      user = "root";
      group = "root";
    };
  };

  # A tmpfiles rule creating the cache `directory` for `owner`.
  cacheDirectoryRule = owner: directory: {
    ${directory}.d = {
      inherit (owner) user group;
      mode = "0700";
    };
  };

  # Hard-fail after 3 errors/hour so journald surfaces the underlying error
  # instead of an endless restart loop.
  sharedUnitConfig = {
    StartLimitBurst = 3;
    StartLimitIntervalSec = 3600;
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
    // credentialServiceConfig workload.credentials
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

  # Enabled workloads of `collection` sorted by ascending `name`, the order
  # workers are emitted and chained in.
  sortedWorkloads =
    collection:
    lib.pipe collection [
      (lib.filterAttrs (_: w: w.enable))
      lib.attrValues
      (lib.sortOn (w: w.name))
    ];

  # Orders every entry after its predecessor when `enable`, so GPU memory
  # profiling never overlaps. `serviceOf` names an entry's service.
  chainEntries =
    enable: serviceOf: entries:
    lib.imap0 (
      index: entry:
      entry
      // {
        after = lib.optional (enable && index > 0) (serviceOf (lib.elemAt entries (index - 1)));
      }
    ) entries;

  # `EnvironmentFile=` layering shared by every workload: the backend-wide file
  # first, so the per-workload one overrides its entries.
  environmentFiles =
    cfg: workload:
    lib.optional (cfg.environmentFile != null) cfg.environmentFile
    ++ lib.optional (workload.environmentFile != null) workload.environmentFile;

  # Configuration every backend emits: the endpoints of its workloads, their
  # firewall ports, the hub cache directory, the update unit and the claims of
  # all of them. `entries` are the backend's workloads, an unlisted one being
  # no inference model, which only a gateway that routes it serves.
  #
  # The update unit `<serviceName>-update`, running under
  # `updateServiceConfig`, is the counterpart of `podman auto-update` for
  # models: it restarts the fetcher of every workload, each of which restarts
  # its server if the model changed, and afterwards, with `fetch.prune`,
  # prunes the hub cache. It exists only with anything to fetch or prune. The
  # fetchers run one at a time in startup order, so the server restarts queue
  # in that order too and keep to the startup chain.
  sharedConfig =
    {
      engine,
      backend,
      serviceName,
      cfg,
      pkgs,
      cacheOwner,
      entries,
      updateServiceConfig ? { },
    }:
    let
      workloads = map (e: e.workload) entries;
      # Every repository and the revision each of them caches.
      pruneKeep = lib.unique (
        lib.concatMap (pruneEntries engine) (lib.concatMap (w: w.repositories) workloads)
      );
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
      updateCommands =
        map (
          fetcher:
          "+${
            lib.escapeShellArgs [
              (lib.getExe' pkgs.systemd "systemctl")
              "restart"
              fetcher
            ]
          }"
        ) (lib.concatMap fetcherOf workloads)
        ++ lib.optional cfg.fetch.prune (
          lib.escapeShellArgs (
            [
              "${pkgs.callPackage ../../pkgs/prune-hub/package.nix { }}"
              (hubDirectory cfg)
            ]
            ++ pruneKeep
          )
        );
      update = updateCommands != [ ];
      owner = [ "services.llmhop.${backend}" ];
    in
    {
      services.llmhop.claims = lib.mkMerge (
        [
          { directory.${cfg.cache.directory} = owner; }
          (lib.optionalAttrs update { unit."${serviceName}-update" = owner; })
        ]
        ++ map workloadClaims workloads
      );
      # Keyed by `name`, not the attribute: that is what the worker advertises
      # and what clients send.
      services.llmhop.endpoints = lib.mkMerge (
        map (
          { workload, unlisted, ... }:
          {
            ${workload.name} = {
              inherit (workload)
                name
                owner
                socket
                ;
              inherit unlisted;
              engine = serviceName;
              url =
                if workload.socket != null then
                  "unix://${workload.socket}"
                else
                  "http://${hostPort workload.host workload.port}";
              # Reachable other than through loopback or the socket.
              exposed = workload.socket == null && (workload.openFirewall || !isLoopback workload.host);
            };
          }
        ) entries
      );
      networking.firewall.allowedTCPPorts = map (w: w.port) (
        lib.filter (w: w.socket == null && w.openFirewall) workloads
      );
      systemd.tmpfiles.settings."10-${serviceName}" = cacheDirectoryRule cacheOwner cfg.cache.directory;
      systemd.services."${serviceName}-update" = lib.mkIf update {
        description = "Fetch and prune the models of ${serviceName}";
        startAt = lib.optional (cfg.fetch.interval != null) cfg.fetch.interval;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = updateCommands;
        }
        // updateServiceConfig;
      };
    };

  # The environment of the server of `workload`, layered under `environment`,
  # the backend's and the workload's own. It reads the hub cache of `cfg` and
  # keeps its runtime caches in its own cache directory rather than the
  # read-only or ephemeral `$HOME`.
  serverEnvironment =
    {
      engine,
      cfg,
      workload,
      environment,
    }:
    let
      cache = unitCacheDirectory workload.unit;
    in
    {
      HF_HOME = cfg.cache.directory;
      # Only the fetcher writes the hub, so even a server with network access
      # never downloads into it.
      HF_HUB_OFFLINE = "1";
      HF_MODULES_CACHE = "${cache}/modules";
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
    // cfg.environment
    // workload.environment;

  # Options of every backend, regardless of kind.
  backendOptions =
    { serviceName, engine }:
    {
      enable = lib.mkEnableOption "${engine.displayName} model serving";
      fetch = {
        interval = mkOption {
          type = with types; nullOr str;
          default = "daily";
          example = "weekly";
          description = ''
            `OnCalendar=` schedule of `${serviceName}-update`, which runs every
            fetcher, so each server whose model changed upstream restarts.
            `null` fetches only when a server starts.
          '';
        };
        prune = lib.mkEnableOption ''
          pruning the hub cache once `${serviceName}-update` ran every fetcher.
          It deletes every repository and revision that no enabled workload
          references, so the cache must belong to this backend alone'';
        environment = mkOption {
          type = with types; attrsOf str;
          default = { };
          example = {
            HF_TOKEN_PATH = "\${cred:llmhop.hf-token}";
            HTTPS_PROXY = "http://proxy.example:3128";
          };
          description = ''
            Environment variables set on every fetcher, such as `HF_TOKEN_PATH`
            for gated Hugging Face repositories or a proxy. Values may
            reference `fetch.credentials` as `''${cred:<name>}`.
            The servers run offline and never see them.
          '';
        };
        environmentFile = mkOption {
          type = with types; nullOr path;
          default = null;
          description = ''
            File in `KEY=VALUE` format forwarded to every fetcher, for
            variables that only exist as values, such as `HF_TOKEN` for
            llama.cpp, which reads no token file.
          '';
        };
        credentials = credentialsOption // {
          description = ''
            Credentials granted to every fetcher, in the format of a
            workload's `credentials`. Reference them from `fetch.environment`
            as `''${cred:<name>}`.
          '';
        };
      };
      cache.directory = mkOption {
        type = types.path;
        default = "/var/cache/${serviceName}";
        description = ''
          `HF_HOME` of every fetcher and server of this backend, created with
          mode `0700`, which the fetchers write and the servers only read.
          Point it at a data disk for large models.
        '';
      };
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Environment variables set on every model service, under the
          `environment` of each model.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr path;
        default = null;
        example = "/etc/${serviceName}/.env";
        description = ''
          File in `KEY=VALUE` format forwarded to every server, loaded before
          the `environmentFile` of each model. Prefer `credentials` for any
          secret a server can read from a file.
        '';
      };
      modelSettings = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          CLI flags forwarded to the server of every model, under the
          `settings` of each model.
          ${settingsRendering engine}
        '';
      };
      openFilesLimit = mkOption {
        type = types.ints.positive;
        default = 1048576;
        description = ''
          File descriptor limit (`LimitNOFILE`) of every server of this
          backend. Increase it if a server logs `accept: Too many open files`.
        '';
      };
      entries = mkOption {
        type = with types; listOf attrs;
        internal = true;
        default = [ ];
        description = "Workloads served beside the models.";
      };
    };

  # The `models` option of a backend, each model a submodule of `modules`
  # whose units `description` names.
  modelsOption =
    {
      engine,
      modules,
      description,
    }:
    mkOption {
      type = types.attrsOf (types.submodule modules);
      default = { };
      example = lib.literalExpression ''
        {
          "qwen3-8b".model = "${engine.modelExample}";
        }
      '';
      inherit description;
    };

  # Identity of llmhop and of the native backends, a named account rather
  # than a `DynamicUser`. `prefix` is the option path, for the documented
  # defaults.
  identityOptions =
    {
      name,
      cfg,
      prefix,
    }:
    {
      user = mkOption {
        type = types.str;
        default = name;
        description = ''
          System user the units run as. The module declares it while it keeps
          its default name, any other user is the deployer's to declare.
        '';
      };
      uid = mkOption {
        type = with types; nullOr ints.unsigned;
        default = null;
        example = 503;
        description = "UID of the declared `user`. `null` lets NixOS allocate one.";
      };
      group = mkOption {
        type = types.str;
        default = cfg.user;
        defaultText = lib.literalExpression "config.${prefix}.user";
        description = ''
          Primary group of `user`. The module declares it while it keeps its
          default name, any other group is the deployer's to declare.
        '';
      };
      gid = mkOption {
        type = with types; nullOr ints.unsigned;
        default = cfg.uid;
        defaultText = lib.literalExpression "config.${prefix}.uid";
        description = "GID of the declared `group`. `null` lets NixOS allocate one.";
      };
    };

  identityConfig =
    { name, cfg }:
    {
      users.users = lib.mkIf (cfg.user == name) {
        ${cfg.user} = {
          description = "${name} service user";
          isSystemUser = true;
          inherit (cfg) group uid;
        };
      };
      users.groups = lib.mkIf (cfg.group == name) { ${cfg.group}.gid = cfg.gid; };
    };

  startupOrderingOption =
    pinNote:
    mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to start model services one at a time by ascending `name`,
        so two workers profiling memory on the same GPU do not race into an
        OOM. Disable only when each model pins itself to a dedicated device
        ${pinNote}.
      '';
    };

  # Submodule of any workload, a model or an auxiliary service. `unitPrefix`
  # precedes its name in the unit name, `listen` gives the listener its server
  # binds, `{ host, port, socket }` from the workload's config, and
  # `derivedSettings` the further flags derived from its options.
  # Both override `settings`, so the gateways, the health probe and the
  # fetcher always agree with the server, while the backend-wide `defaults`
  # only provide defaults.
  workloadModule =
    {
      engine,
      unitPrefix,
      noun,
      socketDirectory,
      listen,
      derivedSettings,
      defaults ? { },
      ...
    }:
    {
      name,
      config,
      options,
      ...
    }:
    let
      socketCapable = engine.socketSettings != null;
      portDescription = "Host port the server binds to on `host`.";
      listener = listen config;
    in
    {
      options = {
        enable = lib.mkEnableOption "${noun} ${name}" // {
          default = true;
        };
        name = mkOption {
          # Allows dots so `qwen3.6-…`-style version suffixes work.
          type = types.strMatching "[[:alnum:]][[:alnum:].-]*";
          default = name;
          description = ''
            Name of this ${noun} in its unit `${unitPrefix}-<name>` and in the
            `model` field clients send, unique across every workload.
          '';
        };
        unit = mkOption {
          type = types.str;
          internal = true;
          readOnly = true;
          default = "${unitPrefix}-${config.name}";
          description = "Unit name of the server, from which everything keyed by unit derives.";
        };
        owner = mkOption {
          type = types.str;
          internal = true;
          readOnly = true;
          default = lib.showOption (lib.init options.enable.loc);
          description = "Option path of this ${noun}, naming it in `services.llmhop.claims`.";
        };
        port = mkOption (
          if socketCapable then
            {
              type = with types; nullOr port;
              default = null;
              description = ''
                ${portDescription}
                `null` binds the unix socket `socket` instead, which claims no
                port, only the gateway and `services.llmhop.socketClients` can
                connect to, and keeps the server off any network.
              '';
            }
          else
            {
              type = types.port;
              description = portDescription;
            }
        );
        socket = mkOption {
          type = with types; nullOr str;
          readOnly = true;
          default =
            if socketCapable && config.port == null then
              "${socketDirectory}/${config.unit}/${socketName}"
            else
              null;
          defaultText = lib.literalMD "`<services.llmhop.socketDirectory>/${unitPrefix}-<name>/${socketName}` while `port` is null, else null";
          description = "Unix socket the server binds, derived from `port`.";
        };
        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "0.0.0.0";
          description = ''
            IP address the server binds `port` to. Any but `127.0.0.1` or
            `::1` requires that no gateway routes it, and lifts the IP address
            filter of an `offline` native server.
          '';
        };
        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to open `port` in the host firewall, which only works
            without a gateway routing this ${noun}. A Quadlet container's
            published port bypasses the firewall either way.
          '';
        };
        environment = mkOption {
          type = with types; attrsOf str;
          default = { };
          description = "Environment variables of this ${noun}'s server, over the backend's `environment`.";
        };
        environmentFile = mkOption {
          type = with types; nullOr path;
          default = null;
          description = ''
            File in `KEY=VALUE` format forwarded to this ${noun}'s server,
            loaded after the backend's `environmentFile`. Prefer `credentials`
            for any secret the server can read from a file.
          '';
        };
        credentials = credentialsOption;
        offline = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether this ${noun}'s server runs without network access. Disable
            it for features that download at runtime, such as media URLs in
            requests. The server serves only what its fetcher downloaded either
            way.
          '';
        };
        settings = mkOption {
          type = with types; attrsOf anything;
          default = { };
          description = ''
            CLI flags of this ${noun}'s server, over the backend's
            `modelSettings`. The listener and the flags derived from the other
            options, such as the served name, always win.
            ${settingsRendering engine}
          '';
        };
      };
      config.settings = lib.mkMerge [
        (lib.mapAttrs (_: lib.mkForce) (
          (
            if listener.socket == null then
              { inherit (listener) host port; }
            else
              engine.socketSettings listener.socket
          )
          // derivedSettings config
        ))
        (lib.mapAttrs (_: lib.mkDefault) defaults)
      ];
    };

  # Submodule of a model, a workload with a model the fetcher downloads,
  # beside the `extraRepositories` every model of the backend needs.
  modelModule =
    args@{
      engine,
      extraRepositories,
      ...
    }:
    { config, ... }:
    {
      imports = [
        (workloadModule (
          args
          // {
            noun = "model";
            derivedSettings = engine.modelSettings;
          }
        ))
      ];
      options = {
        model = mkOption {
          type = types.str;
          example = engine.modelExample;
          description = ''
            ${engine.modelDescription}
            A repository is downloaded by the fetcher, while an absolute path,
            in a container one inside it, is served as is.
          '';
        };
        extraModels = mkOption {
          type = with types; listOf str;
          default = [ ];
          example = [ "Qwen/Qwen3-0.6B" ];
          description = ''
            Further repositories the fetcher downloads beside `model`, such as a
            speculative draft model or a LoRA adapter that `settings`
            reference, since the server cannot download them itself.
          '';
        };
        repositories = repositoriesOption (
          lib.optional (isRepository config.model) {
            repo = config.model;
            revision = config.revision or null;
          }
          ++ map (repo: { inherit repo; }) config.extraModels
          ++ extraRepositories
        );
      }
      // lib.optionalAttrs engine.revisions {
        revision = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "main";
          description = ''
            Branch, tag or commit of `model` that the fetcher downloads and the
            server loads. `null` follows the default branch, so `fetch.interval`
            picks up upstream changes, while a commit pins the model.
          '';
        };
      };
    };
}
