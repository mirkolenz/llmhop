{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop;
  format = pkgs.formats.json { };
  configFile = format.generate "llmhop.json" cfg.settings;
in
{
  options.services.llmhop = {
    enable = lib.mkEnableOption "llmhop reverse proxy";

    package = lib.mkPackageOption pkgs "llmhop" { } // {
      default = pkgs.callPackage ./package.nix { };
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
  };

  config = lib.mkIf cfg.enable {
    systemd.services.llmhop = {
      description = "llmhop reverse proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          (lib.getExe cfg.package)
          "--config"
          configFile
        ];
        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        RemoveIPC = true;
        UMask = "0077";
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
