# Option builders shared by every backend and workload.
lib: self:
let
  inherit (lib)
    mkEnableOption
    mkOption
    types
    ;
  inherit (self)
    baseWorkloadOptions
    credentialSources
    credentialsOption
    engine
    isQuadlet
    isRepository
    modelLabel
    quadletServiceName
    repositoriesOption
    settingsRendering
    socketCapable
    socketName
    workloadUnit
    ;
in
{
  # Top-level options every backend exposes, regardless of kind.
  baseOptions =
    { backend }:
    let
      serviceName = quadletServiceName backend;
    in
    {
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
        prune = mkEnableOption ''
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
            Credentials granted to every fetcher through systemd.
            ${credentialSources "llmhop.hf-token"}

            Reference the resulting read-only file from `fetch.environment` as
            `''${cred:<name>}`.
          '';
        };
      };
      cache = {
        directory = mkOption {
          type = types.path;
          default = "/var/cache/${serviceName}";
          description = ''
            Host directory shared by every fetcher and server of this backend
            as `HF_HOME`, holding the Hugging Face hub cache in `hub`. The
            fetchers write it, the servers only read it, and containers mount
            it at the same path. Point it at a data disk for large models.
          '';
        };
        manage = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether llmhop creates `directory` with systemd-tmpfiles, mode
            `0700` and owned by the account the units run as.
          '';
        };
      };
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
          File in `KEY=VALUE` format forwarded to every server.
          Use only for upstream features that require environment variables.
          Environment variables are not systemd credentials and are visible to
          every model, so prefer `credentials` for any secret a server can read
          from a file. A Hugging Face token belongs to `fetch` instead, since
          only the fetchers download.
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

  # Identity of the units of a backend, a named account rather than a
  # `DynamicUser`, since its fetchers and servers share their directories.
  # `prefix` is the option path, for the documented defaults.
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

  # Config-side twin of `identityOptions`.
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
      # A socket-capable workload defaults to `port = null`, which binds
      # `socket` instead of a TCP port.
      port = mkOption (
        if socketCapable backend then
          {
            type = types.nullOr types.port;
            default = null;
            description = ''
              ${portDescription}
              `null` binds the unix socket `socket` instead, which claims no port,
              only llmhop can connect to, and keeps the server off any network.
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
          if socketCapable backend && workload.port == null then
            "${socketDirectory}/${workloadUnit serviceName workload}/${socketName}"
          else
            null;
        defaultText = lib.literalMD "`<services.llmhop.socketDirectory>/${serviceName}-<name>/${socketName}` while `port` is null, else null";
        description = "Unix socket the server binds, derived from `port`.";
      };
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
          override global ones. Prefer `credentials` for any secret the server
          can read from a file. Must be readable by the user systemd reads it as.
        '';
      };
      credentials = credentialsOption;
      offline = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether this ${noun}'s server runs without network access, serving
          only what its fetcher downloaded. Disable it for features that
          download at runtime, such as media URLs in requests. The server then
          still binds loopback or its socket, but may connect anywhere and
          download from the hub itself.
        '';
      };
    };

  # Per-model options every backend exposes, regardless of kind.
  # `modelDescription` says how the server receives `model`.
  baseModelOptions =
    args@{
      backend,
      workload,
      modelDescription,
      modelExample,
      ...
    }:
    baseWorkloadOptions (
      removeAttrs args [
        "modelDescription"
        "modelExample"
      ]
      // {
        noun = "model";
      }
    )
    // {
      model = mkOption {
        type = types.str;
        example = modelExample;
        description = ''
          ${modelDescription}
          A repository is downloaded by the fetcher, while an absolute path is
          served as is.
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
        lib.optional (isRepository workload.model) {
          repo = workload.model;
          revision = workload.revision or null;
        }
        ++ map (repo: { inherit repo; }) workload.extraModels
        # Only the native backends lack what the images ship.
        ++ lib.optionals (!isQuadlet backend) (engine backend).nativeRepositories
      );
    }
    // lib.optionalAttrs (engine backend).revisions {
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
    }
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
}
