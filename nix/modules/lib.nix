lib:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  # ─── Shared building blocks (private) ────────────────────────────────

  # Append to a systemd list setting that an earlier layer may have set as a
  # scalar, or not at all.
  appendList =
    attrs: key: entries:
    lib.toList (attrs.${key} or [ ]) ++ entries;

  # `host:port`, with IPv6 literals bracketed.
  hostPort =
    host: port:
    if lib.hasInfix ":" host then "[${host}]:${toString port}" else "${host}:${toString port}";

  # Unit name of a model or auxiliary workload. Everything keyed by unit, from
  # its socket path to its credential directory, derives from this.
  workloadUnit = prefix: workload: "${prefix}-${workload.name}";

  # Permissive label for unit and routing-key names. Allows dots so
  # `qwen3.6-…`-style version suffixes work.
  modelLabel = types.strMatching "[[:alnum:]][[:alnum:].-]*";

  credentialReferencePrefix = "\${cred:";
  # Root of everything llmhop mounts into a container.
  containerRuntimeDirectory = "/run/llmhop";
  credentialDirectory = "${containerRuntimeDirectory}/credentials";

  credentialType = types.either types.path (
    types.submodule {
      options = {
        source = mkOption {
          type = types.path;
          description = "File or socket from which systemd loads the credential.";
        };
        encrypted = mkOption {
          type = types.bool;
          default = false;
          description = "Whether to load and decrypt the source with `LoadCredentialEncrypted=`.";
        };
      };
    }
  );

  # A credential name becomes a systemd credential ID, which systemd renders as
  # a plain file name under `$CREDENTIALS_DIRECTORY`. Anything carrying a path
  # separator or exceeding 255 characters is rejected by systemd itself, so it
  # is caught here rather than at rebuild or service start. The credential
  # passes through unchanged, so the check composes with `mapAttrs`.
  checkCredentialName =
    name:
    lib.throwIfNot (lib.match "[[:alnum:]_][[:alnum:]_.-]{0,254}" name != null)
      "services.llmhop: `${name}` is not a valid systemd credential name. Start with an alphanumeric character or `_`, continue with those plus `.` and `-`, and stay within 255 characters.";

  credentialsOption = mkOption {
    type = types.attrsOf credentialType;
    default = { };
    apply = lib.mapAttrs checkCredentialName;
    example = lib.literalExpression ''
      {
        apiKeys = "/run/secrets/api-keys";
        tlsKey = {
          source = "/etc/credstore.encrypted/tls-key";
          encrypted = true;
        };
      }
    '';
    description = ''
      Credentials granted exclusively to this service through systemd.
      A path uses `LoadCredential=`. The attribute form can select
      `LoadCredentialEncrypted=` for a `systemd-creds` encrypted source.

      Reference the resulting read-only file from `settings` as
      `''${cred:<name>}`. The module resolves the reference to the native or
      container credential path without copying its contents to the Nix store
      or command line.
    '';
  };

  normalizeCredential =
    value:
    if value ? source then
      value
    else
      {
        source = value;
        encrypted = false;
      };

  # Append this workload's `LoadCredential=`/`LoadCredentialEncrypted=` entries
  # to whatever `serviceConfig` already declares.
  mergeCredentialServiceConfig =
    serviceConfig: credentials:
    let
      normalized = lib.mapAttrs (_: normalizeCredential) credentials;
      render =
        encrypted:
        lib.mapAttrsToList (name: value: "${name}:${toString value.source}") (
          lib.filterAttrs (_: value: value.encrypted == encrypted) normalized
        );
    in
    serviceConfig
    // lib.optionalAttrs (credentials != { }) {
      LoadCredential = appendList serviceConfig "LoadCredential" (render false);
      LoadCredentialEncrypted = appendList serviceConfig "LoadCredentialEncrypted" (render true);
    };

  # Rewrite every `${cred:<name>}` reference in a settings tree to the path the
  # credential is mounted at, so secrets reach the server as a file name rather
  # than a value on the command line.
  resolveCredentialRefs =
    directory: credentials:
    let
      names = lib.attrNames credentials;
      references = map (name: "${credentialReferencePrefix}${name}}") names;
      paths = map (name: "${directory}/${name}") names;
      resolve =
        value:
        if lib.isString value then
          let
            resolved = lib.replaceStrings references paths value;
          in
          if lib.hasInfix credentialReferencePrefix resolved then
            throw "unknown credential reference in `${value}`"
          else
            resolved
        else if lib.isList value then
          map resolve value
        else if lib.isAttrs value && !lib.isDerivation value then
          lib.mapAttrs (_: resolve) value
        else
          value;
    in
    resolve;

  systemdCredentialDirectory = unit: "/run/credentials/${unit}.service";

  # Settings as a server receives them: `managed` over `settings`, with every
  # `${cred:…}` resolved against the credential `directory`.
  resolveSettings =
    directory: credentials: managed: settings:
    resolveCredentialRefs directory credentials (withManagedSettings managed settings);

  # ─── CLI rendering (private) ─────────────────────────────────────────

  # How each backend's parser reads the two `settings` shapes that have no
  # portable rendering, keyed by the unsuffixed service name so a native backend
  # and its quadlet twin share one entry. `negateBools` means the parser
  # registers a `--no-<key>` twin for every boolean; `listStyle` picks between
  # `--key a b` ("values") and `--key a --key b` ("repeat"). See the module
  # internals documentation for why neither axis can be delegated to `lib.cli`.
  # `socketSettings` renders the flags binding a unix socket, or is null for a
  # server that only listens on TCP.
  cliDialects = {
    llama-cpp = {
      negateBools = true;
      listStyle = "repeat";
      # llama-server binds a unix socket when the host ends in `.sock`.
      socketSettings = path: {
        host = path;
        port = null;
      };
    };
    vllm = {
      negateBools = true;
      listStyle = "values";
      socketSettings = path: {
        uds = path;
        host = null;
        port = null;
      };
    };
    sglang = {
      negateBools = false;
      listStyle = "values";
      socketSettings = null;
    };
  };

  cliDialect = backend: cliDialects.${quadletServiceName backend};

  # Whether `backend`'s server can bind a unix socket instead of a port.
  socketCapable = backend: (cliDialect backend).socketSettings != null;

  # Listener flags binding `socket`, or `host:port` when `socket` is null.
  listenSettings =
    backend:
    {
      host,
      port,
      socket,
    }:
    if socket == null then { inherit host port; } else (cliDialect backend).socketSettings socket;

  # The flags a workload's server receives: its `settings` under the backend's
  # `managed` flags and the `listen` flags, with every `${cred:…}` resolved
  # against the credential `directory`.
  workloadFlags =
    {
      backend,
      directory,
      listen,
      managed,
      workload,
      settings,
    }:
    resolveSettings directory workload.credentials (managed // listenSettings backend listen) settings;

  # What a host process binds, and what a container binds on `containerPort`
  # or the mounted `socket`, in the shape `listenSettings` takes.
  hostListen = workload: {
    host = "127.0.0.1";
    inherit (workload) port socket;
  };
  containerListen = containerPort: socket: {
    host = "0.0.0.0";
    port = containerPort;
    socket = if socket != null then containerSocketPath else null;
  };

  # `false` becomes `--no-<key>` (and `no-<key> = false` becomes `--<key>`) for
  # the backends whose parsers auto-register the negated twin. Other values
  # pass through untouched.
  flipBoolFlags = lib.mapAttrs' (
    name: value:
    if value == false then
      lib.nameValuePair (
        if lib.hasPrefix "no-" name then lib.removePrefix "no-" name else "no-${name}"
      ) true
    else
      lib.nameValuePair name value
  );

  # Strings, paths and derivations render verbatim, everything else through JSON.
  cliValue = value: if lib.isStringLike value then toString value else lib.toJSON value;

  # One-sentence dialect summary appended to every `settings` description.
  settingsRendering =
    backend:
    let
      dialect = cliDialect backend;
    in
    "Rendered as `--<key> <value>`, with ${
      if dialect.negateBools then
        "`false` as `--no-<key>`"
      else
        "`false` dropped, since this CLI pairs `--enable-X` with `--disable-X`"
    } and a list ${
      if dialect.listStyle == "values" then "handed to a single flag" else "repeating the flag"
    }. See [settings rendering](../README.md#settings-rendering) for the full rules.";

  # Render a `settings` attribute set into the argv `backend`'s parser expects,
  # following its entry in `cliDialects`. A `"values"` list always spends one
  # argv entry per element, `sep` or not: argparse stops consuming values after
  # the one glued onto `--<key>=`.
  renderCliArgsWith =
    sep: backend:
    let
      dialect = cliDialect backend;
      flag =
        name: value:
        if sep == null then
          [
            "--${name}"
            (cliValue value)
          ]
        else
          [ "--${name}${sep}${cliValue value}" ];
      # `false` only reaches this point for dialects without a negated twin,
      # `flipBoolFlags` having rewritten the key otherwise.
      render =
        name: value:
        if value == null || value == false then
          [ ]
        else if value == true then
          [ "--${name}" ]
        else if !lib.isList value then
          flag name value
        else if dialect.listStyle == "values" then
          lib.optionals (value != [ ]) ([ "--${name}" ] ++ map cliValue value)
        else
          lib.concatMap (flag name) value;
    in
    attrs:
    lib.concatLists (
      lib.mapAttrsToList render (if dialect.negateBools then flipBoolFlags attrs else attrs)
    );

  # Flag and value as separate argv entries, what `utils.escapeSystemdExecArgs`
  # takes.
  renderCliArgs = renderCliArgsWith null;

  # One shell-quoted string of `--key=value` tokens, what a Quadlet `Exec=` takes.
  renderCliArgsShell =
    backend:
    let
      render = renderCliArgsWith "=" backend;
    in
    attrs: lib.escapeShellArgs (render attrs);

  # Merge the flags llmhop derives from its own options (listener, routing
  # name) onto the user's `settings`. `managed` wins, so an override can
  # neither move a server off loopback nor off the port or socket the
  # readiness probe and llmhop route to.
  withManagedSettings = managed: settings: settings // managed;

  # ─── Option builders (private) ───────────────────────────────────────

  # Top-level options every backend exposes, regardless of kind.
  baseOptions =
    { backend }:
    {
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Environment variables set on every model service.
          Merged with `services.llmhop.${backend}.models.<name>.environment`; per-model
          entries take precedence.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr path;
        default = null;
        example = "/etc/${backend}/.env";
        description = ''
          File in `KEY=VALUE` format forwarded to every service.
          Use only for upstream features that require environment variables,
          such as `HF_TOKEN` for gated Hugging Face repositories. Environment
          variables are not systemd credentials and are visible to every model.
          Loaded before `services.llmhop.${backend}.models.<name>.environmentFile`, so
          per-model files override these entries.
        '';
      };
      modelSettings = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          CLI flags forwarded to the model server for every model.
          ${settingsRendering backend}
          Merged with `services.llmhop.${backend}.models.<name>.settings`; per-model
          entries take precedence.
        '';
      };
      openFilesLimit = mkOption {
        type = types.ints.positive;
        default = 1048576;
        description = ''
          File descriptor limit (`LimitNOFILE`) applied to every ${backend} systemd unit.
          Increase if the server logs `accept: Too many open files` under concurrent load.
        '';
      };
    };

  # Quadlet backends live under the `<service>-quadlet` option namespace but
  # emit units named `<service>-<model>`, matching their native twin (hence the
  # mutual-exclusion assertion in `quadlet.mkConfig`).
  quadletServiceName = lib.removeSuffix "-quadlet";

  # Identity of units that always run as a named account, e.g. because their
  # directories outlive any single start. `prefix` is the option path, for the
  # documented defaults.
  staticIdentityOptions =
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

  # Identity of units that run as a `DynamicUser` unless a user is named.
  dynamicIdentityOptions =
    { name }:
    {
      user = mkOption {
        type = with types; nullOr str;
        default = null;
        description = ''
          System user the units run as, which is the deployer's to declare.
          `null` allocates one per unit through `DynamicUser=`.
        '';
      };
      group = mkOption {
        type = types.str;
        default = name;
        description = ''
          Static primary group of the units, also beside a `DynamicUser`. The
          module declares it while it keeps its default name, any other group
          is the deployer's to declare.
        '';
      };
    };

  # Config-side twin of both identity options. `mkIf` guards the whole
  # attrset, since a `null` user cannot name an attribute.
  identityConfig =
    { name, cfg }:
    {
      users.users = lib.mkIf (cfg.user == name) {
        ${cfg.user} = {
          description = "${name} service user";
          isSystemUser = true;
          inherit (cfg) group;
          uid = cfg.uid or null;
        };
      };
      users.groups = lib.mkIf (cfg.group == name) { ${cfg.group}.gid = cfg.gid or null; };
    };

  identityServiceConfig =
    cfg:
    {
      Group = cfg.group;
    }
    // (if cfg.user == null then { DynamicUser = true; } else { User = cfg.user; });

  # Startup chaining by model name, shared by every multi-worker GPU backend.
  # `pinNote` names the backend-specific way to pin a model to one device.
  startupOrderingOption =
    { pinNote }:
    mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to chain enabled model services by ascending `name` during startup.
        GPU-memory profiling races otherwise: two workers booting on the same device
        each see it as fully free and race to claim their share, leading to OOM.
        Disable only when each model pins itself to a dedicated device ${pinNote}.
      '';
    };

  # `port` plus the `socket` derived from it. A socket-capable workload
  # defaults to `port = null`, which binds `socket` instead of a TCP port.
  # `workload` is the submodule's own config, read for `port` and `name`.
  listenerOptions =
    {
      socketCapable,
      socketDirectory ? null,
      unitPrefix,
      portDescription,
      workload,
    }:
    {
      port = mkOption (
        if socketCapable then
          {
            type = types.nullOr types.port;
            default = null;
            description = ''
              ${portDescription}
              `null` binds the unix socket `socket` instead, which claims no port
              and only llmhop can connect to.
            '';
          }
        else
          {
            type = types.port;
            description = portDescription;
          }
      );
      socket = mkOption {
        type = types.nullOr types.str;
        readOnly = true;
        default =
          if socketCapable && workload.port == null then
            "${socketDirectory}/${workloadUnit unitPrefix workload}/${socketName}"
          else
            null;
        defaultText = lib.literalMD "`<services.llmhop.socketDirectory>/${unitPrefix}-<name>/${socketName}` while `port` is null, else null";
        description = "Unix socket the server binds, derived from `port`.";
      };
    };

  # Per-workload options every model and auxiliary workload exposes, whatever
  # the backend. `backend` is the (possibly suffixed) option namespace used in
  # cross-references, `serviceName` the unsuffixed prefix of the generated unit
  # names, and `noun` names the workload in the prose.
  baseWorkloadOptions =
    {
      backend,
      serviceName ? backend,
      noun,
      name,
      workload,
      socketDirectory ? null,
      portDescription,
    }:
    {
      enable = mkEnableOption "${noun} ${name}" // {
        default = true;
      };
      name = mkOption {
        type = modelLabel;
        default = name;
        description = ''
          Canonical identifier for this ${noun}. Used for the unit name
          (`${serviceName}-<name>`) and as the routing key registered with llmhop,
          which clients send in the `model` field. Shares one namespace with
          every other routing key, so a collision fails evaluation.

          Defaults to the attribute key, so the key itself must match the
          required label format.
        '';
      };
    }
    // listenerOptions {
      inherit
        socketDirectory
        portDescription
        workload
        ;
      socketCapable = socketCapable backend;
      unitPrefix = serviceName;
    }
    // {
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Additional environment variables set on this ${noun}'s service.
          Merged with `services.llmhop.${backend}.environment`; per-${noun} entries
          take precedence.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          File in `KEY=VALUE` format forwarded to this ${noun}'s service.
          Loaded after `services.llmhop.${backend}.environmentFile`, so its entries
          override global ones. Use `credentials` for file-capable secret
          settings. Must be readable by the user systemd reads it as.
        '';
      };
      credentials = credentialsOption;
    };

  # Per-model options every backend exposes, regardless of kind.
  baseModelOptions =
    args@{ backend, ... }:
    baseWorkloadOptions (args // { noun = "model"; })
    // {
      settings = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          CLI flags forwarded to the model server for this model.
          ${settingsRendering backend}
          Merged with `services.llmhop.${backend}.modelSettings`; per-model entries
          take precedence. The flags llmhop derives from the model options
          (its served name and listener) always win over both.
        '';
      };
    };

  # Per-workload escape hatches for native units: extra `[Service]` and `[Unit]`
  # settings merged last, so they win over the hardened baseline and any
  # backend relaxations.
  serviceConfigOption =
    { serviceName }:
    mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        MemoryHigh = "64G";
      };
      description = ''
        Extra `[Service]` settings merged into this workload's
        `${serviceName}-<name>` unit after the hardened baseline and
        backend-specific relaxations. The module retains ownership of
        `ExecStart`, `KillMode`, and `Type` because they implement readiness
        supervision as one lifecycle contract.
      '';
    };

  unitConfigOption =
    { serviceName }:
    mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        StartLimitBurst = 10;
      };
      description = ''
        Extra `[Unit]` settings merged into this workload's
        `${serviceName}-<name>` unit after the shared baseline.

        Ordering and dependency directives (`After=`, `Requires=`, `Wants=`)
        do not belong here: NixOS renders those from the `after`, `requires`
        and `wants` options, so a definition of the same key in `unitConfig`
        conflicts with it instead of merging. Declare them on
        `systemd.services."${serviceName}-<name>"` from your own module,
        where the module system concatenates them with what this one sets.
      '';
    };

  # ─── Unix sockets (private) ──────────────────────────────────────────

  # A workload without a `port` binds `socketName` in a `RuntimeDirectory=` of
  # its own below `services.llmhop.socketDirectory`, reachable by llmhop
  # through the unit's group, or through the root's default ACL for Quadlet.
  # See "Unix sockets" in the module internals documentation.
  socketName = "http.sock";

  # Keeps group write, which the kernel would otherwise mask off the socket
  # and thereby off its group or ACL.
  socketUMask = "0007";

  # Where a container sees its socket directory. Beside, not over, the
  # credential mount.
  containerSocketDirectory = "${containerRuntimeDirectory}/socket";
  containerSocketPath = "${containerSocketDirectory}/${socketName}";

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

  # ─── Unit defaults (private) ─────────────────────────────────────────

  # Hard-fail after 3 errors/hour so journald surfaces the underlying error
  # instead of an endless restart loop.
  sharedUnitConfig = {
    StartLimitBurst = 3;
    StartLimitIntervalSec = 3600;
  };

  # Hour-long `TimeoutStartSec` covers cold-start model downloads plus GPU
  # memory profiling; `RestartSec = 30` debounces crash loops.
  sharedServiceConfig = {
    TimeoutStartSec = 3600;
    RestartSec = 30;
  };

  # Universal systemd-exec(5) hardening shared between the llmhop reverse proxy
  # and the native model workers. Quadlet workers skip this layer — podman
  # handles isolation at the container level. `SocketBind*` is intentionally
  # absent: it pairs with a per-unit `SocketBindAllow` that only workers set.
  hardenedServiceConfig = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    NoNewPrivileges = true;
    PrivateIPC = true;
    PrivateMounts = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    MemoryDenyWriteExecute = true;
    LockPersonality = true;
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
    SystemCallErrorNumber = "EPERM";
    ProtectProc = "invisible";
    ProtectHostname = true;
    ProcSubset = "pid";
  };

  # Relaxations NCCL needs to initialise for multi-GPU / tensor-parallel
  # inference; see the module internals documentation.
  ncclServiceConfig = {
    RestrictAddressFamilies = hardenedServiceConfig.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
    SocketBindAllow = "tcp";
  };

  # Keep the transport on loopback and off any InfiniBand fabric. Applied as
  # environment defaults, so a deployer can still override them per model.
  ncclEnvironment = {
    NCCL_SOCKET_IFNAME = "lo";
    NCCL_IB_DISABLE = "1";
  };

  # Relaxations a GPU worker needs on top of the hardened baseline; the
  # rationale for each is in the module internals documentation.
  gpuServiceConfig = {
    PrivateDevices = false;
    SupplementaryGroups = [
      "render"
      "video"
    ];
    PrivateUsers = "identity";
    MemoryDenyWriteExecute = false;
    LimitMEMLOCK = "infinity";
    ProcSubset = "all";
  };

  # Where a GPU worker's runtime caches go, redirected out of the read-only
  # `$HOME` into the unit's own cache root.
  gpuCacheEnvironment = cacheBase: {
    TRITON_CACHE_DIR = "${cacheBase}/triton";
    TORCHINDUCTOR_CACHE_DIR = "${cacheBase}/inductor";
    MIOPEN_USER_DB_PATH = "${cacheBase}/miopen";
    MIOPEN_CUSTOM_CACHE_DIR = "${cacheBase}/miopen";
    SYCL_CACHE_PERSISTENT = "1";
    SYCL_CACHE_DIR = "${cacheBase}/sycl";
    NEO_CACHE_PERSISTENT = "1";
    NEO_CACHE_DIR = "${cacheBase}/neo";
  };

  # ─── Workload collections (private) ──────────────────────────────────

  # Enabled subset of any `attrsOf { enable; ... }` workload collection.
  enabled = lib.filterAttrs (_: w: w.enable);

  # Enabled-model subset shared by registry helpers and backend iteration.
  enabledModels = cfg: enabled cfg.models;

  # Enabled models and auxiliaries that bind a unix socket.
  socketWorkloads =
    cfg: auxiliaries:
    lib.filter (w: w.socket or null != null) (
      lib.attrValues (enabledModels cfg) ++ lib.attrValues auxiliaries
    );

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

  # Resolve `image:tag` or `image@digest`. `tag` and `digest` are mutually
  # exclusive; `defaultTag` is used when both are null.
  resolveImageRef =
    {
      image,
      tag,
      digest,
      defaultTag ? null,
      label,
    }:
    if tag != null && digest != null then
      throw "${label}: `tag` and `digest` are mutually exclusive."
    else if digest != null then
      "${image}@${digest}"
    else if tag != null then
      "${image}:${tag}"
    else if defaultTag != null then
      "${image}:${defaultTag}"
    else
      throw "${label}: one of `tag`, `digest`, or a default tag must be provided.";

  # Every backend binds the host loopback or a socket, and llmhop shares the host.
  # `workload` carries `port` and, for socket-capable ones, `socket`.
  workerUrl =
    workload:
    if workload.socket != null then
      "unix://${workload.socket}"
    else
      "http://127.0.0.1:${toString workload.port}";

  # Cross-cutting NixOS fragment every backend emits: its llmhop models and its
  # contributions to the three registries `core.nix` asserts on. Registry keys
  # are the owning option path, so a collision names what to change.
  #
  # `auxiliaries` covers everything a backend runs that is not a model, as
  # `{ <label> = { port, unit ? null, model ? null }; }`. One entry per service
  # rather than one map per registry, so a label cannot go missing from a
  # dimension it belongs to. `model` is the llmhop routing key, registered
  # `unlisted` so the service shares llmhop's auth but stays out of the catalog.
  # Sockets need no registry, since their paths derive from unit names.
  mkSharedConfig =
    {
      backend,
      serviceName,
      cfg,
      auxiliaries ? { },
    }:
    let
      models = enabledModels cfg;
      unitName = workloadUnit serviceName;
      # An entry joins a registry only if it carries that field.
      mkRegistry =
        modelValue: auxValue:
        lib.filterAttrs (_: value: value != null) (
          lib.mapAttrs' (name: m: lib.nameValuePair "${backend}.models.${name}" (modelValue m)) models
          // lib.mapAttrs' (label: aux: lib.nameValuePair "${backend}.${label}" (auxValue aux)) auxiliaries
        );
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
        portsRegistry = mkRegistry (m: m.port) (aux: aux.port);
        unitsRegistry = mkRegistry unitName (aux: aux.unit or null);
        modelsRegistry = mkRegistry (m: m.name) (aux: aux.model or null);
      };
    };

  # ─── Quadlet helpers (private) ───────────────────────────────────────

  # `socket` adds the options of a container that may bind a unix socket.
  mkQuadletObjectOptions =
    {
      description ? "this container",
      socket ? false,
    }:
    let
      sectionOption =
        section:
        mkOption {
          type = with types; attrsOf anything;
          default = { };
          description = "Extra `[${section}]` settings applied to ${description}.";
        };
    in
    {
      containerConfig = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          Extra `[Container]` settings applied to ${description}.
          Keys use Quadlet's native `PascalCase` names, including `User`,
          `UserNS`, `UIDMap`, `GIDMap`, `SubUIDMap`, and `SubGIDMap`.
        '';
      };
      serviceConfig = sectionOption "Service";
      unitConfig = sectionOption "Unit";
      quadletConfig = sectionOption "Quadlet";
      extraConfig = mkOption {
        type = with types; attrsOf (attrsOf anything);
        default = { };
        description = ''
          Extra unit sections applied to ${description} after all generated
          sections. This is the final escape hatch for settings that do not
          fit one of the dedicated `*Config` options.
        '';
      };
      mountOptions = {
        credentials = mkOption {
          type = with types; listOf str;
          default = [ ];
          example = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
          description = ''
            Podman volume options appended to ${description}'s systemd
            credential mount. Use an `idmap` mapping when `[Container] User=`
            selects a non-root identity. The mount is always read-only.
          '';
        };
      }
      // lib.optionalAttrs socket {
        socket = mkOption {
          type = with types; listOf str;
          default = [ "U" ];
          example = [
            "U"
            "z"
          ];
          description = ''
            Podman volume options of ${description}'s socket directory mount.
            `U` hands the directory to whatever host UID the container user maps
            to, so the socket works under any `User=` and `UserNS=`. Add `z` on
            SELinux hosts.
          '';
        };
      };
    };

  quadletMountSuffix =
    options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

  # Per-workload overrides of the backend's image.
  mkQuadletImageOptions =
    { noun }:
    {
      tag = mkOption {
        type = with types; nullOr str;
        default = null;
        description = ''
          Tag of the container image used for this ${noun}.
          Mutually exclusive with `digest`.
        '';
      };
      digest = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "sha256:a73fb0b9046fee099f7c1829d2548e6cc1740f4c2776a6855fa659ae5d0deb49";
        description = ''
          Immutable digest of the container image (e.g. `sha256:…`).
          Mutually exclusive with `tag`.
        '';
      };
    };

  # Image reference and pull policy for one container. Digest-locked images use
  # `Pull=missing`; tag-tracking ones use `Pull=newer`.
  mkQuadletImageArgs =
    {
      image,
      defaultTag,
      workload,
      label,
    }:
    {
      Image = resolveImageRef {
        inherit image defaultTag label;
        inherit (workload) tag digest;
      };
      Pull = if workload.digest != null then "missing" else "newer";
    };

  # `[Container]` fields every workload of a quadlet backend shares: the cache
  # bind-mount, the env var pointing the runtime at it, and the global/per-
  # workload environment layers.
  mkQuadletContainerRuntime = cfg: workload: {
    Volume = [
      "${cfg.cache.directory}:${cfg.cache.containerDirectory}${quadletMountSuffix cfg.cache.mountOptions}"
    ];
    EnvironmentFile = environmentFiles cfg workload;
    Environment = {
      ${cfg.cache.environmentVariable} = cfg.cache.containerDirectory;
    }
    // cfg.environment
    // workload.environment;
  };

  # Render a Quadlet container worker fragment. The optional host user selects
  # the systemd user manager. Native Quadlet section overrides are layered
  # globally and then per container.
  #
  # The server binds the host `socket` mounted into the container, else
  # `containerPort`, published on the host `port` unless that is null (host
  # networking). A rootless `socket` needs `podman` to clear it. See "Unix
  # sockets" in the module internals documentation. The health probe reaches
  # a server bound to `bindAddress`, through loopback for a wildcard.
  mkQuadletWorker =
    {
      cfg,
      containerPort,
      port ? null,
      socket ? null,
      podman ? null,
      healthPath ? "/health",
      bindAddress ? "localhost",
      healthTLS ? false,
      healthStartPeriod ? "30m",
      serviceConfig ? { },
      unitConfig ? { },
      containerConfig ? { },
      credentials ? { },
      overrides ? { },
      mounts ? [ ],
    }:
    let
      rootless = cfg.quadlet.user != null;
      healthScheme = if healthTLS then "https" else "http";
      healthHost =
        {
          "0.0.0.0" = "127.0.0.1";
          "::" = "::1";
        }
        .${bindAddress} or bindAddress;
      # Appended after every override, so a user `Volume` cannot drop them.
      allMounts =
        mounts
        ++ lib.optional (
          socket != null
        ) "${dirOf socket}:${containerSocketDirectory}${quadletMountSuffix overrides.mountOptions.socket}"
        ++
          lib.optional (credentials != { })
            "%d:${credentialDirectory}${quadletMountSuffix ([ "ro" ] ++ overrides.mountOptions.credentials)}";
      mergedServiceConfig =
        sharedServiceConfig
        // {
          # `Restart = "always"` overrides quadlet-nix's `on-failure` default;
          # see the module internals documentation.
          Restart = "always";
          LimitNOFILE = cfg.openFilesLimit;
        }
        // lib.optionalAttrs (socket != null && rootless) {
          ExecStartPre = "${lib.getExe podman} unshare rm -f ${socket}";
        }
        // serviceConfig
        // cfg.quadlet.serviceConfig
        // overrides.serviceConfig;
      # Minimal hardening (podman handles the rest) plus an HTTP readiness
      # probe. The rootfs stays writable; `/tmp` is a tmpfs for fast scratch.
      mergedContainerConfig = {
        NoNewPrivileges = true;
        DropCapability = "all";
        Tmpfs = [ "/tmp" ];
        Notify = "healthy";
        HealthCmd = "curl --fail --silent --show-error ${lib.optionalString healthTLS "--insecure "}${
          if socket != null then
            "--unix-socket ${containerSocketPath} ${healthScheme}://localhost"
          else
            "${healthScheme}://${hostPort healthHost containerPort}"
        }${healthPath}";
        HealthStartPeriod = healthStartPeriod;
        HealthInterval = "10s";
        HealthTimeout = "5s";
      }
      // lib.optionalAttrs (socket != null) { Umask = socketUMask; }
      // lib.optionalAttrs (port != null) {
        PublishPort = [ "127.0.0.1:${toString port}:${toString containerPort}" ];
      }
      // containerConfig
      // cfg.quadlet.containerConfig
      // overrides.containerConfig;
    in
    {
      uid = if rootless then cfg.quadlet.user.uid else null;
      serviceConfig = mergeCredentialServiceConfig (
        mergedServiceConfig
        // lib.optionalAttrs (!rootless) (socketRuntimeDirectory mergedServiceConfig socket)
      ) credentials;
      unitConfig = sharedUnitConfig // unitConfig // cfg.quadlet.unitConfig // overrides.unitConfig;
      quadletConfig = cfg.quadlet.quadletConfig // overrides.quadletConfig;
      extraConfig = lib.recursiveUpdate cfg.quadlet.extraConfig overrides.extraConfig;
      containerConfig =
        mergedContainerConfig
        // lib.optionalAttrs (allMounts != [ ]) {
          Volume = appendList mergedContainerConfig "Volume" allMounts;
        };
    };

  # One workload's container: `mkQuadletWorker` with the backend's image,
  # cache and environment, running `arguments` followed by `settings` rendered
  # as `backend`'s flags under `managed` and the listener. `collection` is the
  # attribute of `services.llmhop.<backend>` holding the workload, so models
  # and auxiliaries such as watermark detectors share it.
  mkQuadletWorkloadContainer =
    {
      backend,
      cfg,
      config,
      collection,
      workload,
      containerPort,
      settings,
      managed ? { },
      arguments ? [ ],
      containerConfig ? { },
      mounts ? [ ],
      serviceConfig ? { },
      unitConfig ? { },
    }:
    mkQuadletWorker {
      inherit
        cfg
        containerPort
        mounts
        serviceConfig
        unitConfig
        ;
      inherit (workload) port socket credentials;
      inherit (config.virtualisation.quadlet) podman;
      overrides = workload.quadlet;
      containerConfig =
        mkQuadletContainerRuntime cfg workload
        // mkQuadletImageArgs {
          inherit (cfg) image;
          inherit workload;
          defaultTag = cfg.tag;
          label = "services.llmhop.${backend}.${collection}.${workload.name}";
        }
        // containerConfig
        // {
          Exec = lib.escapeShellArgs (
            arguments
            ++ renderCliArgsWith "=" backend (workloadFlags {
              inherit
                backend
                managed
                workload
                settings
                ;
              directory = credentialDirectory;
              listen = containerListen containerPort workload.socket;
            })
          );
        };
    };

  # ─── Native (systemd) helpers (private) ──────────────────────────────

  # `llmhop-notify` is resolved from this flake rather than from
  # `services.llmhop.package`; see the module internals documentation.
  notifyExe = pkgs: lib.getExe' (pkgs.callPackage ../package.nix { }) "llmhop-notify";

  # Render a systemd worker unit fragment from the worker's argv. Returns
  # `{ serviceConfig, unitConfig }` with the shared baseline plus full
  # systemd-exec(5) hardening merged in and lifecycle settings enforced last.
  # `llmhop-notify` keeps the unit activating until `healthPath` on `url`
  # answers.
  mkNativeWorker =
    {
      openFilesLimit,
      pkgs,
      utils,
      url,
      healthPath ? "/health",
      execStart,
      serviceConfig ? { },
      unitConfig ? { },
      credentials ? { },
    }:
    {
      serviceConfig = mergeCredentialServiceConfig (
        sharedServiceConfig
        // hardenedServiceConfig
        // {
          LimitNOFILE = openFilesLimit;
          SocketBindDeny = "any";
        }
        // serviceConfig
        // {
          KillMode = "control-group";
          Type = "notify";
          ExecStart = utils.escapeSystemdExecArgs (
            [
              (notifyExe pkgs)
              "-url"
              url
              "-health-path"
              healthPath
            ]
            ++ execStart
          );
        }
      ) credentials;
      unitConfig = sharedUnitConfig // unitConfig;
    };

  # One systemd unit for any workload of a native backend: the cache root every
  # runtime is redirected into, plus the `mkNativeWorker` hardening and
  # readiness baseline. `workload` is anything carrying `name`, `port`,
  # `environment`, `environmentFile`, `credentials`, `serviceConfig` and
  # `unitConfig`, so model workers and auxiliary services share one body.
  # `cfg` must carry `openFilesLimit`, `environment` and `environmentFile`.
  mkNativeService =
    {
      unitName,
      description,
      subdir,
      cfg,
      pkgs,
      utils,
      workload,
      execStart,
      healthPath ? "/health",
      after ? [ ],
      path ? [ ],
      environment ? (_cacheBase: { }),
      serviceConfig ? { },
    }:
    let
      # CacheDirectory root, owned by the unit; see `gpuCacheEnvironment`.
      cacheBase = "/var/cache/${subdir}";
      mergedServiceConfig = {
        Restart = "on-failure";
        CacheDirectory = subdir;
        WorkingDirectory = cacheBase;
        EnvironmentFile = environmentFiles cfg workload;
      }
      # Its group owns the worker socket, see `systemd.mkConfig`.
      // identityServiceConfig cfg
      // (
        if workload.socket != null then
          { UMask = socketUMask; }
        else
          {
            UMask = "0077";
            SocketBindAllow = "tcp:${toString workload.port}";
          }
      )
      // serviceConfig
      # Last, so the per-workload escape hatch wins over every default.
      // workload.serviceConfig;
    in
    lib.nameValuePair unitName (
      {
        inherit description path;
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ] ++ after;
        environment =
          gpuCacheEnvironment cacheBase // environment cacheBase // cfg.environment // workload.environment;
      }
      // mkNativeWorker {
        inherit (cfg) openFilesLimit;
        inherit
          pkgs
          utils
          execStart
          healthPath
          ;
        inherit (workload) credentials unitConfig;
        url = workerUrl workload;
        serviceConfig = mergedServiceConfig // socketRuntimeDirectory mergedServiceConfig workload.socket;
      }
    );

  # `mkNativeService` for a GPU model worker: device access, the NCCL/RCCL
  # environment, and its own `StateDirectory` for non-regenerable state.
  # `previous` is the preceding model in the ascending startup chain, or null
  # when the backend does not chain.
  mkNativeModelService =
    {
      serviceName,
      cfg,
      pkgs,
      utils,
      model,
      execStart,
      previous ? null,
      path ? [ ],
      environment ? (_cacheBase: { }),
      serviceConfig ? { },
    }:
    let
      subdir = "${serviceName}/${model.name}";
    in
    mkNativeService {
      inherit
        subdir
        cfg
        pkgs
        utils
        execStart
        path
        ;
      unitName = workloadUnit serviceName model;
      description = "${serviceName} server for ${model.name}";
      workload = model;
      after = lib.optional (previous != null) "${workloadUnit serviceName previous}.service";
      environment = cacheBase: environment cacheBase // ncclEnvironment;
      serviceConfig = {
        KillSignal = "SIGINT";
        TasksMax = 4096;
        StateDirectory = subdir;
        WorkingDirectory = "/var/lib/${subdir}";
      }
      // gpuServiceConfig
      // ncclServiceConfig
      // serviceConfig;
    };

  # The flags a native workload's server receives, the host-side twin of the
  # `Exec` that `mkQuadletWorkloadContainer` renders.
  nativeWorkloadArgs =
    {
      backend,
      unit,
      workload,
      managed,
      settings,
    }:
    renderCliArgs backend (workloadFlags {
      inherit
        backend
        managed
        workload
        settings
        ;
      directory = systemdCredentialDirectory unit;
      listen = hostListen workload;
    });

  # Shared body of `systemd.mkServices`/`mkUvServices`. `wrap` layers a backend
  # flavour (currently `withUv`) onto every worker's args and `previous`
  # resolves the startup chain, or stays null for a backend that does not chain.
  #
  # `command` builds the argv preceding the flags, executable included, and
  # `settings` the backend's own managed flags from a model, as `arguments`
  # and `settings` do for `quadlet.mkModelContainers`.
  mkModelServices =
    {
      serviceName,
      cfg,
      pkgs,
      utils,
      command,
      settings,
      models,
      previous ? (_index: null),
      wrap ? lib.id,
      environment ? (_cacheBase: { }),
      serviceConfig ? { },
    }:
    lib.listToAttrs (
      lib.imap0 (
        index: model:
        mkNativeModelService (wrap {
          inherit
            serviceName
            cfg
            pkgs
            utils
            model
            environment
            serviceConfig
            ;
          previous = previous index;
          execStart =
            command model
            ++ nativeWorkloadArgs {
              backend = serviceName;
              unit = workloadUnit serviceName model;
              workload = model;
              managed = settings model;
              settings = cfg.modelSettings // model.settings;
            };
        })
      ) models
    );

  # The `PATH` and environment a backend built from Python wheels
  # needs, layered onto any `mkNativeService`/`mkNativeModelService` arguments.
  # See the module internals documentation for what each entry is for.
  withUv =
    args@{
      pkgs,
      environment ? (_cacheBase: { }),
      ...
    }:
    args
    // {
      path = with pkgs; [
        stdenv.cc
        ninja
        bash
      ];
      environment =
        cacheBase:
        {
          HOME = cacheBase;
          HF_HOME = cacheBase;
          HF_HUB_CACHE = "${cacheBase}/hub";
          XDG_CACHE_HOME = cacheBase;
          LD_LIBRARY_PATH = "/run/opengl-driver/lib";
          TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
        }
        // environment cacheBase;
    };
