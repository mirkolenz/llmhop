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
          Use for secrets managed by sops-nix/agenix, e.g. a file containing
          `HF_TOKEN=<token>` to access gated Hugging Face repositories.
          Loaded before `services.llmhop.${backend}.models.<name>.environmentFile`, so
          per-model files override these entries.
        '';
      };
      modelSettings = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          CLI flags forwarded to the model server for every model.
          `true` collapses to `--<key>`; `null` and `false` are dropped (write
          the negated key explicitly, e.g. `"no-mmap" = true;`, when the upstream
          CLI registers a `--no-<key>` form).
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

  # Per-model options every backend exposes, regardless of kind.
  baseModelOptions =
    {
      backend,
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
          (`${backend}-<name>`) and as the routing key registered with llmhop
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
          `true` collapses to `--<key>`; `null` and `false` are dropped (write
          the negated key explicitly, e.g. `"no-mmap" = true;`, when the upstream
          CLI registers a `--no-<key>` form).
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
          override global ones. Must be readable by the user systemd reads it as.
        '';
      };
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

  # Enabled-model subset shared by registry helpers and backend iteration.
  enabledModels = cfg: lib.filterAttrs (_: m: m.enable) cfg.models;

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

  # Cross-cutting NixOS fragment every backend emits: local port-uniqueness
  # assertion plus llmhop model + ports-registry contributions. Backend
  # extras layer on via `lib.mkMerge`.
  #
  # `portsRegistry` keys are `<backend>/<modelName>` for models and
  # `<backend>/<extraLabel>` for auxiliaries (gateways, metrics endpoints);
  # the labels let the global collision assertion in `default.nix` name
  # colliding owners.
  mkSharedConfig =
    {
      backend,
      cfg,
      extras ? { },
      portsMessage ? null,
    }:
    let
      models = enabledModels cfg;
      modelPortEntries = lib.mapAttrs' (name: m: lib.nameValuePair "${backend}/${name}" m.port) models;
      extraPortEntries = lib.mapAttrs' (name: port: lib.nameValuePair "${backend}/${name}" port) extras;
      portsRegistry = modelPortEntries // extraPortEntries;
      ports = lib.attrValues portsRegistry;
    in
    {
      assertions = [
        {
          assertion = lib.length (lib.unique ports) == lib.length ports;
          message =
            if portsMessage != null then
              portsMessage
            else
              "services.llmhop.${backend}.models: each model must use a unique `port`.";
        }
      ];
      services.llmhop = {
        settings.models = lib.mapAttrs (_: m: { url = "http://127.0.0.1:${toString m.port}"; }) models;
        inherit portsRegistry;
      };
    };
