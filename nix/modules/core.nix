# The options every backend and the gateway share: the runtime of all their
# units, the sockets of native ones, the user namespaces of containers, and
# the claims that keep ports, units and model names unique.
sectionType:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.llmhop;

  # Assertion that only one owner claims the resource `key` of `kind`.
  claimAssertion = kind: key: owners: {
    assertion = lib.length (lib.unique owners) < 2;
    message = "services.llmhop: ${kind} `${key}` is claimed by ${lib.concatStringsSep ", " owners}.";
  };
in
{
  meta.maintainers = with lib.maintainers; [ mirkolenz ];

  options.services.llmhop = {
    version = mkOption {
      type = types.str;
      internal = true;
      default = "dev";
      description = "Version of `package`, which the flake's modules set to its revision.";
    };

    package = mkOption {
      type = types.package;
      internal = true;
      readOnly = true;
      default = pkgs.callPackage ../package.nix { inherit (cfg) version; };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The llmhop package, whose binary also runs the worker commands.";
    };

    systemctl = mkOption {
      type = types.str;
      internal = true;
      default = lib.getExe' config.systemd.package "systemctl";
      defaultText = lib.literalExpression ''lib.getExe' config.systemd.package "systemctl"'';
      description = "The `systemctl` of the running systemd, which the refresh units call.";
    };

    runtime = mkOption {
      type = types.enum [
        "native"
        "container"
      ];
      default = "native";
      description = ''
        How every backend and the gateway run: natively as hardened services
        with fetchers, unix sockets and offline servers, or as rootful
        Quadlet containers in user namespaces, which publish loopback ports,
        download for themselves and can be bundled for hosts without Nix.
      '';
    };

    socketDirectory = mkOption {
      type = types.strMatching "/run(/[[:alnum:]_][[:alnum:]_.-]*)+";
      default = "/run/llmhop";
      description = ''
        Directory of every unix socket a workload or llmhop serves, with a
        `RuntimeDirectory=` per native workload without a `port`, hence
        below `/run`.
      '';
    };

    socketClients = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [ "caddy" ];
      description = ''
        Users that may connect to the unix socket of every native workload
        without a `port`, such as a reverse proxy in front of them, by
        joining the group of every backend. The gateway adds its own user.
      '';
    };

    container = {
      userNS = mkOption {
        type = with types; nullOr str;
        default = "auto:size=65536";
        example = "auto:gidmapping=0:303:1";
        description = ''
          `UserNS=` of every container, which maps its root onto an
          unprivileged range of the subordinate IDs of the `containers` user
          that quadlet-nix declares, a fresh range on every start. Every
          writable or root-owned mount then gets `idmap`. `null` runs the
          containers as host root, or leaves `UIDMap=` and `GIDMap=` to
          `config`. A host without Nix needs the `containers` entry in
          `/etc/subuid` and `/etc/subgid`.
        '';
      };
      config = mkOption {
        type = sectionType;
        default = { };
        example = {
          GroupAdd = [ "303" ];
        };
        description = ''
          `[Container]` keys of every container, servers, detectors and the
          gateway alike, over the generated ones.
        '';
      };
    };

    claims = mkOption {
      type = with types; attrsOf (attrsOf (listOf str));
      default = { };
      internal = true;
      example.port."8080" = [
        "services.llmhop.gateway.listen.default"
        "services.llmhop.vllm.models.qwen3-8b"
      ];
      description = ''
        Resources that only one owner may hold, by kind (`port`, `unit`,
        `model`) and key, each listing the option paths of its owners. An
        assertion rejects every key with more than one owner.
      '';
    };
  };

  config = {
    assertions = lib.concatLists (
      lib.mapAttrsToList (kind: lib.mapAttrsToList (claimAssertion kind)) cfg.claims
    );
    virtualisation.quadlet.bundle.name = "llmhop";
  };
}
