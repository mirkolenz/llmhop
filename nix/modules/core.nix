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

    settings = lib.mkOption {
      type = format.type;
      default = { };
      example = {
        listen = ":8080";
        models = {
          "gpt-4".url = "https://api.openai.com";
        };
      };
      description = ''
        Configuration written to the JSON config file passed to llmhop.
        See the upstream `Config` struct for available fields.
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
      systemd.services.llmhop = {
        description = "llmhop reverse proxy";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        unitConfig = systemd.sharedUnitConfig;

        # Tighter than the worker baseline: drop `AF_UNIX` (proxy speaks IP
        # only) and block `@resources` syscalls (no setrlimit/setpriority).
        serviceConfig = systemd.hardenedServiceConfig // {
          ExecStart = utils.escapeSystemdExecArgs [
            (lib.getExe cfg.package)
            "--config"
            configFile
          ];
          Restart = "on-failure";
          RestartSec = 5;
          DynamicUser = true;
          PrivateDevices = true;
          UMask = "0077";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
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
