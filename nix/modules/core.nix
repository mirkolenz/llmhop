{
  config,
  lib,
  ...
}:
let
  cfg = config.services.llmhop;

  util = import ./lib.nix lib;

  # Assertion that only one owner claims the resource `key` of `kind`.
  claimAssertion = kind: key: owners: {
    assertion = lib.length (lib.unique owners) < 2;
    message = "services.llmhop: ${kind} `${key}` is claimed by ${lib.concatStringsSep ", " owners}.";
  };

  # Assertion of the routed endpoint of `owner`, which only the gateway may
  # expose.
  gatewayAssertion =
    owner:
    let
      endpoint = cfg.endpoints.${owner};
    in
    {
      assertion = !endpoint.exposed;
      message = "services.llmhop: `${endpoint.owner}` is routed by the gateway `${cfg.gateway.type}`, but sets `host` or `openFirewall`, so clients could bypass the gateway.";
    };

  endpointModule = {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Name the workload advertises and gateways route by.";
      };
      engine = lib.mkOption {
        type = lib.types.str;
        description = "Engine of the workload's backend.";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        description = "Option path of the workload.";
      };
      url = lib.mkOption {
        type = lib.types.str;
        description = "URL of the server, `http://` on its port or `unix://` on its socket.";
      };
      socket = lib.mkOption {
        type = with lib.types; nullOr str;
        description = "Unix socket of the server, or null on a port.";
      };
      unlisted = lib.mkOption {
        type = lib.types.bool;
        description = "Whether the workload is no inference model, such as a detector.";
      };
      exposed = lib.mkOption {
        type = lib.types.bool;
        description = "Whether the server is reachable other than through loopback or its socket.";
      };
    };
  };
in
{
  imports = map (import ./backends/native.nix lib) (lib.attrNames (import ./engines.nix lib)) ++ [
    (import ./backends/watermark.nix lib).native
    (import ./gateways/llmhop.nix lib).native
    (import ./gateways/smg.nix lib).native
    (import ./gateways/bifrost.nix lib).native
  ];

  meta = {
    maintainers = with lib.maintainers; [ mirkolenz ];
    doc = ../../docs/src/internals.md;
  };

  options.services.llmhop = {
    socketDirectory = lib.mkOption {
      type = lib.types.strMatching "/run(/[[:alnum:]_][[:alnum:]_.-]*)+";
      default = "/run/llmhop";
      description = ''
        Directory of every unix socket a workload or llmhop serves, with a
        `RuntimeDirectory=` per workload without a `port`, hence below `/run`.
      '';
    };

    socketClients = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "caddy" ];
      description = ''
        Users that may connect to the unix socket of every workload without a
        `port`, such as a reverse proxy in front of them. Each joins the group
        of every native backend and gets a default ACL on `socketDirectory`
        for the Quadlet ones. A gateway reaching sockets adds its own user.
      '';
    };

    gateway = {
      type = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ ]);
        default = null;
        example = "llmhop";
        description = ''
          The one gateway in front of every backend, configured by the option
          set of the same name, or `null` for none, so clients connect to each
          workload directly. It routes every listed model, which must then
          stay on loopback and leave authentication to the gateway.
        '';
      };

      routes = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        internal = true;
        description = "Owners of the endpoints the selected gateway routes, all others staying direct.";
      };
    };

    endpoints = lib.mkOption {
      type = with lib.types; attrsOf (submodule endpointModule);
      default = { };
      internal = true;
      # Unlike `internal`, also hides the options of the submodule.
      visible = false;
      description = "Every workload by its `owner`, which gateways route by its `name`.";
    };

    claims = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf (listOf str));
      default = { };
      internal = true;
      example.port."8080" = [
        "services.llmhop.gateway.llmhop.listen.default"
        "services.llmhop.vllm.models.qwen3-8b"
      ];
      description = ''
        Resources that only one owner may hold, by kind (`port`, `unit`,
        `model`) and key, each listing the option paths of its
        owners. An assertion rejects every key with more than one owner.
      '';
    };
  };

  config = {
    assertions =
      lib.concatLists (lib.mapAttrsToList (kind: lib.mapAttrsToList (claimAssertion kind)) cfg.claims)
      ++ map gatewayAssertion cfg.gateway.routes;

    systemd.tmpfiles.settings."10-llmhop" = lib.mkIf (lib.any (e: e.socket != null) (
      lib.attrValues cfg.endpoints
    )) (util.rootDirectoryRule cfg.socketDirectory);
  };
}
