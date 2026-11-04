# Options shared by the native and the Quadlet backends: those of a backend,
# of every workload and of every model.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  shared = import ./shared.nix lib;
in
rec {
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

  # Options of every backend, regardless of kind.
  backendOptions = engine: {
    enable = lib.mkEnableOption "${engine.displayName} model serving";
    fetch = {
      interval = mkOption {
        type = with types; nullOr str;
        default = "weekly";
        example = "daily";
        description = ''
          `OnCalendar=` schedule of this backend's `<backend>-update`, such
          as `${engine.name}-update`, which runs every fetcher and restarts
          each running server after a successful fetch, even if its model
          did not change.
          `null` disables scheduled fetching.
        '';
      };
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        example.HTTPS_PROXY = "http://proxy.example:3128";
        description = ''
          Environment variables set on every fetcher, such as a proxy. Values
          may reference `fetch.credentials` as `''${cred:<name>}`.
          The servers run offline and never see them.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr path;
        default = null;
        description = ''
          File in `KEY=VALUE` format forwarded to every fetcher, for
          variables that only exist as values.
        '';
      };
      tokenCredential = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "llmhop.hf-token";
        description = ''
          Credential holding a Hugging Face token for gated repositories,
          imported from the system credential store unless
          `fetch.credentials` names a file for it. Only the fetchers receive
          it, as `HF_TOKEN`, and skip it while it is missing.
        '';
      };
      credentials = util.credentialsOption // {
        description = ''
          Credentials granted to every fetcher, in the format of a
          workload's `credentials`. Reference them from `fetch.environment`
          as `''${cred:<name>}`.
        '';
      };
    };
    cache.directory = mkOption {
      type = types.path;
      default = "/var/cache/${engine.name}";
      description = ''
        Root of the cache directories of this backend's workloads, each
        `<name>` the `HF_HOME` of one fetcher and its server, created with
        mode `0700`. The fetcher writes its `hub/`, which the server only
        reads. Point it at a data disk for large models.
      '';
    };
    environment = mkOption {
      type = with types; attrsOf str;
      default = { };
      description = ''
        Environment variables set on every model service, under the
        `environment` of each model, where `''${cred:<name>}` expands to the
        path of a credential.
      '';
    };
    environmentFile = mkOption {
      type = with types; nullOr path;
      default = null;
      example = "/etc/${engine.name}/.env";
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
    extraWorkloads = mkOption {
      type = with types; listOf attrs;
      internal = true;
      default = [ ];
      description = "Workloads served beside the models, such as watermark detectors.";
    };
  };

  # Whether a backend starts its models one at a time, pinned to devices as
  # `pinNote` describes otherwise.
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

  # The listener a server container binds, on the engine's port or the
  # mounted socket.
  quadletListener = engine: workload: {
    host = "0.0.0.0";
    inherit (engine.quadlet) port;
    socket =
      if workload.socket != null then "${util.containerSocketDirectory}/${shared.socketName}" else null;
  };

  # Submodule of every workload, a model or an auxiliary service, served by
  # `engine` as the unit `<engine>-<name>`. `listener` maps the workload to the
  # `{ host, port, socket }` its server binds, natively the workload itself, and `derivedSettings` to further
  # flags. Both override `settings`, so the gateways, the health probe and the
  # fetcher always agree with the server, while `defaults` only provide
  # defaults.
  workloadModule =
    {
      engine,
      noun,
      socketDirectory,
      listener,
      derivedSettings,
      defaults ? { },
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
      listen = listener config;
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
            Name of this ${noun} in its unit `${engine.name}-<name>` and in the
            `model` field clients send, unique across every workload.
          '';
        };
        unit = mkOption {
          type = types.str;
          internal = true;
          readOnly = true;
          default = "${engine.name}-${config.name}";
          description = "Unit name of the server, from which everything keyed by unit derives.";
        };
        owner = mkOption {
          type = types.str;
          internal = true;
          readOnly = true;
          default = lib.showOption (lib.init options.enable.loc);
          description = "Option path of this ${noun}, naming it in `services.llmhop.claims`.";
        };
        description = mkOption {
          type = types.str;
          internal = true;
          readOnly = true;
          default = "${engine.displayName} ${noun} ${config.name}";
          description = "Description of the server unit.";
        };
        unlisted = mkOption {
          type = types.bool;
          internal = true;
          default = false;
          description = ''
            Whether this is an auxiliary service rather than an inference
            model, which gets no GPU, no place in the startup chain, and is
            routed only by the llmhop gateway.
          '';
        };
        repositories = mkOption {
          type = with types; listOf attrs;
          internal = true;
          default = [ ];
          description = "Repositories the fetcher downloads, each `{ repo, revision ? null, include ? [ ] }`.";
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
              "${socketDirectory}/${config.unit}/${shared.socketName}"
            else
              null;
          defaultText = lib.literalMD "`<services.llmhop.socketDirectory>/${engine.name}-<name>/${shared.socketName}` while `port` is null, else null";
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
            Whether to open `port` in the host firewall, which requires a
            `host` other than loopback and no gateway routing this ${noun}.
            A Quadlet container's published port bypasses the firewall either
            way.
          '';
        };
        environment = mkOption {
          type = with types; attrsOf str;
          default = { };
          description = ''
            Environment variables of this ${noun}'s server, over the backend's
            `environment`, where `''${cred:<name>}` expands to the path of a
            credential.
          '';
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
        credentials = util.credentialsOption;
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
            if listen.socket == null then
              { inherit (listen) host port; }
            else
              engine.socketSettings listen.socket
          )
          // derivedSettings config
        ))
        (lib.mapAttrs (_: lib.mkDefault) defaults)
      ];
    };

  # Submodule of a model, a workload whose `model` and `extraModels` the
  # fetcher downloads beside the `extraRepositories` every model of the
  # backend needs.
  modelModule =
    { engine, extraRepositories }:
    { config, ... }:
    {
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
      config.repositories =
        lib.optional (util.isRepository config.model) {
          repo = config.model;
          revision = config.revision or null;
        }
        ++ map (repo: { inherit repo; }) config.extraModels
        ++ extraRepositories;
    };

  # The models of a backend, each a submodule of `modules`.
  modelsOption =
    { engine, description }:
    modules:
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
}
