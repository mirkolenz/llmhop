# The options every workload of a backend shares, and what their records
# derive from them.
lib:
let
  inherit (lib) mkOption types;
  util = import ../../lib lib;
in
rec {
  # The watermark script of `engine`, natively checked against its
  # environment `package`, while a container runs it unchecked.
  watermarkScriptFor =
    pkgs: llmhop: engine: package:
    let
      script = pkgs.callPackage ../../../pkgs/mkWatermark/package.nix { };
    in
    if llmhop.runtime == "native" then script.checked engine.name package else script.source;

  # A workload without a `port` binds `socketName` in a `RuntimeDirectory=` of
  # its own below `services.llmhop.socketDirectory`. See "Unix sockets" in the
  # module internals documentation.
  socketName = "http.sock";

  # The names of workloads and their attributes, which also name units and
  # paths. Dots allow `qwen3.6-…`-style version suffixes.
  namePattern = "[[:alnum:]_][[:alnum:]_.-]*";

  # Where a container finds the watermark script mounted.
  containerScript = "${util.containerRuntimeDirectory}/watermark.py";

  # One-sentence dialect summary appended to every `settings` description.
  settingsRendering =
    engine:
    "Rendered as `--<key> <value>`, with ${
      if engine.negateBools then
        "`false` as `--no-<key>`"
      else
        "`false` dropped, since this CLI pairs `--enable-X` with `--disable-X`"
    } and a list ${
      if engine.listStyle == "values" then
        "handed to a single flag"
      else
        "joined by commas into a single value"
    }. See [settings rendering](../README.md#settings-rendering) for the full rules.";

  # Whether `workload` is reachable beyond loopback.
  exposed = workload: workload.socket == null && !util.isLoopback workload.host;

  # Whether the server of `workload` can run without network: on its socket,
  # or natively on a loopback port behind an IP address filter. A container
  # publishes its port, which needs a network. See "Offline servers" in the
  # module internals documentation.
  isolable = runtime: workload: workload.socket != null || runtime == "native" && !exposed workload;

  # The watermark of a model or detector profile of `engine`.
  watermarkType =
    engine:
    types.submodule {
      options = {
        settings = mkOption {
          type = with types; attrsOf json;
          default = { };
          example = engine.watermark.example;
          description = "${engine.watermark.description}, which a detector profile must repeat.";
        };
        credential = mkOption {
          type = types.str;
          default = "llmhop.watermark-key.${engine.name}";
          example = "llmhop.watermark-key.${engine.name}.2026-10";
          description = ''
            Credential holding the key, an unsigned 64-bit integer, imported
            from the system credential store unless the service's
            `credentials` names a file for it. A new name per key, such as a
            date suffix, restarts every service using it when the key is
            rotated.
          '';
        };
      }
      // lib.optionalAttrs engine.watermark.secondaryKey {
        secondaryCredential = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "llmhop.watermark-key-b.${engine.name}.2026-10";
          description = ''
            Credential holding the second key of dual-key watermarking, in
            the format of `credential`, or `null` for a single key.
          '';
        };
      };
    };

  # Options of every workload of the backend `cfg` of `engine`, a `noun`,
  # which binds a unix socket while it has no `port` if `socketCapable`.
  workloadOptions =
    {
      engine,
      llmhop,
      cfg,
      noun,
      socketCapable,
      name,
      config,
    }:
    let
      portDescription = "Host port the server binds to on `host`.";
    in
    {
      enable = lib.mkEnableOption "${noun} ${name}" // {
        default = true;
      };
      name = mkOption {
        type = types.strMatching namePattern;
        default = name;
        description = ''
          Name of this ${noun} in the `model` field clients send. Workloads
          sharing a name are replicas, which the gateway balances as one
          model, so they must agree on what it routes, such as their
          adapters, `dataParallelSize` and whether they are listed.
        '';
      };
      unit = mkOption {
        type = types.str;
        readOnly = true;
        default = "${engine.name}-${name}";
        defaultText = lib.literalExpression ''"${engine.name}-<key>"'';
        description = ''
          Name of the server unit, by the attribute name of this ${noun},
          from which every other unit and its cache directory derive.
        '';
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
              connect to, and keeps the server off any network. Containers
              always need a port.
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
          if socketCapable && llmhop.runtime == "native" && config.port == null then
            "${llmhop.socketDirectory}/${config.unit}/${socketName}"
          else
            null;
        defaultText = lib.literalMD "`<services.llmhop.socketDirectory>/${engine.name}-<key>/${socketName}` natively while `port` is null, else null";
        description = "Unix socket the server binds, derived from `port`.";
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        example = "0.0.0.0";
        description = ''
          IP address the server binds `port` to, or a container publishes it
          on. Any but `127.0.0.1` or `::1` requires that the gateway does not
          route it and `offline = false`.
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
      credentials = util.credentialsOption;
      offline = mkOption {
        type = types.bool;
        default = cfg.fetch.enable && isolable llmhop.runtime config;
        defaultText = lib.literalMD "whether the backend's `fetch.enable` is set, the runtime is `\"native\"`, and `socket` is set or `host` is loopback";
        description = ''
          Whether this ${noun}'s server runs without network access, which
          only a native server can: a socket gets a network namespace of its
          own and a `port` an IP address filter, which requires a loopback
          `host`. Disable it for features that download at runtime, such as
          media URLs in requests.
          With the backend's `fetch.enable`, the server serves only what its
          fetcher downloaded either way, and otherwise downloads its
          repositories itself, which requires `false`.
        '';
      };
      package = mkOption {
        type = types.package;
        default = cfg.package;
        defaultText = lib.literalExpression "config.services.llmhop.${engine.name}.package";
        description = ''
          Package providing this ${noun}'s server, overriding the backend's
          `package`, e.g. a nightly build for a just-released architecture.
          ${util.runtimeOnly "native"}
        '';
      };
    }
    // util.environmentOptions {
      environment.description = ''
        Environment variables of this ${noun}'s server, over the backend's
        `environment`, where `''${cred:<name>}` expands to the path of a
        credential.
      '';
      environmentFile.description = ''
        File in `KEY=VALUE` format forwarded to this ${noun}'s server,
        loaded after the backend's `environmentFile`. Prefer `credentials`
        for any secret the server can read from a file.
      '';
    };
}
