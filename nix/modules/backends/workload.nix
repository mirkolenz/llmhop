# The submodules of the workloads of a backend, its models and its auxiliary
# services such as watermark detectors.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
in
rec {
  # A workload without a `port` binds `socketName` in a `RuntimeDirectory=` of
  # its own below `services.llmhop.socketDirectory`. See "Unix sockets" in the
  # module internals documentation.
  socketName = "http.sock";

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

  # Enabled workloads of `collection` sorted by ascending `name`, the order
  # servers are emitted and chained in.
  sortedWorkloads =
    collection:
    lib.pipe collection [
      (lib.filterAttrs (_: w: w.enable))
      lib.attrValues
      (lib.sortOn (w: w.name))
    ];

  # Submodule of every workload of a backend of `engine` with `runtime`, served
  # as the unit `<engine>-<name>` by its internal `command`, followed by its
  # settings, and while `fetch` from what its fetcher downloaded. Its listener,
  # `derivedSettings` and, while `fetch`, the engine's `offlineSettings`
  # override `settings`, so the gateways, the health probe and the fetcher
  # always agree with the server, while `defaults` only provide defaults.
  workloadModule =
    {
      engine,
      runtime,
      fetch,
      kind,
      socketDirectory,
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
      noun = if kind == "model" then "model" else "watermark detector";
      socketCapable = engine.socketSettings != null;
      portDescription = "Host port the server binds to on `host`.";
      # A container binds the engine's port or the mounted socket.
      listener =
        if runtime == "native" then
          { inherit (config) host port socket; }
        else
          {
            host = "0.0.0.0";
            inherit (engine.quadlet) port;
            socket = if config.socket != null then "${util.containerSocketDirectory}/${socketName}" else null;
          };
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
        listener = mkOption {
          type = types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                description = "Address the server binds.";
              };
              port = mkOption {
                type = with types; nullOr port;
                description = "Port the server binds, or null for its socket.";
              };
              socket = mkOption {
                type = with types; nullOr str;
                description = "Unix socket the server binds, or null for its port.";
              };
            };
          };
          internal = true;
          readOnly = true;
          default = listener;
          description = "The `host`, `port` and `socket` the server binds, in its container if any.";
        };
        exposed = mkOption {
          type = types.bool;
          internal = true;
          readOnly = true;
          default = config.socket == null && !util.isLoopback config.host;
          description = "Whether the server is reachable beyond loopback.";
        };
        fetches = mkOption {
          type = types.bool;
          internal = true;
          readOnly = true;
          default = fetch && config.repositories != [ ];
          description = "Whether a fetcher downloads the repositories of this ${noun}.";
        };
        # See "Offline servers" in the module internals documentation.
        isolable = mkOption {
          type = types.bool;
          internal = true;
          readOnly = true;
          default = config.socket != null || runtime == "native" && !config.exposed;
          description = ''
            Whether the server can run without network: on its socket, or
            natively on a loopback port behind an IP address filter, while a
            container's published port needs a network.
          '';
        };
        command = mkOption {
          type = with types; listOf (either str package);
          internal = true;
          description = "Command of the server, followed by its settings.";
        };
        mounts = mkOption {
          type = with types; listOf str;
          internal = true;
          default = [ ];
          description = "Further `Volume=` lines of the server's container.";
        };
        kind = mkOption {
          type = types.enum [
            "model"
            "detector"
          ];
          internal = true;
          readOnly = true;
          default = kind;
          description = "Whether this workload serves a model or detects watermarks.";
        };
        repositories = mkOption {
          type =
            with types;
            listOf (submodule {
              options = {
                repo = mkOption {
                  type = str;
                  description = "Hugging Face repository.";
                };
                revision = mkOption {
                  type = nullOr str;
                  default = null;
                  description = "Branch, tag or commit, or null for the default branch.";
                };
                include = mkOption {
                  type = listOf str;
                  default = [ ];
                  description = "Glob patterns of the files to download, or all files if empty.";
                };
              };
            });
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
              "${socketDirectory}/${config.unit}/${socketName}"
            else
              null;
          defaultText = lib.literalMD "`<services.llmhop.socketDirectory>/${engine.name}-<name>/${socketName}` while `port` is null, else null";
          description = "Unix socket the server binds, derived from `port`.";
        };
        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "0.0.0.0";
          description = ''
            IP address the server binds `port` to. Any but `127.0.0.1` or
            `::1` requires that no gateway routes it and `offline = false`.
          '';
        };
        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether to open `port` in the host firewall, which requires a
            `host` other than loopback and no gateway routing this ${noun}.
            A container's published port bypasses the firewall either way.
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
          type = with types; nullOr externalPath;
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
          default = fetch && config.isolable;
          defaultText = lib.literalMD "`false` without the backend's `fetch.enable`, else whether `socket` is set or, if its `runtime` is `\"native\"`, `host` is loopback";
          description = ''
            Whether this ${noun}'s server runs without network access. Natively,
            a socket gets a network namespace of its own and a `port` an IP
            address filter, which requires a loopback `host`. A container runs
            with `Network=none`, which requires its socket.
            Disable it for features that download at runtime, such as media URLs
            in requests.
            With the backend's `fetch.enable`, the server serves only what its
            fetcher downloaded either way, and otherwise downloads its
            repositories itself, which requires `false`.
          '';
        };
        settings = mkOption {
          type = with types; attrsOf json;
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
          // lib.optionalAttrs fetch engine.offlineSettings
        ))
        (lib.mapAttrs (_: lib.mkDefault) defaults)
      ];
    };

  # Submodule of a model, a workload whose `model` and `extraRepositories` the
  # fetcher downloads beside the `requiredRepositories` every model of the
  # backend needs.
  modelModule =
    { engine, requiredRepositories }:
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
        extraRepositories = mkOption {
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
            server loads. `null` follows the default branch, so `fetch.schedule`
            picks up upstream changes, while a commit pins the model.
          '';
        };
      };
      config.repositories =
        lib.optional (util.isRepository config.model) {
          repo = config.model;
          revision = config.revision or null;
        }
        ++ map (repo: { inherit repo; }) config.extraRepositories
        ++ requiredRepositories;
    };
}
