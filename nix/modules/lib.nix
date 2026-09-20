lib:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;

  # ─── Shared building blocks (private) ────────────────────────────────

  # Permissive label for unit and routing-key names. Allows dots so
  # `qwen3.6-…`-style version suffixes work.
  modelLabel = types.strMatching "[[:alnum:]][[:alnum:].-]*";

  credentialNamePattern = "[[:alnum:]_][[:alnum:]_.-]*";
  credentialReferencePrefix = "\${cred:";
  credentialDirectory = "/run/llmhop/credentials";

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

  credentialsOption = mkOption {
    type = types.attrsOf credentialType;
    default = { };
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
    name: value:
    if builtins.match credentialNamePattern name == null then
      throw "invalid systemd credential name `${name}`"
    else if value ? source then
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
      normalized = lib.mapAttrs normalizeCredential credentials;
      render =
        encrypted:
        lib.mapAttrsToList (name: value: "${name}:${toString value.source}") (
          lib.filterAttrs (_: value: value.encrypted == encrypted) normalized
        );
      append = key: entries: lib.toList (serviceConfig.${key} or [ ]) ++ entries;
    in
    serviceConfig
    // lib.optionalAttrs (credentials != { }) {
      LoadCredential = append "LoadCredential" (render false);
      LoadCredentialEncrypted = append "LoadCredentialEncrypted" (render true);
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
        if builtins.isString value then
          let
            resolved = lib.replaceStrings references paths value;
          in
          if lib.hasInfix credentialReferencePrefix resolved then
            throw "unknown credential reference in `${value}`"
          else
            resolved
        else if builtins.isList value then
          map resolve value
        else if builtins.isAttrs value && !lib.isDerivation value then
          lib.mapAttrs (_: resolve) value
        else
          value;
    in
    resolve;

  systemdCredentialDirectory = unit: "/run/credentials/${unit}.service";

  # ─── CLI rendering (private) ─────────────────────────────────────────

  # How each backend's parser reads the two `settings` shapes that have no
  # portable rendering. Keyed by the unsuffixed service name, so a native
  # backend and its quadlet twin share one entry.
  #
  # `negateBools`: the parser registers a `--no-<key>` twin for every boolean
  # (argparse `BooleanOptionalAction`, llama.cpp's paired flags). SGLang
  # instead pairs `--enable-X` with `--disable-X` and rejects `--no-X`.
  #
  # `listStyle`: `"values"` hands every element to one flag (`--key a b`), what
  # argparse `nargs` and clap multi-value options take. `"repeat"` emits the
  # flag once per element (`--key a --key b`), all that llama.cpp's hand-rolled
  # parser understands (it also takes only `--key value`, never `--key=value`).
  # Both argparse backends register a few options in the other style, so this
  # is the dominant form for a backend rather than a guarantee for every flag.
  #
  # `lib.cli.toCommandLine` renders neither axis: its `optionFormat` never sees
  # the value, and list handling is hardcoded to repeat-style. The `mkBool` and
  # `mkList` hooks of `lib.cli.toGNUCommandLine` could, but it is deprecated as
  # of nixpkgs 25.11 and warns on every evaluation.
  cliDialects = {
    llama-cpp = {
      negateBools = true;
      listStyle = "repeat";
    };
    vllm = {
      negateBools = true;
      listStyle = "values";
    };
    sglang = {
      negateBools = false;
      listStyle = "values";
    };
  };

  cliDialect = backend: cliDialects.${quadletServiceName backend};

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

  # Settings values are Nix-typed, so each shape is rendered the way the
  # parsers read it: strings, paths and derivations verbatim, everything else
  # through JSON. That keeps `0.6` from becoming `0.600000` (what `toString`
  # makes of a float) and turns an attribute set into the JSON object that
  # options like vLLM's `--speculative-config` parse.
  cliValue = value: if lib.isStringLike value then toString value else builtins.toJSON value;

  # Prose shared by `modelSettings` and `settings`, phrased for the dialect the
  # backend's parser speaks.
  settingsRendering =
    backend:
    let
      dialect = cliDialect backend;
    in
    ''
      `true` collapses to `--<key>`, `null` and empty lists are dropped, and an
      attribute set is serialised to JSON.
      ${
        if dialect.negateBools then
          "`false` renders as `--no-<key>`, so a flag with no negated twin (an on-only one, or a tri-state one taking `on|off|auto`) has to be omitted or given its value explicitly rather than set to `false`."
        else
          "`false` is dropped, since the CLI pairs `--enable-X` with `--disable-X` instead of auto-negating: write the negated key explicitly, e.g. `disable-radix-cache = true;`."
      }
      ${
        if dialect.listStyle == "values" then
          "A list hands every element to a single flag (`--<key> a b`), which is what most multi-value options of this CLI take. The few that instead expect a repeated flag have to be written out one value at a time."
        else
          "A list repeats the flag once per element (`--<key> a --<key> b`)."
      }
    '';

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

  # Identity of a native backend whose directories outlive any single service
  # start, so their ownership has to be pinned rather than left to systemd.
  # The group side lazily defaults to its user counterpart, which is why `cfg`
  # is passed in.
  identityOptions =
    {
      backend,
      cfg,
    }:
    let
      serviceName = quadletServiceName backend;
    in
    {
      user = mkOption {
        type = types.str;
        default = serviceName;
        description = ''
          Dedicated system user owning the ${serviceName} data and cache
          directories. Defaults to the backend name; override to point at a
          user the deployer manages externally (in which case the matching
          `users.users.<name>` and `users.groups.<name>` declarations become the
          deployer's responsibility).
        '';
      };
      uid = mkOption {
        type = types.ints.unsigned;
        example = 503;
        description = ''
          Host UID assigned to `services.llmhop.${backend}.user`.
          Required — pick a value that does not clash with other system users on the
          host.
        '';
      };
      group = mkOption {
        type = types.str;
        default = cfg.user;
        defaultText = lib.literalExpression "config.services.llmhop.${backend}.user";
        description = ''
          Primary group for `services.llmhop.${backend}.user`.
          Defaults to the user name (matching the typical 1:1 user/group layout).
        '';
      };
      gid = mkOption {
        type = types.ints.unsigned;
        default = cfg.uid;
        defaultText = lib.literalExpression "config.services.llmhop.${backend}.uid";
        description = ''
          Host GID assigned to `services.llmhop.${backend}.group`.
          Defaults to `uid`.
        '';
      };
    };

  # Config-side twin of `identityOptions`: the system user and group the
  # backend's units run as. Declared only while `user` is still llmhop's own
  # default — pointing it at an externally managed account makes the matching
  # declarations the deployer's responsibility. `userExtra` carries the
  # rootless-session attributes only quadlet needs.
  identityConfig =
    {
      backend,
      cfg,
      userExtra ? { },
    }:
    let
      serviceName = quadletServiceName backend;
    in
    lib.mkIf (cfg.user == serviceName) {
      users.users.${cfg.user} = {
        description = "${serviceName} service user";
        uid = cfg.uid;
        isSystemUser = true;
        group = cfg.group;
      }
      // userExtra;
      users.groups.${cfg.group}.gid = cfg.gid;
    };

  # Ascending-port startup chaining, shared by every multi-worker GPU backend.
  # `pinNote` names the backend-specific way to pin a model to one device.
  startupOrderingOption =
    { pinNote }:
    mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to chain enabled model services by ascending `port` during startup.
        GPU-memory profiling races otherwise: two workers booting on the same device
        each see it as fully free and race to claim their share, leading to OOM.
        Disable only when each model pins itself to a dedicated device ${pinNote}.
      '';
    };

  # Per-model options every backend exposes, regardless of kind. `backend` is
  # the (possibly suffixed) option namespace used in cross-references;
  # `serviceName` is the unsuffixed prefix of the generated unit names.
  baseModelOptions =
    {
      backend,
      serviceName ? backend,
      name,
    }:
    {
      enable = mkEnableOption "serving of model ${name}" // {
        default = true;
      };
      name = mkOption {
        type = modelLabel;
        default = name;
        description = ''
          Canonical identifier for this model. Used for the unit name
          (`${serviceName}-<name>`) and as the routing key registered with llmhop
          (clients select the backend by sending this value in the OpenAI
          `model` field).

          Defaults to the attribute key, so the key itself must match the
          required label format.
        '';
      };
      settings = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          CLI flags forwarded to the model server for this model.
          ${settingsRendering backend}
          Merged with `services.llmhop.${backend}.modelSettings`; per-model entries
          take precedence.
        '';
      };
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Additional environment variables set on this model's service.
          Merged with `services.llmhop.${backend}.environment`; per-model entries
          take precedence.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          File in `KEY=VALUE` format forwarded to this model's service.
          Loaded after `services.llmhop.${backend}.environmentFile`, so its entries
          override global ones. Use `credentials` for file-capable secret
          settings. Must be readable by the user systemd reads it as.
        '';
      };
      credentials = credentialsOption;
    };

  vllmDetectorOptions = name: {
    enable = mkEnableOption "watermark detector ${name}" // {
      default = true;
    };
    name = mkOption {
      type = modelLabel;
      default = name;
      description = "Name used for the `vllm-detector-<name>` systemd unit.";
    };
    tokenizer = mkOption {
      type = types.str;
      example = "Qwen/Qwen3-8B";
      description = ''
        Tokenizer used to encode candidate text. It must exactly match the
        tokenizer used for watermarked generation.
      '';
    };
    port = mkOption {
      type = types.port;
      description = "Loopback port on which the upstream detector serves `/detect`.";
    };
    settings = mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        key = 42;
        context-width = 4;
      };
      description = ''
        Arguments passed to vLLM's upstream watermark detector server.
        Its current interface supports `key`, `prf`, `context-width`, and
        `p-value-threshold`.
        ${settingsRendering "vllm"}
      '';
    };
    environment = mkOption {
      type = with types; attrsOf str;
      default = { };
      description = "Additional environment variables for this detector.";
    };
    environmentFile = mkOption {
      type = with types; nullOr path;
      default = null;
      description = "Additional environment file for this detector.";
    };
    credentials = credentialsOption;
  };

  vllmDetectorUnit = detector: "vllm-detector-${detector.name}";

  # Base CLI settings every detector shares; `host` differs because the
  # container publishes its port instead of binding loopback directly.
  vllmDetectorSettings =
    host: port: detector:
    {
      inherit (detector) tokenizer;
      inherit host port;
    }
    // detector.settings;

  # Registry entries folded into `mkConfig` so detector ports and unit names
  # take part in the global uniqueness checks alongside models.
  vllmDetectorRegistry = detectors: {
    extras = lib.mapAttrs' (
      name: detector: lib.nameValuePair "detectors.${name}" detector.port
    ) detectors;
    extraUnits = lib.mapAttrs' (
      name: detector: lib.nameValuePair "detectors.${name}" (vllmDetectorUnit detector)
    ) detectors;
  };

  # Defaults applied to every worker, scoped by the systemd unit-file section
  # they belong to. Worker helpers merge these into the corresponding *Config
  # attribute before layering caller overrides on top.

  # `[Unit]` defaults: hard-fail after 3 errors/hour so journald surfaces the
  # underlying error instead of an endless restart loop.
  sharedUnitConfig = {
    StartLimitBurst = 3;
    StartLimitIntervalSec = 3600;
  };

  # `[Service]` defaults: hour-long `TimeoutStartSec` covers cold-start model
  # downloads + GPU memory profiling; `RestartSec = 30` debounces crash loops.
  sharedServiceConfig = {
    TimeoutStartSec = 3600;
    RestartSec = 30;
  };

  # Universal systemd-exec(5) hardening shared between the llmhop reverse
  # proxy and the systemd-managed model workers (llama.cpp). Quadlet workers
  # skip this layer — podman handles isolation at the container level.
  # `SocketBind*` is intentionally NOT set here: it's paired with a per-unit
  # `SocketBindAllow` that only worker units declare (via `mkWorker`).
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
  # inference, layered on top of the hardened baseline. `getifaddrs()` opens an
  # AF_NETLINK socket during its interface scan, so that family is re-added.
  # The bootstrap/proxy/RAS listeners bind ephemeral (port 0) TCP sockets, which
  # `SocketBindDeny = "any"` refuses. The bind hook only ever sees port 0, never
  # the assigned port, so allow-all-TCP is the tightest workable rule, and it
  # already covers the worker's own listener. UDP stays denied.
  ncclServiceConfig = {
    RestrictAddressFamilies = hardenedServiceConfig.RestrictAddressFamilies ++ [ "AF_NETLINK" ];
    SocketBindAllow = "tcp";
  };

  # NCCL defaults for single-host workers: keep the transport on loopback and
  # off any InfiniBand fabric (there is none on a single node). Applied as
  # environment defaults, so a deployer can still override them per model.
  # RCCL is an API clone of NCCL and reads the same variables, so this covers
  # AMD as well; oneCCL (Intel) uses `CCL_*` and simply ignores them.
  ncclEnvironment = {
    NCCL_SOCKET_IFNAME = "lo";
    NCCL_IB_DISABLE = "1";
  };

  # Relaxations a GPU worker needs on top of the hardened baseline, named for
  # the same reason `ncclServiceConfig` is: so "what does a GPU worker give up,
  # and why" has one place to read rather than accreting inline.
  gpuServiceConfig = {
    # GPU acceleration needs raw device access (`/dev/nvidia*` for CUDA,
    # `/dev/kfd` + `/dev/dri/renderD*` for ROCm and Level Zero); the upstream
    # NVIDIA NixOS modules disable PrivateDevices for this.
    PrivateDevices = false;

    # `/dev/nvidia*` is world-readable, but systemd's default udev rules leave
    # the AMD and Intel nodes group-owned, so a worker running as a real user
    # (or a `DynamicUser`) cannot open them without joining those groups.
    SupplementaryGroups = [
      "render"
      "video"
    ];

    # Those groups only mean anything if their GIDs survive into the worker's
    # user namespace, and the baseline's `PrivateUsers = true` maps everything
    # but the unit's own identity to `nobody`. `identity` keeps the namespace
    # but maps the first 65536 IDs one-to-one, so the check resolves normally.
    PrivateUsers = "identity";

    # Runtime kernel compilation mmaps PROT_WRITE|PROT_EXEC pages: torch-inductor
    # and triton, the CUDA driver's PTX→SASS pass, and the SPIR-V JIT behind
    # SYCL and Level Zero all do it.
    MemoryDenyWriteExecute = false;

    # Page-locked memory draws from RLIMIT_MEMLOCK, which systemd otherwise caps
    # at its 8 MiB default: every stack pins the host side of its device buffers
    # (CUDA, and the ROCm KFD the same way), and llama.cpp's `--mlock` pins the
    # weights outright. Too low a limit reports OOM despite free VRAM.
    LimitMEMLOCK = "infinity";

    # The baseline's `ProcSubset = "pid"` hides everything in /proc that is not
    # a process directory. psutil, torch and NUMA discovery all read
    # /proc/meminfo and /proc/cpuinfo, so the engine dies on a missing
    # /proc/meminfo before it reaches the GPU. `ProtectProc` still keeps other
    # users' process directories invisible.
    ProcSubset = "all";
  };

  # Where a GPU worker's runtime caches go. Every accelerator stack compiles
  # kernels on first use and caches them next to `$HOME`, which `ProtectSystem =
  # "strict"` makes read-only, so each one is redirected into the unit's own
  # cache root — the single place `systemctl clean` can reach. All of them are
  # set unconditionally: a variable belonging to a stack that is not installed
  # is never read, which is cheaper than tracking which host has which vendor.
  gpuCacheEnvironment = cacheBase: {
    TRITON_CACHE_DIR = "${cacheBase}/triton";
    TORCHINDUCTOR_CACHE_DIR = "${cacheBase}/inductor";
    # MIOpen (ROCm) needs both: its kernel database and its compiled-kernel
    # cache otherwise land under separate `$HOME` roots.
    MIOPEN_USER_DB_PATH = "${cacheBase}/miopen";
    MIOPEN_CUSTOM_CACHE_DIR = "${cacheBase}/miopen";
    # SYCL and the Intel compute runtime (NEO) only cache their SPIR-V → ISA
    # compilation when asked to, which is what turns a multi-minute JIT into a
    # one-time cost across restarts.
    SYCL_CACHE_PERSISTENT = "1";
    SYCL_CACHE_DIR = "${cacheBase}/sycl";
    NEO_CACHE_PERSISTENT = "1";
    NEO_CACHE_DIR = "${cacheBase}/neo";
  };

  # Enabled subset of any `attrsOf { enable; ... }` workload collection.
  enabled = lib.filterAttrs (_: w: w.enable);

  # Enabled-model subset shared by registry helpers and backend iteration.
  enabledModels = cfg: enabled cfg.models;

  # Enabled models sorted by ascending `port`. Quadlet backends use this for
  # both unit-emission order and the deterministic `After=` startup chain.
  sortedModels =
    cfg:
    lib.pipe (enabledModels cfg) [
      lib.attrValues
      (lib.sort (a: b: a.port < b.port))
    ];

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

  # Cross-cutting NixOS fragment every backend emits: llmhop model, ports- and
  # units-registry contributions. Backend extras layer on via `lib.mkMerge`.
  #
  # Both registries are keyed by the option path that owns the entry —
  # `<backend>.models.<name>` for models, `<backend>.<extraLabel>` for
  # auxiliaries (gateways, metrics endpoints) — so the global collision
  # assertions in `core.nix` name the exact options to change, and a model
  # named after an auxiliary still gets its own entry. `serviceName` is the
  # prefix of the emitted unit names, which is why two backends sharing one
  # (a native/quadlet pair) collide.
  mkSharedConfig =
    {
      backend,
      serviceName,
      cfg,
      extras ? { },
      extraUnits ? { },
    }:
    let
      models = enabledModels cfg;
      mkRegistry =
        modelValue: extraValues:
        lib.mapAttrs' (name: m: lib.nameValuePair "${backend}.models.${name}" (modelValue m)) models
        // lib.mapAttrs' (label: lib.nameValuePair "${backend}.${label}") extraValues;
      portsRegistry = mkRegistry (m: m.port) extras;
      unitsRegistry = mkRegistry (m: "${serviceName}-${m.name}") extraUnits;
    in
    {
      services.llmhop = {
        settings.models = lib.mapAttrs (_: m: { url = "http://127.0.0.1:${toString m.port}"; }) models;
        inherit portsRegistry unitsRegistry;
      };
    };

  mkQuadletObjectOptions =
    {
      description ? "this container",
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
      credentialMountOptions = mkOption {
        type = with types; listOf str;
        default = [ ];
        example = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
        description = ''
          Podman volume options appended to this container's systemd credential
          mount. Use an `idmap` mapping when `[Container] User=` selects a
          non-root identity. The mount is always read-only.
        '';
      };
    };

  quadletMountSuffix =
    options: lib.optionalString (options != [ ]) ":${lib.concatStringsSep "," options}";

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
    EnvironmentFile =
      lib.optional (cfg.environmentFile != null) cfg.environmentFile
      ++ lib.optional (workload.environmentFile != null) workload.environmentFile;
    Environment = {
      ${cfg.cache.environmentVariable} = cfg.cache.containerDirectory;
    }
    // cfg.environment
    // workload.environment;
  };
