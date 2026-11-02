# llmhop in front of every endpoint, as a native service under
# `services.llmhop.gateway.llmhop`, the only gateway reaching unix sockets, and
# as a Quadlet container under `services.llmhop.gateway.llmhop-quadlet`.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  gateway = import ./shared.nix lib;

  # The unit and the default user, named after the binary.
  unit = "llmhop";

  settingsOption =
    pkgs:
    mkOption {
      inherit (pkgs.formats.json { }) type;
      default = { };
      example = {
        authTokens = [ "\${cred:llmhop.client-token}" ];
        models."gpt-4".url = "https://api.openai.com";
      };
      description = ''
        llmhop's JSON config, validated at build time by the binary itself,
        with every endpoint of the backends as a model.
      '';
    };

  credentialsOption = util.credentialsOption // {
    description = util.credentialsOption.description + ''

      llmhop reads its own config, so in `settings` the reference expands
      to the credential's contents rather than to its path.
    '';
  };

  # The `models` of the config routing `endpoints`, each probed by readiness.
  models =
    endpoints:
    lib.genAttrs' endpoints (
      endpoint:
      lib.nameValuePair endpoint.name {
        inherit (endpoint) url unlisted;
        health = "/health";
      }
    );

  # The config file of `settings`, validated by `package` itself, so a typo
  # fails the build instead of the service. Secret references stay
  # unexpanded, since what they name does not exist in a build sandbox.
  configFile =
    pkgs: package: settings:
    let
      file = (pkgs.formats.json { }).generate "llmhop.json" settings;
    in
    if pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform then
      pkgs.runCommandLocal "llmhop.json" { } ''
        ${lib.getExe package} -check -config ${file}
        cp ${file} $out
      ''
    else
      file;

  containerConfigFile = "${util.containerRuntimeDirectory}/llmhop.json";
