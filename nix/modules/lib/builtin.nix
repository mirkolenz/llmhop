# The built-in llmhop gateway under `services.llmhop.gateway.builtin`, the
# only one reaching unix sockets and routing unlisted endpoints.
lib:
{
  common,
  gateway,
  native,
}:
{
  config,
  pkgs,
  utils,
  ...
}:
let
  name = "builtin";
  # The unit and the default user, named after the binary.
  unit = "llmhop";
  cfg = config.services.llmhop.gateway.${name};
  inherit (config.services.llmhop) socketDirectory;
  format = pkgs.formats.json { };

  inherit (common)
    credentialServiceConfig
    credentialsOption
    hostPort
    identityConfig
    identityOptions
    sharedUnitConfig
    socketRootRule
    ;

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

  # The options of the listener `listenerName`, an entry of `listen`.
  listenerOptions = listenerName: {
    port = lib.mkOption {
      type = with lib.types; nullOr port;
      default = null;
      example = 8080;
      description = ''
        TCP port to listen on. `null` listens on the unix socket `socket`
        instead. The `default` listener defaults to `8080`.
      '';
    };
    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "";
      description = ''
        IP address to bind `port` to. An empty string binds every interface,
        leaving access control to the firewall. IPv6 literals are written
        plain (e.g. `::1`).
      '';
    };
    socket = lib.mkOption {
      type = lib.types.str;
      default = "${socketDirectory}/${listenerName}.sock";
      defaultText = lib.literalExpression ''"''${config.services.llmhop.socketDirectory}/${listenerName}.sock"'';
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
in
{
  options.services.llmhop.gateway = gateway.typeOption name // {
    ${name} =
      identityOptions {
        inherit cfg;
        name = unit;
        prefix = gateway.owner name;
      }
      // {
        package = lib.mkPackageOption pkgs "llmhop" { } // {
          default = pkgs.callPackage ../../package.nix { };
          defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
        };

        listen = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: { options = listenerOptions name; }));
          default = { };
          example = {
            default.host = "";
            caddy.socketGroup = "caddy";
          };
          description = ''
            Listeners of llmhop, each a `llmhop-<name>.socket` unit handing its
            socket to llmhop through socket activation. The `default` one
            always exists, on port `8080` unless configured otherwise.
          '';
        };

        openFirewall = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to open the `port` of every TCP listener in the host firewall.";
        };

        credentials = credentialsOption // {
          description = credentialsOption.description + ''

            llmhop reads its own config, so in `settings` the reference expands
            to the credential's contents rather than to its path.
          '';
        };

        settings = lib.mkOption {
          inherit (format) type;
          default = { };
          example = {
            authTokens = [ "\${cred:llmhop.client-token}" ];
            models."gpt-4".url = "https://api.openai.com";
          };
          description = ''
            llmhop's JSON config, validated at build time by the binary itself.
            Every endpoint of the backends is a model here, while `host` and
            `port` do not apply, since the listeners come from `listen`.
          '';
        };
      };
  };

  config = lib.mkIf (config.services.llmhop.gateway.type == name) (
    lib.mkMerge [
      (identityConfig {
        inherit cfg;
        name = unit;
      })
      {
        services.llmhop = {
          socketClients = [ cfg.user ];
          gateway.routes = lib.attrNames config.services.llmhop.endpoints;
          gateway.${name} = {
            listen.default.port = lib.mkDefault 8080;
            settings.models = lib.mapAttrs (_: endpoint: {
              inherit (endpoint) url unlisted;
              health = "/health";
            }) config.services.llmhop.endpoints;
          };
          claims = {
            unit.${unit} = [ (gateway.owner name) ];
            port = lib.mkMerge (
              lib.mapAttrsToList (listenerName: listener: {
                ${toString listener.port} = [ "${gateway.owner name}.listen.${listenerName}" ];
              }) tcpListeners
            );
          };
        };

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
          lib.mapAttrsToList (_: listener: listener.port) tcpListeners
        );

        systemd = {
          # Its socket listeners share the root of the worker sockets.
          tmpfiles.settings."10-llmhop" = lib.mkIf (lib.any (listener: listener.port == null) (
            lib.attrValues cfg.listen
          )) (socketRootRule socketDirectory);

          sockets = lib.mapAttrs' (
            listenerName: listener:
            lib.nameValuePair "llmhop-${listenerName}" {
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
            description = "llmhop model gateway";
            wantedBy = [ "multi-user.target" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];

            unitConfig = sharedUnitConfig;

            # Tighter than the worker baseline: `@resources` syscalls are blocked
            # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited
            # baseline for the sd_notify datagram and the worker sockets. Named,
            # not `DynamicUser`, so the Quadlet sockets' ACL can grant this user
            # alone. Never give it a `RuntimeDirectory=` of `socketDirectory`:
            # stopping llmhop would delete every socket.
            serviceConfig =
              baseServiceConfig
              // credentialServiceConfig cfg.credentials
              // gateway.restartConfig
              // {
                # Pairs with the binary's sd_notify call: the unit reaches
                # `active` only once llmhop serves, so anything ordered after
                # it can assume it answers.
                Type = "notify";
                ExecStart = utils.escapeSystemdExecArgs [
                  (lib.getExe cfg.package)
                  "-config"
                  validatedConfigFile
                ];
                # The listeners arrive from `llmhop-<name>.socket`, so nothing
                # is bound here.
                Sockets = lib.mapAttrsToList (listenerName: _: "llmhop-${listenerName}.socket") cfg.listen;
                UMask = "0077";
                SystemCallFilter = baseServiceConfig.SystemCallFilter ++ [ "~@resources" ];
              };
          };
        };
      }
    ]
  );
}
