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
      pkgs.runCommandLocal "llmhop.json" { } ''
        ${lib.getExe cfg.package} -check -config ${configFile}
        cp ${configFile} $out
      ''
    else
      configFile;

  baseServiceConfig = native.serviceConfig cfg;

  tcpListeners = lib.filterAttrs (_: listener: listener.port != null) cfg.listen;

  # A `ListenStream=`, which takes IP literals only.
  listenStream =
    listener:
    if listener.port == null then
      listener.socket
    else if listener.host == "" then
      toString listener.port
    else
      hostPort listener.host listener.port;

  # Shared by the top-level options, which define the `default` listener, and
  # every entry of `listen`.
  listenerOptions = name: defaultPort: {
    port = lib.mkOption {
      type = with lib.types; nullOr port;
      default = defaultPort;
      description = ''
        TCP port to listen on. `null` listens on the unix socket `socket`
        instead.
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

  inherit (import ./lib lib)
    credentialServiceConfig
    credentialsOption
    engines
    hostPort
    identityConfig
    identityOptions
    native
    sharedUnitConfig
    watermark
    ;
in
{
  imports = [ watermark.native ] ++ map native.mkBackend (lib.attrNames engines);

  meta = {
    maintainers = with lib.maintainers; [ mirkolenz ];
    doc = ../../docs/src/internals.md;
  };

  # The `default` listener and the identity llmhop runs as, beside the rest.
  options.services.llmhop =
    listenerOptions "default" 8080
    // identityOptions {
      inherit cfg;
      name = "llmhop";
      prefix = "services.llmhop";
    }
    // {
      enable = lib.mkEnableOption "llmhop reverse proxy";

      package = lib.mkPackageOption pkgs "llmhop" { } // {
        default = pkgs.callPackage ../package.nix { };
        defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      };

      socketDirectory = lib.mkOption {
        type = lib.types.strMatching "/run(/[[:alnum:]_][[:alnum:]_.-]*)+";
        default = "/run/llmhop";
        description = ''
          Directory of every unix socket llmhop serves or connects to: the
          default path of each socket listener, and one directory per workload
          without a `port`. Those are `RuntimeDirectory=`s, hence the `/run`
          prefix.
          Each path component must start with a letter, digit, or underscore and
          contain only those characters, dots, and hyphens.
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
        description = credentialsOption.description + ''

          llmhop reads its own config, so in `settings` the reference expands to
          the credential's contents rather than to its path.
        '';
      };

      claims = lib.mkOption {
        type = with lib.types; attrsOf (attrsOf (listOf str));
        default = { };
        internal = true;
        example.port."8080" = [
          "services.llmhop.listen.default"
          "services.llmhop.vllm.models.qwen3-8b"
        ];
        description = ''
          Resources that only one owner may hold, by kind (`port`, `unit`,
          `model`, `directory`) and key, each listing the option paths of its
          owners. An assertion rejects every key with more than one owner.
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
    };

  config = lib.mkMerge [
    {
      # Backends claim their resources without llmhop too.
      assertions = lib.concatLists (
        lib.mapAttrsToList (
          kind:
          lib.mapAttrsToList (
            key: owners: {
              assertion = lib.length owners < 2;
              message = "services.llmhop: ${kind} `${key}` is claimed by ${lib.concatStringsSep ", " owners}.";
            }
          )
        ) cfg.claims
      );
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
        claims.port = lib.mkMerge (
          lib.mapAttrsToList (name: listener: {
            ${toString listener.port} = [ "services.llmhop.listen.${name}" ];
          }) tcpListeners
        );
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

          unitConfig = sharedUnitConfig;

          # Tighter than the worker baseline: `@resources` syscalls are blocked
          # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited baseline
          # for the sd_notify datagram and the worker sockets. Named, not
          # `DynamicUser`, so the Quadlet sockets' ACL can grant this user
          # alone. Never give it a `RuntimeDirectory=` of `socketDirectory`:
          # stopping llmhop would delete every socket.
          serviceConfig =
            baseServiceConfig
            // credentialServiceConfig cfg.credentials
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
              # The listeners arrive from `llmhop-<name>.socket`, so nothing is
              # bound here.
              Sockets = lib.mapAttrsToList (name: _: "llmhop-${name}.socket") cfg.listen;
              UMask = "0077";
              SystemCallFilter = baseServiceConfig.SystemCallFilter ++ [ "~@resources" ];
            };
        };
      };
    })
  ];
}
