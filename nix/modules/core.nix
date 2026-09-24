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

  tcpListeners = lib.filterAttrs (_: listener: listener.port != null) cfg.listen;

  # A `ListenStream=`, which takes IP literals only.
  listenStream =
    listener:
    if listener.port == null then
      listener.socket
    else if listener.host == "" then
      toString listener.port
    else if lib.hasInfix ":" listener.host then
      "[${listener.host}]:${toString listener.port}"
    else
      "${listener.host}:${toString listener.port}";

  # Shared by the top-level options, which define the `default` listener, and
  # every entry of `listen`.
  listenerOptions = name: defaultPort: {
    port = lib.mkOption {
      type = with lib.types; nullOr port;
      default = defaultPort;
      description = ''
        TCP port to listen on, registered in the global port registry so a
        backend reusing it fails evaluation. `null` listens on the unix socket
        `socket` instead.
      '';
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "127.0.0.1";
      description = ''
        IP address to bind `port` to. The default binds every interface,
        leaving access control to the firewall. IPv6 literals are written
        plain (e.g. `::1`).
      '';
    };
    socket = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.socketDirectory}/${name}.sock";
      defaultText = lib.literalExpression ''"''${config.services.llmhop.socketDirectory}/${name}.sock"'';
      description = "Unix socket to listen on while `port` is null.";
    };
    socketUser = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Owner of `socket`.";
    };
    socketGroup = lib.mkOption {
      type = lib.types.str;
      default = "root";
      example = "caddy";
      description = "Group of `socket`, typically the one of a reverse proxy in front of llmhop.";
    };
    socketMode = lib.mkOption {
      type = lib.types.str;
      default = "0660";
      description = "Mode of `socket`. Connecting needs write permission.";
    };
  };

  # The `default` listener and the identity llmhop runs as.
  topLevelOptions =
    listenerOptions "default" 8080
    // staticIdentityOptions {
      inherit cfg;
      name = "llmhop";
      prefix = "services.llmhop";
    };

  inherit (import ./lib.nix lib)
    credentialsOption
    identityConfig
    identityServiceConfig
    mergeCredentialServiceConfig
    mkRegistryAssertion
    staticIdentityOptions
    systemd
    ;