in
{
  inherit
    baseWorkloadOptions
    containerRuntimeDirectory
    credentialDirectory
    credentialsOption
    enabled
    identityConfig
    identityServiceConfig
    staticIdentityOptions
    mergeCredentialServiceConfig
    modelLabel
    nativeWorkloadArgs
    quadletServiceName
    socketCapable
    containerListen
    hostListen
    hostPort
    listenerOptions
    renderCliArgs
    renderCliArgsShell
    resolveCredentialRefs
    resolveSettings
    serviceConfigOption
    settingsRendering
    sortedModels
    systemdCredentialDirectory
    unitConfigOption
    workerUrl
    workloadFlags
    workloadUnit
    ;

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

  # ─── Quadlet (container-based) ───────────────────────────────────────

  quadlet = {
    mkObjectOptions = mkQuadletObjectOptions;
    mkImageArgs = mkQuadletImageArgs;
    mkWorker = mkQuadletWorker;
    mkWorkloadContainer = mkQuadletWorkloadContainer;
    mkImageOptions = mkQuadletImageOptions;

    # Top-level options for a quadlet-based backend. Spread under
    # `options.services.llmhop.<backend>` via `//`; the caller adds `enable`,
    # `models`, and any backend-specific extras (gateway sub-options, etc.).
    # `cfg` (the corresponding `config.services.llmhop.<backend>`) is passed
    # in so the GID-side options can lazily default to their UID counterparts;
    # `config` (the top-level NixOS config) is read so `devices` can derive
    # its default from `hardware.nvidia-container-toolkit.enable`.
    mkOptions =
      {
        backend,
        cfg,
        config,
        defaultImage,
        defaultCacheDir,
        defaultContainerCacheDir ? "/root/.cache/huggingface",
        defaultCacheEnvVar ? "HF_HOME",
        tagExample ? "latest",
      }:
      let
        serviceName = quadletServiceName backend;
        userType = types.submodule (
          { config, ... }:
          {
            options = {
              manage = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Whether llmhop creates and configures this account. Disable
                  this for an account managed elsewhere, including its home,
                  linger setting, group, and subordinate ID ranges.
                '';
              };
              name = mkOption {
                type = types.str;
                default = serviceName;
                description = "Host account whose systemd user manager owns the Quadlets.";
              };
              uid = mkOption {
                type = types.ints.positive;
                example = 503;
                description = "UID of the systemd user manager that owns the Quadlets.";
              };
              group = mkOption {
                type = types.str;
                default = config.name;
                defaultText = lib.literalExpression "config.name";
                description = "Primary group of the managed account.";
              };
              gid = mkOption {
                type = types.ints.positive;
                default = config.uid;
                defaultText = lib.literalExpression "config.uid";
                description = "GID of the managed account's primary group.";
              };
              home = mkOption {
                type = types.path;
                default = "/var/lib/${serviceName}";
                description = ''
                  Home directory used for rootless Podman storage. This must
                  live on a filesystem that supports the selected storage driver.
                '';
              };
            };
          }
        );
      in
      (baseOptions { inherit backend; })
      // {
        image = mkOption {
          type = types.str;
          default = defaultImage;
          description = "Container image used for every model worker.";
        };
        tag = mkOption {
          type = types.str;
          example = tagExample;
          description = ''
            Default tag of the container image used for models that do not set their own
            `tag` or `digest`.
          '';
        };
        # Mounts are per container: the global layer would apply a mapping to
        # containers that do not share the same `User=`.
        quadlet =
          removeAttrs (mkQuadletObjectOptions {
            description = "every generated container";
          }) [ "mountOptions" ]
          // {
            user = mkOption {
              type = types.nullOr userType;
              default = null;
              description = ''
                Host account whose systemd user manager owns these Quadlets.
                `null` installs system units and runs Podman rootfully. An
                attribute set installs user units for its `uid` and runs Podman
                rootlessly. This is independent of `[Container] User=` and the
                container's user namespace configuration.

                A managed account gets NixOS-allocated subordinate ID ranges.
                Set `users.users.<name>.subUidRanges` and `subGidRanges` (with
                `autoSubUidGidRange = false`) to pick them yourself.
              '';
            };
          };
        cache = {
          directory = mkOption {
            type = types.path;
            default = defaultCacheDir;
            description = "Host directory bind-mounted as the Hugging Face cache.";
          };
          containerDirectory = mkOption {
            type = types.str;
            default = defaultContainerCacheDir;
            description = "Path at which the cache is mounted inside every model container.";
          };
          environmentVariable = mkOption {
            type = types.str;
            default = defaultCacheEnvVar;
            description = ''
              Environment variable set on every container to point its runtime
              at `containerDirectory`.
            '';
          };
          mountOptions = mkOption {
            type = with types; listOf str;
            default = [ ];
            example = [ "idmap" ];
            description = ''
              Options appended to the cache's Quadlet `Volume=` entry. This can
              be used for Podman ownership mechanisms such as `U`, `idmap`, or
              SELinux relabeling.
            '';
          };
          manage = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether llmhop creates the host cache directory with
              systemd-tmpfiles, owned by `user`/`group` and mode `0700`.
            '';
          };
          user = mkOption {
            type = types.str;
            default = if cfg.quadlet.user == null then "root" else cfg.quadlet.user.name;
            defaultText = lib.literalExpression ''
              if config.services.llmhop.${backend}.quadlet.user == null then
                "root"
              else
                config.services.llmhop.${backend}.quadlet.user.name
            '';
            description = ''
              Host owner used when `cache.manage` is enabled. Override it when a
              `UIDMap`/`idmap` mapping makes the container see a different owner
              than the host account running Podman.
            '';
          };
          group = mkOption {
            type = types.str;
            default = if cfg.quadlet.user == null then "root" else cfg.quadlet.user.group;
            defaultText = lib.literalExpression ''
              if config.services.llmhop.${backend}.quadlet.user == null then
                "root"
              else
                config.services.llmhop.${backend}.quadlet.user.group
            '';
            description = "Host group used when `cache.manage` is enabled.";
          };
        };
        startupOrdering = startupOrderingOption { pinNote = "via its own `devices`"; };
        devices = mkOption {
          type = with types; listOf str;
          default =
            if config.hardware.nvidia-container-toolkit.enable or false then [ "nvidia.com/gpu=all" ] else [ ];
          defaultText = lib.literalExpression ''
            if config.hardware.nvidia-container-toolkit.enable then
              [ "nvidia.com/gpu=all" ]
            else
              [ ]
          '';
          example = [ "amd.com/gpu=all" ];
          description = ''
            Devices exposed to every model container — passed verbatim as Quadlet
            `AddDevice=` lines. Accepts both CDI references (recommended:
            `nvidia.com/gpu=…`, `amd.com/gpu=…`, `intel.com/gpu=…`, ...) and raw
            host device paths (e.g. `/dev/dri/renderD128`). For CDI, the
            corresponding spec must be generated on the host (e.g.
            `nvidia-ctk cdi generate`).
            Defaults to `[ "nvidia.com/gpu=all" ]` when
            `hardware.nvidia-container-toolkit.enable` is set, otherwise empty
            (CPU-only). Per-model `devices` overrides this.
          '';
        };
      };

    # Per-model submodule for a quadlet-based backend. `cfg` (the top-level
    # backend config) is passed so `devices` can lazily default to the
    # backend-wide value.
    mkModelSubmodule =
      {
        backend,
        cfg,
        socketDirectory ? null,
        portDescription,
        hasModel ? true,
      }:
      let
        serviceName = quadletServiceName backend;
      in
      { name, config, ... }:
      {
        options =
          (baseModelOptions {
            inherit
              backend
              serviceName
              name
              socketDirectory
              portDescription
              ;
            workload = config;
          })
          // mkQuadletImageOptions { noun = "model"; }
          // {
            devices = mkOption {
              type = with types; listOf str;
              default = cfg.devices;
              defaultText = lib.literalExpression "config.services.llmhop.${backend}.devices";
              example = [ "nvidia.com/gpu=0" ];
              description = ''
                Devices exposed to this model's container — passed verbatim as
                Quadlet `AddDevice=` lines. Replaces (does not extend)
                `services.llmhop.${backend}.devices` for this model.
                Use to pin a model to specific device indices
                (e.g. `[ "nvidia.com/gpu=0" ]`).
              '';
            };
            shmSize = mkOption {
              type = types.str;
              default = "32g";
              example = "64g";
              description = ''
                Size of the container's private `/dev/shm` tmpfs.
                PyTorch and friends use shared memory for NCCL/tensor-parallel inference;
                upstream recommends 32g (or `--ipc=host`). A private tmpfs is preferred for
                isolation: raise the value for larger models or higher tensor-parallel sizes.
              '';
            };
            quadlet = mkQuadletObjectOptions {
              description = "this model container";
              socket = socketCapable backend;
            };
          }
          // lib.optionalAttrs hasModel {
            model = mkOption {
              type = types.str;
              example = "Qwen/Qwen2.5-7B-Instruct";
              description = "Hugging Face repo id (or local path) passed to the model server.";
            };
          };
      };

    # Every enabled model of a quadlet backend as one
    # `virtualisation.quadlet.containers` attrset: sorted by ascending `name`,
    # each published on loopback or bound to its socket, chained on its
    # predecessor, and with every `${cred:…}` in its settings already resolved.
    #
    # `settings` builds the backend's base flags from a model, `arguments` the
    # positional argv preceding them, and `containerConfig` carries static
    # `[Container]` extras such as `Entrypoint`. The listener flags are derived
    # here from `port`, `socket` and `workerPort`, the container-side port.
    mkModelContainers =
      {
        backend,
        cfg,
        config,
        workerPort,
        settings,
        arguments ? (_model: [ ]),
        containerConfig ? { },
      }:
      let
        serviceName = quadletServiceName backend;
        models = sortedModels cfg;
      in
      lib.listToAttrs (
        lib.imap0 (
          index: model:
          lib.nameValuePair (workloadUnit serviceName model) (mkQuadletWorkloadContainer {
            inherit backend cfg config;
            collection = "models";
            workload = model;
            containerPort = workerPort;
            managed = settings model;
            settings = cfg.modelSettings // model.settings;
            arguments = arguments model;
            containerConfig = {
              AddDevice = model.devices;
              ShmSize = model.shmSize;
              Ulimit = "host";
            }
            // containerConfig;
            # Each container waits on its predecessor so GPU-memory profiling
            # never overlaps.
            unitConfig.After =
              lib.optional (cfg.startupOrdering && index > 0)
                "${
                  config.virtualisation.quadlet.containers.${
                    workloadUnit serviceName (lib.elemAt models (index - 1))
                  }.serviceName
                }.service";
          })
        ) models
      );

    # Cross-cutting NixOS config produced by every quadlet backend:
    # the quadlet-enabled assertion, llmhop registration, resource registries,
    # cache and socket directories, and the optional rootless account.
    #
    # `auxiliaries` describes the non-model services this backend runs; see
    # `mkSharedConfig`.
    mkConfig =
      {
        backend,
        cfg,
        config,
        auxiliaries ? { },
      }:
      let
        serviceName = quadletServiceName backend;
        user = cfg.quadlet.user;
        sockets = socketWorkloads cfg auxiliaries;
      in
      lib.mkMerge [
        (mkSharedConfig {
          inherit
            backend
            serviceName
            cfg
            auxiliaries
            ;
        })
        {
          assertions = [
            {
              assertion = config.virtualisation.quadlet.enable;
              message = "services.llmhop.${backend} requires virtualisation.quadlet.enable.";
            }
            {
              # The unit registry only catches twins that also share a model
              # name. They collide at the backend level regardless: both emit
              # `${serviceName}-<model>` units and both own
              # `${cfg.cache.directory}`, which this backend hands to its own
              # (possibly root-owned) account with mode 0700.
              assertion = !config.services.llmhop.${serviceName}.enable;
              message = "services.llmhop.${backend} and services.llmhop.${serviceName} are mutually exclusive: they emit the same `${serviceName}-<model>` unit names and share the `${serviceName}` cache directory.";
            }
          ];

          systemd.tmpfiles.settings."10-${serviceName}" =
            lib.optionalAttrs cfg.cache.manage {
              ${cfg.cache.directory}.d = {
                inherit (cfg.cache) user group;
                mode = "0700";
              };
            }
            # Rootless socket directories of every workload, see
            # `mkQuadletWorker`.
            // lib.optionalAttrs (user != null) (
              lib.listToAttrs (
                map (
                  w:
                  lib.nameValuePair (dirOf w.socket) {
                    d = {
                      inherit (user) group;
                      user = user.name;
                      mode = socketDirectoryMode;
                    };
                  }
                ) sockets
              )
            );

          # A container maps to no host group known in advance, so its socket
          # is reachable through a default ACL on the root instead. See "Unix
          # sockets" in the module internals documentation.
          systemd.tmpfiles.settings."10-llmhop" = lib.mkIf (sockets != [ ]) {
            ${config.services.llmhop.socketDirectory}.a.argument =
              "default:user:${config.services.llmhop.user}:-wx";
          };
        }
        (lib.mkIf (user != null && user.manage) {
          users.users.${user.name} = {
            description = "${serviceName} container service user";
            inherit (user) uid group home;
            isSystemUser = true;
            createHome = true;
            linger = true;
            # Rootless Podman needs subordinate IDs; `mkDefault` leaves the
            # native `users.users.<name>.subUidRanges` route open.
            autoSubUidGidRange = lib.mkDefault true;
          };
          users.groups.${user.group}.gid = user.gid;
        })
      ];
  };

  # ─── Systemd (host-process) ──────────────────────────────────────────

  systemd = {
    inherit
      hardenedServiceConfig
      sharedUnitConfig
      ;

    # A single auxiliary unit of a from-wheel Python backend, for workloads
    # that are not model workers.
    mkUvService = args: mkNativeService (withUv args);

    # Top-level options for a systemd-service backend running as a
    # `DynamicUser` by default.
    mkOptions =
      { backend }: baseOptions { inherit backend; } // dynamicIdentityOptions { name = backend; };

    # Options for a uv/wheel-based GPU Python backend (vLLM, SGLang): the
    # shared base plus the service identity, the `startupOrdering` switch and
    # the required, no-default `package` templated per backend. Parallels
    # `quadlet.mkOptions` bundling its consumer-specific options; the module
    # adds only `enable` and `models`. `displayName`/`packageEntry` fill the
    # prose and `packageNote` appends an optional trailing paragraph.
    mkUvOptions =
      {
        backend,
        cfg,
        displayName,
        packageEntry,
        packageNote ? "",
      }:
      baseOptions { inherit backend; }
      // staticIdentityOptions {
        inherit cfg;
        name = backend;
        prefix = "services.llmhop.${backend}";
      }
      // {
        startupOrdering = startupOrderingOption {
          pinNote = "via `environment` (the variable is stack-specific: `CUDA_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES`, `ZE_AFFINITY_MASK`, ...)";
        };
        package = mkOption {
          type = types.package;
          description = ''
            Package providing ${packageEntry}.

            No default on purpose: ${displayName} has no one-derivation-fits-all
            (new model architectures routinely need dev snapshots, and the wheels
            come in per-accelerator variants), so you build the package from a uv
            workspace and pin / follow upstream there. The flake exposes a
            helper:

            ```nix
            inputs.llmhop.legacyPackages.''${pkgs.system}.mkUvEnv {
              workspaceRoot = ./${backend}-env; # your pyproject.toml + uv.lock
            }
            ```

            Individual models may override this with `models.<name>.package`.
          ''
          + packageNote;
          example = lib.literalExpression ''
            inputs.llmhop.legacyPackages.''${pkgs.system}.mkUvEnv {
              workspaceRoot = ./${backend}-env;
            }
          '';
        };
      };

    # Per-model submodule for a systemd-service backend.
    mkModelSubmodule =
      {
        backend,
        socketDirectory ? null,
        portDescription,
      }:
      { name, config, ... }:
      {
        options =
          baseModelOptions {
            inherit
              backend
              name
              socketDirectory
              portDescription
              ;
            workload = config;
          }
          // {
            serviceConfig = serviceConfigOption { serviceName = backend; };
            unitConfig = unitConfigOption { serviceName = backend; };
          };
      };

    # Per-model submodule for a uv/wheel-based GPU Python backend: the shared
    # base plus the `model` repo id (`modelArgument` names the CLI argument it
    # is passed as), and a per-model `package` override that defaults to the
    # backend-wide `package`. The override lets a single model pin a different
    # release (e.g. a nightly wheel for a just-released architecture) without
    # disturbing the others. `cfg` is the backend config, read for that default.
    mkUvModelSubmodule =
      {
        backend,
        cfg,
        socketDirectory ? null,
        modelArgument,
        modelExample,
      }:
      { name, config, ... }:
      {
        options =
          baseModelOptions {
            inherit backend name socketDirectory;
            workload = config;
            portDescription = ''
              Loopback host port ${backend} binds to (`--host 127.0.0.1 --port <port>`).
              Must be unique per enabled model; llmhop reaches the backend at
              `http://127.0.0.1:<port>`.
            '';
          }
          // {
            model = mkOption {
              type = types.str;
              example = modelExample;
              description = "Hugging Face repo id (or local path) passed as ${modelArgument}.";
            };
            package = mkOption {
              type = types.package;
              default = cfg.package;
              defaultText = lib.literalExpression "config.services.llmhop.${backend}.package";
              description = ''
                Package providing this model's worker, overriding the backend-wide
                `package`. Set it for a model that needs a different ${backend}
                release than the rest — e.g. a nightly wheel for a just-released
                architecture — built the same way with `mkUvEnv` over a per-model
                uv workspace. Defaults to the backend-wide `package`.
              '';
            };
            serviceConfig = serviceConfigOption { serviceName = backend; };
            unitConfig = unitConfigOption { serviceName = backend; };
          };
      };

    # One unit per enabled model. Owning the unit name also lets this own the
    # credential directory derived from it, so every `${cred:…}` is resolved
    # here and backends never spell a credential path themselves.
    mkServices = args: mkModelServices (args // { models = lib.attrValues (enabledModels args.cfg); });

    # `mkServices` for a from-wheel Python backend: the uv environment, and
    # workers emitted and chained by ascending `name`.
    mkUvServices =
      args:
      let
        models = sortedModels args.cfg;
      in
      mkModelServices (
        args
        // {
          inherit models;
          wrap = withUv;
          previous =
            index: if args.cfg.startupOrdering && index > 0 then lib.elemAt models (index - 1) else null;
          # These frameworks trap SIGINT to drain the engine and then exit 0, so
          # `on-failure` would leave a crashed worker dead.
          serviceConfig = {
            Restart = "always";
          }
          // args.serviceConfig or { };
        }
      );

    # Cross-cutting NixOS config produced by a systemd backend: registry
    # entries, socket directories and llmhop registration. llmhop also joins
    # `group`, which owns the worker sockets.
    # Units are named after the backend itself, and run as its identity.
    mkConfig =
      {
        backend,
        cfg,
        auxiliaries ? { },
      }:
      lib.mkMerge [
        (mkSharedConfig {
          inherit
            backend
            cfg
            auxiliaries
            ;
          serviceName = backend;
        })
        (identityConfig {
          inherit cfg;
          name = backend;
        })
        { services.llmhop.supplementaryGroups = [ cfg.group ]; }
      ];
  };
}