in
{
  inherit
    credentialDirectory
    credentialsOption
    enabled
    enabledModels
    sortedModels
    identityConfig
    mergeCredentialServiceConfig
    renderCliArgs
    renderCliArgsShell
    resolveCredentialRefs
    settingsRendering
    systemdCredentialDirectory
    vllmDetectorOptions
    vllmDetectorRegistry
    vllmDetectorSettings
    vllmDetectorUnit
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
    mkContainerRuntime = mkQuadletContainerRuntime;
    mkObjectOptions = mkQuadletObjectOptions;

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
        rangeOptions =
          startName:
          types.submodule {
            options = {
              ${startName} = mkOption {
                type = types.ints.unsigned;
                description = "First subordinate ID in this range.";
              };
              count = mkOption {
                type = types.ints.positive;
                description = "Number of consecutive subordinate IDs in this range.";
              };
            };
          };
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
              autoSubUidGidRange = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Whether NixOS automatically allocates subordinate UID and GID
                  ranges for the managed account.
                '';
              };
              subUidRanges = mkOption {
                type = types.listOf (rangeOptions "startUid");
                default = [ ];
                description = "Explicit subordinate UID ranges for the managed account.";
              };
              subGidRanges = mkOption {
                type = types.listOf (rangeOptions "startGid");
                default = [ ];
                description = "Explicit subordinate GID ranges for the managed account.";
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
        quadlet = mkQuadletObjectOptions { description = "every generated container"; } // {
          user = mkOption {
            type = types.nullOr userType;
            default = null;
            description = ''
              Host account whose systemd user manager owns these Quadlets.
              `null` installs system units and runs Podman rootfully. An
              attribute set installs user units for its `uid` and runs Podman
              rootlessly. This is independent of `[Container] User=` and the
              container's user namespace configuration.
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
            description = "Whether llmhop creates the host cache directory with systemd-tmpfiles.";
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
            description = "Host owner used when `cache.manage` is enabled.";
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
          mode = mkOption {
            type = types.str;
            default = "0700";
            description = "Mode used when `cache.manage` is enabled.";
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

    # Per-model submodule for a quadlet-based backend (without `port`, since
    # its description varies per backend). Use as one entry of `imports` inside
    # `lib.types.submodule`. `cfg` (the top-level backend config) is passed so
    # `devices` can lazily default to the backend-wide value.
    mkModelSubmodule =
      {
        backend,
        cfg,
        hasModel ? true,
      }:
      let
        serviceName = quadletServiceName backend;
      in
      { name, ... }:
      {
        options =
          (baseModelOptions { inherit backend serviceName name; })
          // {
            tag = mkOption {
              type = with types; nullOr str;
              default = null;
              description = ''
                Tag of the container image used for this model.
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
            quadlet = mkQuadletObjectOptions { description = "this model container"; };
          }
          // lib.optionalAttrs hasModel {
            model = mkOption {
              type = types.str;
              example = "Qwen/Qwen2.5-7B-Instruct";
              description = "Hugging Face repo id (or local path) passed to the model server.";
            };
          };
      };

    # Render a Quadlet container worker fragment. The optional host user
    # selects the systemd user manager. Native Quadlet section overrides are
    # layered globally and then per container.
    mkWorker =
      {
        cfg,
        healthPort,
        healthPath ? "/health",
        healthStartPeriod ? "30m",
        serviceConfig ? { },
        unitConfig ? { },
        containerConfig ? { },
        credentials ? { },
        overrides ? { },
      }:
      let
        credentialMountOptions = [
          "ro"
        ]
        ++ cfg.quadlet.credentialMountOptions
        ++ overrides.credentialMountOptions;
        mergedServiceConfig =
          sharedServiceConfig
          // {
            Restart = "always";
            LimitNOFILE = cfg.openFilesLimit;
          }
          // serviceConfig
          // cfg.quadlet.serviceConfig
          // overrides.serviceConfig;
        mergedContainerConfig = {
          NoNewPrivileges = true;
          DropCapability = "all";
          Tmpfs = [ "/tmp" ];
          Notify = "healthy";
          HealthCmd = "curl --fail --silent --show-error http://localhost:${toString healthPort}${healthPath}";
          HealthStartPeriod = healthStartPeriod;
          HealthInterval = "10s";
          HealthTimeout = "5s";
        }
        // containerConfig
        // cfg.quadlet.containerConfig
        // overrides.containerConfig;
      in
      {
        uid = if cfg.quadlet.user == null then null else cfg.quadlet.user.uid;
        # `Restart = "always"` overrides quadlet-nix's `on-failure` default:
        # vLLM/sglang catch an EngineCore death, shut the API server down
        # gracefully, and exit 0, so `on-failure` would leave a crashed worker
        # dead. `StartLimitBurst` (shared unit config) still breaks crash loops.
        serviceConfig = mergeCredentialServiceConfig mergedServiceConfig credentials;
        unitConfig = sharedUnitConfig // unitConfig // cfg.quadlet.unitConfig // overrides.unitConfig;
        quadletConfig = cfg.quadlet.quadletConfig // overrides.quadletConfig;
        extraConfig = lib.recursiveUpdate cfg.quadlet.extraConfig overrides.extraConfig;
        # `[Container]` defaults: minimal hardening (podman handles the rest)
        # plus an HTTP readiness probe. The rootfs stays writable — ML runtimes
        # scatter JIT/compile caches across version-dependent HOME paths, so an
        # immutable rootfs would need an ever-growing tmpfs allow-list. `/tmp` is
        # a tmpfs for fast scratch (torch inductor's `/tmp/torchinductor_root`).
        containerConfig =
          mergedContainerConfig
          // lib.optionalAttrs (credentials != { }) {
            Volume = lib.toList (mergedContainerConfig.Volume or [ ]) ++ [
              "%d:${credentialDirectory}${quadletMountSuffix credentialMountOptions}"
            ];
          };
      };

    mkImageArgs = mkQuadletImageArgs;

    # Common Quadlet `containerConfig` fields for a model worker: image,
    # pull policy, GPU CDI device, cache bind-mount, env, shm, ulimits.
    # Backend-specific extras (`PublishPort`, `Exec`, ...) spread on top.
    mkContainerArgs =
      {
        backend,
        cfg,
        model,
      }:
      mkQuadletContainerRuntime cfg model
      // mkQuadletImageArgs {
        inherit (cfg) image;
        defaultTag = cfg.tag;
        workload = model;
        label = "services.llmhop.${backend}.models.${model.name}";
      }
      // {
        AddDevice = model.devices;
        ShmSize = model.shmSize;
        Ulimit = "host";
      };

    # `[Unit] After=` for the ascending startup chain: each container waits on
    # its lower-port predecessor so GPU-memory profiling never overlaps.
    mkStartupOrdering =
      {
        config,
        cfg,
        models,
        prefix,
        index,
      }:
      {
        After =
          lib.optional (cfg.startupOrdering && index > 0)
            "${
              config.virtualisation.quadlet.containers."${prefix}-${
                (lib.elemAt models (index - 1)).name
              }".serviceName
            }.service";
      };

    # Cross-cutting NixOS config produced by every quadlet backend:
    # the quadlet-enabled assertion, llmhop registration, resource registries,
    # cache directory, and optional rootless account and operator helper.
    #
    # `extras` / `extraUnits` are labeled attrsets of auxiliary host ports
    # (e.g. `{ gateway = 30000; }`) and unit names (e.g.
    # `{ gateway = "sglang-gateway"; }`) folded into the global registries.
    mkConfig =
      {
        backend,
        cfg,
        config,
        pkgs,
        extras ? { },
        extraUnits ? { },
      }:
      let
        serviceName = quadletServiceName backend;
        user = cfg.quadlet.user;
      in
      lib.mkMerge [
        (mkSharedConfig {
          inherit
            backend
            serviceName
            cfg
            extras
            extraUnits
            ;
        })
        {
          assertions = [
            {
              assertion = config.virtualisation.quadlet.enable;
              message = "services.llmhop.${backend} requires virtualisation.quadlet.enable.";
            }
            {
              assertion =
                user == null
                || !user.manage
                || !user.autoSubUidGidRange
                || (user.subUidRanges == [ ] && user.subGidRanges == [ ]);
              message = "services.llmhop.${backend}.quadlet.user cannot combine automatic and explicit subordinate ID ranges.";
            }
          ];

          systemd.tmpfiles.settings."10-${serviceName}" = lib.optionalAttrs cfg.cache.manage {
            ${cfg.cache.directory}.d = {
              inherit (cfg.cache) user group mode;
            };
          };

          environment.systemPackages = lib.optional (user != null) (
            pkgs.writeShellApplication {
              name = "${serviceName}-shell";
              text = ''
                if [ "$#" -eq 0 ]; then
                  echo "Entering the ${serviceName} user shell. Useful commands:"
                  echo "  systemctl --user status ${serviceName}-<model>    # service state"
                  echo "  journalctl --user -u ${serviceName}-<model> -f    # tail logs"
                  echo "  podman ps                                     # list containers"
                  echo "  exit                                          # back to host"
                  exec sudo machinectl --quiet shell ${user.name}@.host
                fi
                exec sudo machinectl --quiet shell ${user.name}@.host /usr/bin/env "$@"
              '';
            }
          );
        }
        (lib.mkIf (user != null && user.manage) {
          users.users.${user.name} = {
            description = "${serviceName} container service user";
            inherit (user)
              uid
              group
              home
              autoSubUidGidRange
              subUidRanges
              subGidRanges
              ;
            isSystemUser = true;
            createHome = true;
            shell = config.users.defaultUserShell;
            extraGroups = [ "systemd-journal" ];
            linger = true;
          };
          users.groups.${user.group}.gid = user.gid;
        })
      ];
  };

  # ─── Systemd (host-process) ──────────────────────────────────────────

  systemd =
    let
      # The readiness supervisor, resolved from this flake rather than from
      # `services.llmhop.package`: it is a module implementation detail, and a
      # deployer-supplied llmhop build need not ship `llmhop-notify` at all —
      # `getExe'` would not catch that, leaving every worker in `activating`
      # until `TimeoutStartSec`.
      notifyExe = pkgs: lib.getExe' (pkgs.callPackage ../package.nix { }) "llmhop-notify";

      # Render a systemd worker unit fragment from the worker's argv. Returns
      # `{ serviceConfig, unitConfig }` with the shared baseline plus full
      # systemd-exec(5) hardening merged in and lifecycle settings enforced last.
      #
      # `llmhop-notify` keeps the unit activating until its readiness path answers and
      # propagates server failures that happen while the model is loading.
      mkWorker =
        {
          openFilesLimit,
          pkgs,
          utils,
          healthPort,
          healthPath ? "/health",
          execStart,
          serviceConfig ? { },
          unitConfig ? { },
          credentials ? { },
        }:
        {
          # `[Service]` defaults: worker-scale timing, universal hardening, the
          # per-unit file-descriptor limit, and a `bind()` lockdown that pairs
          # with the caller-provided `SocketBindAllow` for the worker's listener.
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
                  "-port"
                  (toString healthPort)
                  "-health-path"
                  healthPath
                ]
                ++ execStart
              );
            }
          ) credentials;
          unitConfig = sharedUnitConfig // unitConfig;
        };

      # Per-model escape hatch shared by every systemd (host-process) backend:
      # extra `[Service]` settings that each worker merges last, so they win over
      # the hardened baseline and any backend relaxations.
      serviceConfigOption =
        { serviceName }:
        mkOption {
          type = with types; attrsOf anything;
          default = { };
          example = {
            MemoryHigh = "64G";
          };
          description = ''
            Extra `[Service]` settings merged into this model's
            `${serviceName}-<name>` unit after the hardened baseline and
            backend-specific relaxations. The module retains ownership of
            `ExecStart`, `KillMode`, and `Type` because they implement readiness
            supervision as one lifecycle contract.
          '';
        };

      # Companion `[Unit]` hatch, merged over `sharedUnitConfig` the same way.
      unitConfigOption =
        { serviceName }:
        mkOption {
          type = with types; attrsOf anything;
          default = { };
          example = {
            StartLimitBurst = 10;
          };
          description = ''
            Extra `[Unit]` settings merged into this model's
            `${serviceName}-<name>` unit after the shared baseline.

            Ordering and dependency directives (`After=`, `Requires=`, `Wants=`)
            do not belong here: NixOS renders those from the `after`, `requires`
            and `wants` options, so a definition of the same key in `unitConfig`
            conflicts with it instead of merging. Declare them on
            `systemd.services."${serviceName}-<name>"` from your own module,
            where the module system concatenates them with what this one sets.
          '';
        };

      # One systemd unit for any uv/wheel-based Python service of a backend:
      # the dedicated-user layout, the cache root every runtime is redirected
      # into, the toolchain these JIT-compiling runtimes look up the FHS way,
      # the host driver libraries prebuilt wheels `dlopen` by name, and the
      # `mkWorker` hardening and readiness baseline.
      #
      # `workload` is anything carrying `name`, `port`, `environment`,
      # `environmentFile`, `credentials`, `serviceConfig` and `unitConfig`, so
      # model workers and auxiliary services (watermark detectors, and whatever
      # a backend adds next) share one body. `mkUvWorker` extends this with the
      # GPU access and startup-chain specifics a model worker additionally needs.
      #
      # Expects `cfg` to carry `openFilesLimit`, `user`, `group`, `environment`
      # and `environmentFile`. Returns a `nameValuePair`.
      mkUvService =
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
          environment ? (_cacheBase: { }),
          serviceConfig ? { },
        }:
        let
          # CacheDirectory root, owned by `cfg.user`; see `gpuCacheEnvironment`.
          cacheBase = "/var/cache/${subdir}";
        in
        lib.nameValuePair unitName (
          {
            inherit description;
            wantedBy = [ "multi-user.target" ];
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ] ++ after;
            # A toolchain on `PATH`, because these runtimes compile at runtime and
            # look one up the FHS way. Triton builds its CUDA driver shim on the
            # first kernel launch and searches `$CC`, then `gcc`/`clang` on `PATH`;
            # torch's `cpp_extension` and flashinfer's JIT drive their builds
            # through `ninja`, which nixpkgs patches to `posix_spawnp("sh")`, so
            # it needs a shell on `PATH` rather than at `/bin/sh`; ctypes falls
            # back to invoking `gcc` and `ld` once nixpkgs' patched `ldconfig`
            # lookup returns nothing. A unit otherwise has none of them.
            path = with pkgs; [
              stdenv.cc
              ninja
              bash
            ];
            environment = {
              # The service user has no home, so `$HOME` is `/` and every library
              # that reaches for `~` (flashinfer's JIT workspace, among others)
              # hits the read-only root under `ProtectSystem = "strict"`. Pointing
              # it at the cache root keeps those writes with the rest of the
              # regenerable state, where `systemctl clean` can reach them.
              HOME = cacheBase;
              HF_HOME = cacheBase;
              HF_HUB_CACHE = "${cacheBase}/hub";
              XDG_CACHE_HOME = cacheBase;
              # These two stay here rather than in `gpuCacheEnvironment` because
              # they are about prebuilt wheels finding host driver libraries, not
              # about GPUs: a nixpkgs-built worker resolves the same libraries
              # from the runpath `autoAddDriverRunpath` gave it at build time.
              #
              # `mkUvEnv` bakes that runpath into the wheels too, so `libcuda.so.1`
              # and its ROCm / Level Zero counterparts resolve via RPATH. This
              # additionally covers the host driver libs the framework `dlopen`s by
              # name from Python during GPU-memory profiling (e.g.
              # `libnvidia-ml.so.1`), which RPATH does not reach.
              LD_LIBRARY_PATH = "/run/opengl-driver/lib";
              # Triton locates `libcuda.so.1` by shelling out to `/sbin/ldconfig -p`,
              # which does not exist on NixOS, so its JIT backend dies with a
              # `FileNotFoundError` the moment a kernel is compiled. This knob is the
              # upstream escape hatch and short-circuits the lookup entirely.
              TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
            }
            // gpuCacheEnvironment cacheBase
            // environment cacheBase
            // cfg.environment
            // workload.environment;
          }
          // mkWorker {
            inherit (cfg) openFilesLimit;
            inherit
              pkgs
              utils
              execStart
              healthPath
              ;
            inherit (workload) credentials;
            healthPort = workload.port;
            serviceConfig = {
              UMask = "0077";
              Restart = "on-failure";

              # A real user, not `DynamicUser`: the `/var/lib/private` layout it
              # implies makes systemd hand `State`/`CacheDirectory` over as
              # ID-mapped mounts, which are unconditionally noexec and beyond
              # the reach of `ExecPaths=`. These runtimes compile kernels into
              # that cache and `dlopen` them back.
              User = cfg.user;
              Group = cfg.group;
              CacheDirectory = subdir;
              WorkingDirectory = cacheBase;
              SocketBindAllow = "tcp:${toString workload.port}";

              EnvironmentFile =
                lib.optional (cfg.environmentFile != null) cfg.environmentFile
                ++ lib.optional (workload.environmentFile != null) workload.environmentFile;
            }
            // serviceConfig
            # Last, so the per-workload escape hatch wins over every default.
            // workload.serviceConfig;
            inherit (workload) unitConfig;
          }
        );

      # `mkUvService` for a model worker: GPU device access, the NCCL/RCCL
      # environment, its own `StateDirectory` for non-regenerable state, and the
      # ascending startup chain (`previous` is the preceding model, or null for
      # the first). Only the `execStart` argv and an optional per-backend
      # `extraEnvironment cacheBase` differ between backends.
      mkUvWorker =
        {
          serviceName,
          cfg,
          pkgs,
          utils,
          model,
          previous,
          execStart,
          extraEnvironment,
        }:
        let
          subdir = "${serviceName}/${model.name}";
        in
        mkUvService {
          inherit
            subdir
            cfg
            pkgs
            utils
            execStart
            ;
          unitName = "${serviceName}-${model.name}";
          description = "${serviceName} server for ${model.name}";
          workload = model;
          # Chain ascending so each worker finishes GPU-memory profiling before
          # the next starts (booting two on one device races to OOM). This is
          # only meaningful because `mkWorker` holds the unit in `activating`
          # until the server reports itself ready.
          after = lib.optional (
            cfg.startupOrdering && previous != null
          ) "${serviceName}-${previous.name}.service";
          environment = cacheBase: extraEnvironment cacheBase // ncclEnvironment;
          serviceConfig = {
            # The frameworks trap SIGINT to drain the engine, then exit 0, so
            # `on-failure` would leave a crashed worker dead; `always` revives it
            # while `StartLimitBurst` (shared unit config) still breaks loops.
            KillSignal = "SIGINT";
            Restart = "always";
            TasksMax = 4096;
            StateDirectory = subdir;
            WorkingDirectory = "/var/lib/${subdir}";
          }
          # GPU relaxations, then NCCL/RCCL's.
          // gpuServiceConfig
          // ncclServiceConfig;
        };
    in
    {
      # Top-level options for a systemd-service backend. Just the shared base —
      # nothing container-specific.
      mkOptions = { backend }: baseOptions { inherit backend; };

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
        // identityOptions { inherit backend cfg; }
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

      # Per-model submodule for a systemd-service backend (without `port`).
      mkModelSubmodule =
        { backend }:
        { name, ... }:
        {
          options = baseModelOptions { inherit backend name; } // {
            serviceConfig = serviceConfigOption { serviceName = backend; };
            unitConfig = unitConfigOption { serviceName = backend; };
          };
        };

      # Per-model submodule for a uv/wheel-based GPU Python backend: the shared
      # base plus the loopback `port`, the `model` repo id (`modelArgument` names
      # the CLI argument it is passed as), and a per-model `package` override that
      # defaults to the backend-wide `package`. The override lets a single model
      # pin a different release (e.g. a nightly wheel for a just-released
      # architecture) without disturbing the others. `cfg` is the backend config,
      # read for the package default.
      mkUvModelSubmodule =
        {
          backend,
          cfg,
          modelArgument,
          modelExample,
        }:
        { name, ... }:
        {
          options = baseModelOptions { inherit backend name; } // {
            model = mkOption {
              type = types.str;
              example = modelExample;
              description = "Hugging Face repo id (or local path) passed as ${modelArgument}.";
            };
            port = mkOption {
              type = types.port;
              description = ''
                Loopback host port ${backend} binds to (`--host 127.0.0.1 --port <port>`).
                Must be unique per enabled model; llmhop reaches the backend at
                `http://127.0.0.1:<port>`.
              '';
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

      # Re-exported so callers (e.g. the llmhop reverse-proxy unit) can spread
      # them into their own services without going through `mkWorker`.
      inherit
        hardenedServiceConfig
        sharedUnitConfig
        mkWorker
        mkUvService
        ncclServiceConfig
        ncclEnvironment
        gpuServiceConfig
        gpuCacheEnvironment
        ;

      # All worker units for a uv/wheel-based GPU Python backend: enabled models
      # sorted by ascending `port`, each rendered by `mkUvWorker`. Owning the
      # unit name also lets this own the credential directory derived from it,
      # so `execStart` receives settings with every `${cred:…}` already resolved
      # and backends never spell a credential path themselves.
      mkUvServices =
        {
          serviceName,
          cfg,
          pkgs,
          utils,
          execStart,
          extraEnvironment ? (_cacheBase: { }),
        }:
        let
          models = sortedModels cfg;
        in
        lib.listToAttrs (
          lib.imap0 (
            index: model:
            let
              directory = systemdCredentialDirectory "${serviceName}-${model.name}";
            in
            mkUvWorker {
              inherit
                serviceName
                cfg
                pkgs
                utils
                model
                extraEnvironment
                ;
              # Ascending chain: each worker waits on its lower-port predecessor.
              previous = if index > 0 then lib.elemAt models (index - 1) else null;
              execStart = execStart model (
                resolveCredentialRefs directory model.credentials (cfg.modelSettings // model.settings)
              );
            }
          ) models
        );

      # Cross-cutting NixOS config produced by a systemd backend: port
      # uniqueness assertion (local + global registry) plus llmhop registration.
      # Units are named after the backend itself. No user/group: llama.cpp gets
      # one per service from `DynamicUser`, while the uv backends, which cannot
      # (see `mkUvWorker`), merge in `identityConfig` alongside this.
      mkConfig =
        {
          backend,
          cfg,
          extras ? { },
          extraUnits ? { },
        }:
        mkSharedConfig {
          inherit
            backend
            cfg
            extras
            extraUnits
            ;
          serviceName = backend;
        };
    };
}
