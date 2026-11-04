# llmhop in front of every endpoint, as a native service under
# `services.llmhop.gateway.llmhop`, the only gateway reaching unix sockets, and
# as a Quadlet container under `services.llmhop.gateway.llmhop-quadlet`, both
# listening on the sockets of their `listen` units.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  gateway = import ./shared.nix lib;

  # The unit and the default user, named after the binary.
  unit = "llmhop";

  settingsOption = mkOption {
    type = with types; attrsOf json;
    default = { };
    example = {
      authTokens.client = "\${cred:llmhop.client-token}";
      models."openai/gpt-4".url = "https://api.openai.com";
    };
    description = ''
      llmhop's JSON config, validated at build time by the binary itself,
      with every endpoint of the backends as a model. Its listeners come
      from `listen`, so `settings` must not set it.
    '';
  };

  credentialsOption = util.credentialsOption // {
    description = util.credentialsOption.description + ''

      llmhop reads its own config, so in `settings` the reference expands
      to the credential's contents rather than to its path.
    '';
  };

  # The options of the listener `listenerName`, an entry of `listen`.
  listenerOptions = socketDirectory: listenerName: {
    port = mkOption {
      type = with types; nullOr port;
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
    openFirewall = gateway.openFirewallOption;
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

  # The `models` of the config routing `endpoints`, each probed by readiness.
  models =
    endpoints:
    lib.genAttrs' endpoints (
      endpoint:
      lib.nameValuePair endpoint.name {
        inherit (endpoint) url unlisted;
        healthPath = util.healthPath;
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
        ${lib.getExe package} check ${file}
        cp ${file} $out
      ''
    else
      file;

  containerConfigFile = "${util.containerRuntimeDirectory}/llmhop.json";

  # The socket unit of the listener `listenerName`.
  socketUnit = listenerName: "llmhop-${listenerName}";

  # The `ListenStream=` of `listener`, which takes IP literals only.
  listenStream =
    listener:
    if listener.port == null then
      listener.socket
    else if listener.host == "" then
      toString listener.port
    else
      util.hostPort listener.host listener.port;

  # What both variants share, which reach `endpoints` and receive their
  # listeners as sockets handed to the service `unit`.
  common =
    {
      config,
      name,
      cfg,
      endpoints,
    }:
    let
      owner = gateway.owner name;
      tcpListeners = lib.filterAttrs (_: listener: listener.port != null) cfg.listen;
    in
    {
      assertions = [
        {
          assertion = !cfg.settings ? listen;
          message = "services.llmhop: `${owner}.settings` sets `listen`, which the sockets of `${owner}.listen` replace.";
        }
      ]
      ++ lib.mapAttrsToList (
        listenerName: util.firewallAssertion "${owner}.listen.${listenerName}"
      ) tcpListeners;

      services.llmhop = {
        gateway = {
          routes = map (e: e.owner) endpoints;
          ${name} = {
            listen.default.port = lib.mkDefault 8080;
            settings.models = models endpoints;
          };
        };
        claims = {
          unit.${unit} = [ owner ];
          port = lib.mkMerge (
            lib.mapAttrsToList (listenerName: listener: {
              ${toString listener.port} = [ "${owner}.listen.${listenerName}" ];
            }) tcpListeners
          );
        };
      };

      networking.firewall.allowedTCPPorts = lib.pipe tcpListeners [
        lib.attrValues
        (lib.filter (listener: listener.openFirewall))
        (map (listener: listener.port))
      ];

      systemd = {
        # Its socket listeners share the root of the worker sockets.
        tmpfiles.settings."10-llmhop" = lib.mkIf (lib.any (listener: listener.port == null) (
          lib.attrValues cfg.listen
        )) (util.rootDirectoryRule config.services.llmhop.socketDirectory);

        sockets = lib.mapAttrs' (
          listenerName: listener:
          lib.nameValuePair (socketUnit listenerName) {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ (listenStream listener) ];
            socketConfig = {
              Service = "${unit}.service";
            }
            // lib.optionalAttrs (listener.port == null) {
              SocketUser = listener.socketUser;
              SocketGroup = listener.socketGroup;
              SocketMode = listener.socketMode;
              RemoveOnStop = true;
            };
          }
        ) cfg.listen;
      };
    };

  # The socket units of the listeners of `cfg`, which the gateway service holds.
  socketUnits =
    cfg: lib.mapAttrsToList (listenerName: _: "${socketUnit listenerName}.socket") cfg.listen;

  options =
    config:
    gateway.commonOptions "llmhop"
    // {
      credentials = credentialsOption;
      settings = settingsOption;
      listen = mkOption {
        type = types.attrsOf (
          types.submodule (
            { name, ... }: { options = listenerOptions config.services.llmhop.socketDirectory name; }
          )
        );
        default = { };
        example = {
          default.host = "";
          caddy.socketGroup = "caddy";
        };
        description = ''
          Listeners of the gateway, each a `llmhop-<name>.socket` unit handing
          its socket to it through socket activation. The `default` one always
          exists, on port `8080` unless configured otherwise.
        '';
      };
    };
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
      inherit (config.services.llmhop) endpoints;
      baseServiceConfig = util.accountServiceConfig cfg;
      sockets = socketUnits cfg;
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
          // options config
          // {
            package = lib.mkPackageOption pkgs "llmhop" { } // {
              default = config.services.llmhop.package;
              defaultText = lib.literalExpression "config.services.llmhop.package";
            };
          };
      };

      config = lib.mkIf (config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          (util.identityConfig {
            inherit cfg;
            name = unit;
          })
          (common {
            inherit config name cfg;
            endpoints = lib.attrValues endpoints;
          })
          {
            services.llmhop.socketClients = [ cfg.user ];

            systemd.services.llmhop = {
              description = "llmhop model gateway";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              partOf = sockets;
              restartTriggers = [ (lib.toJSON cfg.listen) ];
              environment = util.resolveCredentialRefs util.credentialDirectory cfg.credentials cfg.environment;

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
                  EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
                  ExecStart = utils.escapeSystemdExecArgs [
                    (lib.getExe cfg.package)
                    "serve"
                    (configFile pkgs cfg.package cfg.settings)
                  ];
                  # The listeners arrive from `llmhop-<name>.socket`, so nothing
                  # is bound here.
                  Sockets = sockets;
                  UMask = "0077";
                  SystemCallFilter = baseServiceConfig.SystemCallFilter ++ [ "~@resources" ];
                };
            };
          }
        ]
      );
    };

  quadlet =
    sectionType:
    { config, pkgs, ... }:
    let
      name = "llmhop-quadlet";
      cfg = config.services.llmhop.gateway.${name};
      # Every endpoint, unlisted ones included, which it reaches on TCP only.
      endpoints = lib.attrValues config.services.llmhop.endpoints;
      package = config.services.llmhop.package;
      file = configFile pkgs package cfg.settings;
      # The image of the binary that validated `file`, unless `container.image` replaces it.
      archive = pkgs.callPackage ../../docker.nix {
        llmhop = package;
        stream = false;
      };
      sockets = socketUnits cfg;
    in
    {
      options.services.llmhop.gateway = {
        type = mkOption { type = types.nullOr (types.enum [ name ]); };
        ${name} =
          options config
          // gateway.containerOptions {
            inherit sectionType;
            displayName = "the llmhop gateway";
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
          };
      };
      config = lib.mkIf (config.services.llmhop.gateway.type == name) (
        lib.mkMerge [
          (common {
            inherit
              config
              name
              cfg
              endpoints
              ;
          })
          { assertions = gateway.tcpEndpointAssertions name endpoints; }
          (gateway.quadletContainer {
            inherit
              config
              name
              cfg
              unit
              ;
            image = if cfg.container.image == null then "docker-archive:${archive}" else cfg.container.image;
            imageTag = if cfg.container.image == null then "localhost/llmhop:${archive.imageTag}" else null;
            arguments = [
              "serve"
              containerConfigFile
            ];
            volumes = [ "${file}:${containerConfigFile}:ro" ];
            # The listeners arrive from `llmhop-<name>.socket`, which Podman
            # hands to the container.
            serviceConfig.Sockets = sockets;
          })
          {
            virtualisation.quadlet.containers.${unit} = {
              unitConfig.PartOf = sockets;
              # Pairs with the binary's sd_notify call, as natively.
              containerConfig.Notify = lib.mkDefault true;
            };
          }
          { virtualisation.quadlet.bundle.sockets = map socketUnit (lib.attrNames cfg.listen); }
        ]
      );
    };
}