in
{
  imports = [
    ./systemd/llama-cpp.nix
    ./systemd/vllm.nix
    ./systemd/sglang.nix
  ];

  options.services.llmhop = topLevelOptions // {
    enable = lib.mkEnableOption "llmhop reverse proxy";

    package = lib.mkPackageOption pkgs "llmhop" { } // {
      default = pkgs.callPackage ../package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
    };

    supplementaryGroups = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "inference" ];
      description = ''
        Groups llmhop joins through `SupplementaryGroups=`. Every native
        backend adds its `group`, which owns the sockets of its workers.
      '';
    };

    socketDirectory = lib.mkOption {
      type = lib.types.strMatching "/run/[^/]+(/[^/]+)*";
      default = "/run/llmhop";
      description = ''
        Directory of every unix socket llmhop serves or connects to: the
        default path of each socket listener, and one directory per workload
        without a `port`. Those are `RuntimeDirectory=`s except under a
        rootless Quadlet user, hence the `/run` prefix.
      '';
    };

    listen = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule ({ name, ... }: { options = listenerOptions name null; })
      );
      default = { };
      example.caddy.socketGroup = "caddy";
      description = ''
        Addresses llmhop serves besides the `default` listener, which the
        top-level `port`, `host`, `socket`, `socketUser`, `socketGroup` and
        `socketMode` options define.
        Each is a `llmhop-<name>.socket` unit handing its socket to llmhop
        through socket activation. systemd applies the ownership and mode of a
        unix socket and removes it on stop.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the `port` of every TCP listener in the host firewall.";
    };

    credentials = credentialsOption // {
      description = ''
        Credentials granted to llmhop through systemd. Reference them from
        `settings` as `''${cred:<name>}`, the same spelling the model backends
        use: llmhop reads its own config, so the reference expands to the
        credential's contents rather than to its path.

        A path uses `LoadCredential=`. The attribute form can select
        `LoadCredentialEncrypted=` for a `systemd-creds` encrypted source.
      '';
    };

    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      example = {
        models = {
          "gpt-4".url = "https://api.openai.com";
        };
      };
      description = ''
        Configuration written to the JSON config file passed to llmhop.
        See the upstream `Config` struct for available fields. `host` and
        `port` only apply outside socket activation, so the module's
        listeners come from the options of the same name and `listen` instead.

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

    modelsRegistry = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = { };
      internal = true;
      description = ''
        Internal registry of llmhop routing keys claimed by models and by the
        auxiliaries routed through llmhop, keyed like `portsRegistry`. Two
        owners of one key would collapse into a single `settings.models` entry
        and misroute silently, so the global uniqueness assertion rejects it
        and names both owners. Written by `lib.nix:mkSharedConfig`; do not set
        directly.
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
        (mkRegistryAssertion {
          registry = cfg.modelsRegistry;
          resource = "llmhop routing key";
        })
      ];
    }
    (lib.mkIf cfg.enable (identityConfig {
      inherit cfg;
      name = "llmhop";
    }))
    (lib.mkIf cfg.enable {
      services.llmhop = {
        listen.default = {
          inherit (cfg)
            port
            host
            socket
            socketUser
            socketGroup
            socketMode
            ;
        };

        # llmhop's listeners compete for host ports with every backend worker,
        # so they participate in the same collision check.
        portsRegistry = lib.mapAttrs' (
          name: listener: lib.nameValuePair "llmhop.listen.${name}" listener.port
        ) tcpListeners;
      };

      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
        lib.mapAttrsToList (_: listener: listener.port) tcpListeners
      );

      systemd = {
        # See "Unix sockets" in the module internals documentation.
        tmpfiles.settings."10-llmhop".${cfg.socketDirectory}.d = {
          mode = "0711";
          user = "root";
          group = "root";
        };

        sockets = lib.mapAttrs' (
          name: listener:
          lib.nameValuePair "llmhop-${name}" {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ (listenStream listener) ];
            socketConfig = {
              Service = "llmhop.service";
            }
            // lib.optionalAttrs (listener.port == null) {
              SocketUser = listener.socketUser;
              SocketGroup = listener.socketGroup;
              SocketMode = listener.socketMode;
              RemoveOnStop = true;
            };
          }
        ) cfg.listen;

        services.llmhop = {
          description = "llmhop reverse proxy";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          unitConfig = systemd.sharedUnitConfig;

          # Tighter than the worker baseline: `@resources` syscalls are blocked
          # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited baseline
          # for the sd_notify datagram and the worker sockets.
          serviceConfig = mergeCredentialServiceConfig (
            systemd.hardenedServiceConfig
            # Named, not `DynamicUser`, so the Quadlet sockets' ACL can grant
            # this user alone. Never give it a `RuntimeDirectory=` of
            # `socketDirectory`: stopping llmhop would delete every socket.
            // identityServiceConfig cfg
            // {
              # Pairs with the binary's sd_notify call: the unit reaches `active`
              # only once llmhop serves, so anything ordered after it can assume
              # it answers.
              Type = "notify";
              ExecStart = utils.escapeSystemdExecArgs [
                (lib.getExe cfg.package)
                "-config"
                validatedConfigFile
              ];
              Restart = "on-failure";
              RestartSec = 5;
              SupplementaryGroups = cfg.supplementaryGroups;
              # The listeners arrive from `llmhop-<name>.socket`, so nothing is
              # bound here.
              Sockets = lib.mapAttrsToList (name: _: "llmhop-${name}.socket") cfg.listen;
              SocketBindDeny = "any";
              PrivateDevices = true;
              UMask = "0077";
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
                "~@resources"
              ];
            }
          ) cfg.credentials;
        };
      };
    })
  ];
}