in
{
  inherit enabledModels sortedModels resolveImageRef;

  # ─── CLI helpers ──────────────────────────────────────────────────────

  # `lib.cli.toCommandLine` drops `false` values entirely. For backends with
  # argparse `BooleanOptionalAction` (paired `--key` / `--no-key`) we want
  # `key = false` to render as `--no-key` instead. This helper rewrites
  # `{ key = false; }` to `{ "no-key" = true; }` (and vice-versa for `no-`-
  # prefixed keys); other values pass through unchanged.
  #
  # Don't use with backends like SGLang that have explicit `--enable-X` /
  # `--disable-X` pairs and reject invalid `--no-X` flags.
  flipBoolFlags = lib.mapAttrs' (
    name: value:
    if value == false then
      lib.nameValuePair (
        if lib.hasPrefix "no-" name then lib.removePrefix "no-" name else "no-${name}"
      ) true
    else
      lib.nameValuePair name value
  );

  # ─── Quadlet (container-based) ───────────────────────────────────────

  quadlet = {
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
        tagExample ? "latest",
      }:
      (baseOptions { inherit backend; })
      // {
        user = mkOption {
          type = types.str;
          default = backend;
          defaultText = lib.literalExpression "backend";
          description = ''
            Dedicated system user that owns the ${backend} cache directory and that
            container root is mapped to via `--uidmap`. Defaults to the backend
            name; override to point at a user the deployer manages externally
            (in which case the matching `users.users.<name>` and
            `users.groups.<name>` declarations become the deployer's
            responsibility).
          '';
        };
        uid = mkOption {
          type = types.ints.unsigned;
          example = 503;
          description = ''
            Host UID assigned to `services.llmhop.${backend}.user` and used as the
            inner-to-outer mapping target in `--uidmap`.
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
            Host GID assigned to `services.llmhop.${backend}.group` and used as the
            inner-to-outer mapping target in `--gidmap`. Defaults to `uid`.
          '';
        };
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
        cacheDir = mkOption {
          type = types.path;
          default = defaultCacheDir;
          description = "Host directory bind-mounted as the Hugging Face cache for every worker.";
        };
        dataDir = mkOption {
          type = types.path;
          default = "/var/lib/${backend}";
          description = ''
            Home directory of `services.llmhop.${backend}.user`.
            Used by rootless podman for container storage
            (`~/.local/share/containers`), so it must live on a filesystem that
            tolerates overlayfs.
          '';
        };
        subUidStart = mkOption {
          type = types.ints.unsigned;
          example = 300000;
          description = ''
            First host UID of the subordinate range mapped into every container.
            Container UIDs ≥1 are mapped to `subUidCount` consecutive host IDs starting here.
            Required — pick a value clear of NixOS system users (`<1000`), regular login
            UIDs, and other backends' subordinate ranges on the same host.
          '';
        };
        subUidCount = mkOption {
          type = types.ints.positive;
          default = 65536;
          description = ''
            Size of the subordinate UID range mapped into every container.
            65536 covers the full unprivileged ID space inside the namespace.
          '';
        };
        subGidStart = mkOption {
          type = types.ints.unsigned;
          default = cfg.subUidStart;
          defaultText = lib.literalExpression "config.services.llmhop.${backend}.subUidStart";
          description = ''
            First host GID of the subordinate range mapped into every container.
            Defaults to `subUidStart` — most setups keep the UID and GID ranges aligned.
          '';
        };
        subGidCount = mkOption {
          type = types.ints.positive;
          default = cfg.subUidCount;
          defaultText = lib.literalExpression "config.services.llmhop.${backend}.subUidCount";
          description = ''
            Size of the subordinate GID range mapped into every container.
            Defaults to `subUidCount`.
          '';
        };
        startupOrdering = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to chain enabled model services by ascending `port` during startup.
            GPU-memory profiling races otherwise: two workers booting on the same device
            each see it as fully free and race to claim their share, leading to OOM.
            Disable only when each model pins itself to a dedicated device via
            its own `devices`.
          '';
        };
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
      { backend, cfg }:
      { name, ... }:
      {
        options = (baseModelOptions { inherit backend name; }) // {
          model = mkOption {
            type = types.str;
            example = "Qwen/Qwen2.5-7B-Instruct";
            description = "Hugging Face repo id (or local path) passed to the model server.";
          };
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
        };
      };

    # Render a Quadlet container worker fragment. Returns
    # `{ uid, serviceConfig, unitConfig, containerConfig }` with the shared
    # baseline merged in; caller overrides win. The top-level `uid` is
    # quadlet-nix's rootless-system marker — it installs the unit under the
    # per-user rootless search path so the resulting service is owned by that
    # UID's systemd-user instance.
    mkWorker =
      {
        cfg,
        healthPort,
        healthPath ? "/health",
        healthStartPeriod ? "30m",
        serviceConfig ? { },
        unitConfig ? { },
        containerConfig ? { },
      }:
      {
        uid = cfg.uid;
        # `Restart = "always"` overrides quadlet-nix's `on-failure` default:
        # vLLM/sglang catch an EngineCore death, shut the API server down
        # gracefully, and exit 0, so `on-failure` would leave a crashed worker
        # dead. `StartLimitBurst` (shared unit config) still breaks crash loops.
        serviceConfig =
          sharedServiceConfig
          // {
            Restart = "always";
            LimitNOFILE = cfg.openFilesLimit;
          }
          // serviceConfig;
        unitConfig = sharedUnitConfig // unitConfig;
        # `[Container]` defaults: minimal hardening (podman handles the rest)
        # plus an HTTP `/health` probe. The rootfs stays writable — ML runtimes
        # scatter JIT/compile caches across version-dependent HOME paths, so an
        # immutable rootfs would need an ever-growing tmpfs allow-list. `/tmp` is
        # a tmpfs for fast scratch (torch inductor's `/tmp/torchinductor_root`).
        containerConfig = {
          NoNewPrivileges = true;
          DropCapability = "all";
          Tmpfs = [ "/tmp" ];
          Notify = "healthy";
          HealthCmd = "curl --fail --silent --show-error http://localhost:${toString healthPort}${healthPath}";
          HealthStartPeriod = healthStartPeriod;
          HealthInterval = "10s";
          HealthTimeout = "5s";
        }
        // containerConfig;
      };

    # Common Quadlet `containerConfig` fields for a model worker: image,
    # pull policy, GPU CDI device, HF cache bind-mount, env, shm, ulimits.
    # Backend-specific extras (`PublishPort`, `Exec`, ...) spread on top.
    #
    # No `UIDMap`/`GIDMap` needed: the quadlet runs under the backend
    # user's systemd instance and rootless podman handles the userns remap
    # from `/etc/sub{u,g}id`. Digest-locked images use `Pull=missing`;
    # tag-tracking ones `Pull=newer`. EnvironmentFile is global-then-per-
    # model so per-model entries win.
    mkContainerArgs =
      {
        backend,
        cfg,
        model,
      }:
      {
        Image = resolveImageRef {
          inherit (cfg) image;
          inherit (model) tag digest;
          defaultTag = cfg.tag;
          label = "services.llmhop.${backend}.models.${model.name}";
        };
        Pull = if model.digest != null then "missing" else "newer";
        AddDevice = model.devices;
        Volume = [ "${cfg.cacheDir}:/root/.cache/huggingface" ];
        EnvironmentFile =
          lib.optional (cfg.environmentFile != null) cfg.environmentFile
          ++ lib.optional (model.environmentFile != null) model.environmentFile;
        Environment = cfg.environment // model.environment;
        ShmSize = model.shmSize;
        Ulimit = "host";
      };

    # Cross-cutting NixOS config produced by every quadlet backend:
    # assertions (quadlet-enabled + port uniqueness), llmhop registration,
    # port registry, `dataDir`/`cacheDir` tmpfiles, and — when `cfg.user`
    # is left at the backend default — the system user/group plus a helper
    # command that drops into the rootless session via `machinectl shell`.
    #
    # `extras` is a labeled attrset of auxiliary host ports
    # (e.g. `{ gateway = 30000; }`) included in the port-uniqueness checks.
    # Deployers who override `cfg.user` must declare the matching
    # `users.users.<name>` (with the right uid + sub-id ranges) and
    # `users.groups.<group>` themselves.
    mkConfig =
      {
        backend,
        cfg,
        config,
        pkgs,
        description,
        extras ? { },
        portsMessage ? null,
      }:
      let
        dirSpec = {
          user = cfg.user;
          group = cfg.group;
          mode = "0700";
        };
      in
      lib.mkMerge [
        (mkSharedConfig {
          inherit
            backend
            cfg
            extras
            portsMessage
            ;
        })
        {
          assertions = [
            {
              assertion = config.virtualisation.quadlet.enable;
              message = "services.llmhop.${backend} requires virtualisation.quadlet.enable.";
            }
          ];

          systemd.tmpfiles.settings."10-${backend}" = {
            ${cfg.dataDir}.d = dirSpec;
            ${cfg.cacheDir}.d = dirSpec;
          };
        }
        # Real home + shell + linger turn the system user into something
        # systemd-logind treats as a real session: rootless podman gets a
        # writable `~/.local/share/containers`, `machinectl shell` works, and
        # `systemctl --user` keeps running across logouts. `systemd-journal`
        # makes `journalctl --user` work inside the machinectl session.
        (lib.mkIf (cfg.user == backend) {
          users.users.${cfg.user} = {
            inherit description;
            uid = cfg.uid;
            isSystemUser = true;
            group = cfg.group;
            home = cfg.dataDir;
            shell = config.users.defaultUserShell;
            extraGroups = [ "systemd-journal" ];
            linger = true;
            subUidRanges = [
              {
                startUid = cfg.subUidStart;
                count = cfg.subUidCount;
              }
            ];
            subGidRanges = [
              {
                startGid = cfg.subGidStart;
                count = cfg.subGidCount;
              }
            ];
          };
          users.groups.${cfg.group}.gid = cfg.gid;

          # Lets operators inspect the rootless services without remembering
          # the `machinectl` incantation.
          environment.systemPackages = [
            (pkgs.writeShellApplication {
              name = "${backend}-shell";
              text = ''
                if [ "$#" -eq 0 ]; then
                  echo "Entering the ${backend} user shell. Useful commands:"
                  echo "  systemctl --user status ${backend}-<model>    # service state"
                  echo "  journalctl --user -u ${backend}-<model> -f    # tail logs"
                  echo "  podman ps                                     # list containers"
                  echo "  exit                                          # back to host"
                  exec sudo machinectl --quiet shell ${cfg.user}@.host
                fi
                exec sudo machinectl --quiet shell ${cfg.user}@.host /usr/bin/env "$@"
              '';
            })
          ];
        })
      ];
  };

  # ─── Systemd (host-process) ──────────────────────────────────────────

  systemd = {
    # Top-level options for a systemd-service backend. Just the shared base —
    # nothing container-specific.
    mkOptions = { backend }: baseOptions { inherit backend; };

    # Per-model submodule for a systemd-service backend (without `port`).
    mkModelSubmodule =
      { backend }:
      { name, ... }:
      {
        options = baseModelOptions { inherit backend name; };
      };

    # Re-exported so callers (e.g. the llmhop reverse-proxy unit) can spread
    # them into their own services without going through `mkWorker`.
    inherit hardenedServiceConfig sharedUnitConfig;

    # Render a systemd worker unit fragment. Returns
    # `{ serviceConfig, unitConfig }` with the shared baseline plus full
    # systemd-exec(5) hardening merged in; caller overrides win.
    mkWorker =
      {
        openFilesLimit,
        serviceConfig ? { },
        unitConfig ? { },
      }:
      {
        # `[Service]` defaults: worker-scale timing, universal hardening, the
        # per-unit file-descriptor limit, and a `bind()` lockdown that pairs
        # with the caller-provided `SocketBindAllow` for the worker's listener.
        serviceConfig =
          sharedServiceConfig
          // hardenedServiceConfig
          // {
            LimitNOFILE = openFilesLimit;
            SocketBindDeny = "any";
          }
          // serviceConfig;
        unitConfig = sharedUnitConfig // unitConfig;
      };

    # Cross-cutting NixOS config produced by every systemd backend: port
    # uniqueness assertion (local + global registry) plus llmhop
    # registration. No tmpfiles/user/group: systemd backends rely on
    # `DynamicUser` per-service.
    mkConfig = { backend, cfg }: mkSharedConfig { inherit backend cfg; };
  };
}
