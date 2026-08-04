{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.llmhop;
  format = pkgs.formats.json { };

  configFile = format.generate "llmhop.json" cfg.settings;

  # llmhop validates its own config, so the schema lives in exactly one place
  # and a typo fails the build instead of the service (`-check` rejects unknown
  # keys and malformed URLs). Secret references are left unexpanded: the files
  # and environment variables they name do not exist in a build sandbox.
  validatedConfigFile =
    if pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform then
      pkgs.runCommand "llmhop.json" { } ''
        ${lib.getExe cfg.package} -check -config ${configFile}
        cp ${configFile} $out
      ''
    else
      configFile;

  inherit (import ./lib.nix lib) mkRegistryAssertion systemd;
in
{
  imports = [
    ./systemd/llama-cpp.nix
    ./systemd/vllm.nix
    ./systemd/sglang.nix
  ];

  options.services.llmhop = {
    enable = lib.mkEnableOption "llmhop reverse proxy";

    package = lib.mkPackageOption pkgs "llmhop" { } // {
      default = pkgs.callPackage ../package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "127.0.0.1";
      description = ''
        Interface llmhop binds to. The default binds every interface, leaving
        access control to the firewall. IPv6 literals are written plain
        (e.g. `::1`) and bracketed by llmhop itself.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port llmhop listens on. Registered in the global port registry, so a
        backend model reusing it fails evaluation instead of leaving one of the
        two services unable to bind.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open `port` in the host firewall.";
    };

    credentials = lib.mkOption {
      type = with lib.types; attrsOf path;
      default = { };
      example = lib.literalExpression ''
        { client_token = "/run/secrets/llmhop-token"; }
      '';
      description = ''
        Files handed to the service through systemd's `LoadCredential=`, keyed
        by the name they are exposed under. Reference them from `settings` as
        `''${file:<name>}`: relative paths resolve against
        `$CREDENTIALS_DIRECTORY`, a per-unit tmpfs readable only by this
        service, so secrets never enter the world-readable Nix store.

        Any path works, including agenix/sops-nix outputs and manually managed
        files.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      example = {
        models = {
          "gpt-4".url = "https://api.openai.com";
        };
      };
      description = ''
        Configuration written to the JSON config file passed to llmhop.
        See the upstream `Config` struct for available fields; `host` and
        `port` are contributed by the options of the same name.

        The generated file is validated at build time by the binary itself, so
        unknown keys and malformed model URLs fail `nixos-rebuild` rather than
        the service.
      '';
    };

    portsRegistry = lib.mkOption {
      type = with lib.types; attrsOf port;
      default = { };
      internal = true;
      description = ''
        Internal registry of host ports reserved by llmhop backends and their
        auxiliary components (gateways, metrics endpoints). Keyed by the owning
        option path (`<backend>.models.<name>` / `<backend>.<component>`) so the
        global uniqueness assertion can name the colliding owners. Written by
        `lib.nix:mkSharedConfig`; do not set directly.
      '';
    };

    unitsRegistry = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = { };
      internal = true;
      description = ''
        Internal registry of systemd unit names emitted by llmhop backends and
        their auxiliary components, keyed the same way as `portsRegistry`. Two
        backends claiming one unit name — most commonly a native backend and its
        `-quadlet` twin, which share a unit prefix — are mutually exclusive, and
        the global uniqueness assertion names both owners. Written by
        `lib.nix:mkSharedConfig`; do not set directly.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        (mkRegistryAssertion {
          registry = cfg.portsRegistry;
          resource = "host port";
        })
        (mkRegistryAssertion {
          registry = cfg.unitsRegistry;
          resource = "systemd unit";
        })
      ];
    }
    (lib.mkIf cfg.enable {
      services.llmhop = {
        # Contributed as real option definitions rather than merged in behind
        # the user's back, so a conflicting `settings.port` fails evaluation
        # instead of being silently dropped.
        settings = { inherit (cfg) host port; };

        # llmhop's own listener competes for host ports with every backend
        # worker, so it participates in the same collision check.
        portsRegistry."llmhop.port" = cfg.port;
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

      systemd.services.llmhop = {
        description = "llmhop reverse proxy";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        unitConfig = systemd.sharedUnitConfig;

        # Tighter than the worker baseline: `@resources` syscalls are blocked
        # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited baseline
        # for the sd_notify datagram; the proxy itself speaks IP only.
        serviceConfig = systemd.hardenedServiceConfig // {
          # Pairs with the binary's sd_notify call: the unit reaches `active`
          # only once the port accepts connections, so anything ordered after
          # llmhop can assume it answers.
          Type = "notify";
          ExecStart = utils.escapeSystemdExecArgs [
            (lib.getExe cfg.package)
            "-config"
            validatedConfigFile
          ];
          LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") cfg.credentials;
          Restart = "on-failure";
          RestartSec = 5;
          DynamicUser = true;
          PrivateDevices = true;
          UMask = "0077";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@resources"
          ];
        };
      };
    })
  ];
}