in
{
  native =
    {
      config,
      pkgs,
      utils,
      ...
    }:
    let
      name = "llmhop";
      cfg = config.services.llmhop.gateway.${name};
      inherit (config.services.llmhop) socketDirectory endpoints;
      baseServiceConfig = util.accountServiceConfig cfg;
      tcpListeners = lib.filterAttrs (_: listener: listener.port != null) cfg.listen;

      # A `ListenStream=`, which takes IP literals only.
      listenStream =
        listener:
        if listener.port == null then
          listener.socket
        else if listener.host == "" then
          toString listener.port
        else
          util.hostPort listener.host listener.port;

      # The options of the listener `listenerName`, an entry of `listen`.
      listenerOptions = listenerName: {
        port = mkOption {
          type = with lib.types; nullOr port;
          default = null;
          example = 8080;
          description = ''
            TCP port to listen on. `null` listens on the unix socket `socket`
            instead. The `default` listener defaults to `8080`.
          '';
        };
        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "";
          description = ''
            IP address to bind `port` to. An empty string binds every interface,
            leaving access control to the firewall. IPv6 literals are written
            plain (e.g. `::1`).
          '';
        };
        socket = mkOption {
          type = types.str;
          default = "${socketDirectory}/${listenerName}.sock";
          defaultText = lib.literalExpression ''"''${config.services.llmhop.socketDirectory}/${listenerName}.sock"'';
          description = "Unix socket to listen on while `port` is null.";
        };
        socketUser = mkOption {
          type = types.str;
          default = "root";
          description = "Owner of `socket`.";
        };
        socketGroup = mkOption {
          type = types.str;
          default = "root";
          example = "caddy";
          description = "Group of `socket`, typically the one of a reverse proxy in front of llmhop.";
        };
        socketMode = mkOption {
          type = types.str;
          default = "0660";
          description = "Mode of `socket`. Connecting needs write permission.";
        };
      };
    in
    {
      options.services.llmhop.gateway = {
        type = mkOption { type = types.nullOr (types.enum [ name ]); };
        ${name} =
          util.identityOptions {
            inherit cfg;
            name = unit;
            prefix = gateway.owner name;
          }
          // {
            package = lib.mkPackageOption pkgs "llmhop" { } // {
              default = pkgs.callPackage ../../package.nix { };
              defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
            };

            listen = mkOption {
              type = types.attrsOf (types.submodule ({ name, ... }: { options = listenerOptions name; }));
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

            openFirewall = mkOption {
              type = types.bool;
              default = false;
              description = "Whether to open the `port` of every TCP listener in the host firewall.";
            };

            credentials = credentialsOption;
            settings = settingsOption pkgs;
          };
      };

      config = lib.mkIf (config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          (util.identityConfig {
            inherit cfg;
            name = unit;
          })
          {
            services.llmhop = {
              socketClients = [ cfg.user ];
              gateway.routes = lib.attrNames endpoints;
              gateway.${name} = {
                listen.default.port = lib.mkDefault 8080;
                settings.models = models (lib.attrValues endpoints);
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
              )) (util.rootDirectoryRule socketDirectory);

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

                unitConfig = util.startLimitConfig;

                # Tighter than the worker baseline: `@resources` syscalls are blocked
                # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited
                # baseline for the sd_notify datagram and the worker sockets. Named,
                # not `DynamicUser`, so the Quadlet sockets' ACL can grant this user
                # alone. Never give it a `RuntimeDirectory=` of `socketDirectory`:
                # stopping llmhop would delete every socket.
                serviceConfig =
                  baseServiceConfig
                  // util.credentialServiceConfig cfg.credentials
                  // gateway.restartConfig
                  // {
                    # Pairs with the binary's sd_notify call: the unit reaches
                    # `active` only once llmhop serves, so anything ordered after
                    # it can assume it answers.
                    Type = "notify";
                    ExecStart = utils.escapeSystemdExecArgs [
                      (lib.getExe cfg.package)
                      "-config"
                      (configFile pkgs cfg.package cfg.settings)
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
    };

  quadlet =
    { config, pkgs, ... }:
    let
      name = "llmhop-quadlet";
      cfg = config.services.llmhop.gateway.${name};
      # Every endpoint, unlisted ones included, which it reaches on TCP only.
      endpoints = lib.attrValues config.services.llmhop.endpoints;
      package = pkgs.callPackage ../../package.nix { };
      file = configFile pkgs package cfg.settings;
      # The image of the binary that validated `file`, unless `image` replaces it.
      archive = pkgs.callPackage ../../docker.nix {
        llmhop = package;
        stream = false;
      };
    in
    {
      options.services.llmhop.gateway = {
        type = mkOption { type = types.nullOr (types.enum [ name ]); };
        ${name} = gateway.options "llmhop" // {
          image = util.imageOption // {
            type = with types; nullOr str;
            default = null;
            example = "ghcr.io/mirkolenz/llmhop:latest";
            description = ''
              Container image reference, including a tag or digest, or `null`
              for an archive of this flake's llmhop, which validated the config
              at build time and never auto-updates.
            '';
          };
          credentials = credentialsOption;
          settings = settingsOption pkgs;
        };
      };
      config = lib.mkIf (config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          (gateway.config {
            inherit
              name
              unit
              cfg
              endpoints
              ;
          })
          {
            services.llmhop.gateway.${name}.settings = {
              host = lib.mkDefault cfg.host;
              port = lib.mkDefault cfg.port;
              models = models endpoints;
            };
          }
          (gateway.quadletContainer {
            inherit
              config
              name
              cfg
              unit
              ;
            inherit (cfg) credentials;
            image = if cfg.image == null then "docker-archive:${archive}" else cfg.image;
            imageTag = if cfg.image == null then "localhost/llmhop:${archive.imageTag}" else null;
            arguments = [
              "-config"
              containerConfigFile
            ];
            volumes = [ "${file}:${containerConfigFile}:ro" ];
            # Pairs with the binary's sd_notify call, as natively.
            containerConfig.Notify = true;
          })
        ]
      );
    };
}
