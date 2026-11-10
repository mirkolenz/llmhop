{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop;

  util = import ./lib.nix lib;
  sockets = lib.filter (e: e.socket != null) (lib.attrValues cfg.endpoints);

  # Assertion that only one owner claims the resource `key` of `kind`.
  claimAssertion = kind: key: owners: {
    assertion = lib.length (lib.unique owners) < 2;
    message = "services.llmhop: ${kind} `${key}` is claimed by ${lib.concatStringsSep ", " owners}.";
  };
in
{
  meta.maintainers = with lib.maintainers; [ mirkolenz ];

  options.services.llmhop = {
    version = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = "dev";
      description = "Version of `package`, which the flake's modules set to its revision.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
      default = pkgs.callPackage ../package.nix { inherit (cfg) version; };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The llmhop package, whose binary also runs the worker commands.";
    };

    systemctl = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = lib.getExe' config.systemd.package "systemctl";
      defaultText = lib.literalExpression ''lib.getExe' config.systemd.package "systemctl"'';
      description = "The `systemctl` of the running systemd, which the refresh units call.";
    };

    runtime = removeAttrs (util.runtimeOption "native") [ "defaultText" ] // {
      description = "Default `runtime` of every backend and gateway, natively as hardened services or as Quadlet containers.";
    };

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
        for the containers. A gateway reaching sockets adds its own user.
      '';
    };

    gateway = {
      type = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "llmhop"
            "smg"
            "bifrost"
          ]
        );
        default = null;
        example = "llmhop";
        description = ''
          The one gateway in front of every backend, configured by the option
          set of the same name, or `null` for none, so clients connect to each
          workload directly. It routes every listed model, which must then
          stay on loopback and leave authentication to the gateway.
        '';
      };
    };

    endpoints = lib.mkOption {
      type = with lib.types; attrsOf attrs;
      default = { };
      internal = true;
      description = ''
        Every workload by its `owner`, which gateways route by its `name`,
        with its `engine`, its `url` on its port or socket, its `socket` or
        null, whether it is `unlisted` and whether it is `exposed` beyond
        loopback.
      '';
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
    assertions = lib.concatLists (
      lib.mapAttrsToList (kind: lib.mapAttrsToList (claimAssertion kind)) cfg.claims
    );

    # A container maps to no host group known in advance, so its socket is
    # reachable through a default ACL on the root instead. See "Unix sockets"
    # in the module internals documentation.
    systemd.tmpfiles.settings."10-llmhop" = lib.mkIf (sockets != [ ]) (
      lib.mkMerge [
        (util.rootDirectoryRule cfg.socketDirectory)
        (lib.mkIf (lib.any (e: cfg.${e.engine}.runtime == "quadlet") sockets && cfg.socketClients != [ ]) {
          ${cfg.socketDirectory}.a.argument = lib.concatMapStringsSep "," (
            user: "default:user:${user}:-wx"
          ) cfg.socketClients;
        })
      ]
    );
  };
}
