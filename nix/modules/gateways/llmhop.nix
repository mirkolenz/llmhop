# llmhop in front of every endpoint under `services.llmhop.gateway.llmhop`,
# listening on the sockets of its `listen` units. Natively, it is the only
# gateway reaching unix sockets.
sectionType:
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
  gateway = import ./shared.nix lib;

  name = "llmhop";
  owner = gateway.owner name;
  cfg = config.services.llmhop.gateway.${name};
  native = cfg.runtime == "native";
  # Every endpoint, unlisted ones included.
  endpoints = lib.attrValues config.services.llmhop.endpoints;
  tcpListeners = lib.filterAttrs (_: listener: listener.port != null) cfg.listen;
  trustedListeners = lib.filterAttrs (_: listener: listener.trusted) cfg.listen;
  # The socket units of the listeners, which the gateway service holds.
  socketUnits = map socketUnit (lib.attrNames cfg.listen);
  sockets = map (unit: "${unit}.socket") socketUnits;

  containerConfigFile = "${util.containerRuntimeDirectory}/llmhop.json";
  # A stable path, so a changed config reloads the native gateway in place,
  # where `llmhopctl` finds it on either runtime.
  etcConfigFile = "${name}/config.json";
  configFile = "/etc/${etcConfigFile}";

  # The glob of credentials loaded as auth tokens, imported from the system
  # credential store.
  tokenCredentials = cfg.settings.authTokenCredentials or null;

  # The socket unit of the listener `listenerName`.
  socketUnit = listenerName: "llmhop-${listenerName}";

  # The config file of `settings`, validated by `package` itself, so a typo
  # fails the build instead of the service. Secret references stay
  # unexpanded, since what they name does not exist in a build sandbox.
  unchecked = (pkgs.formats.json { }).generate "llmhop.json" cfg.settings;
  file =
    if pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform then
      pkgs.runCommandLocal "llmhop.json" { } ''
        ${lib.getExe cfg.package} check ${unchecked}
        cp ${unchecked} $out
      ''
    else
      unchecked;
  # The image of the binary that validated `file`, unless `container.image` replaces it.
  archive = pkgs.callPackage ../../docker.nix {
    llmhop = cfg.package;
    stream = false;
  };
  baseServiceConfig = util.accountServiceConfig cfg;
in
{
  options.services.llmhop.gateway.${name} =
    gateway.options {
      inherit config sectionType;
      displayName = "the llmhop gateway";
      image = util.imageOption // {
        type = with types; nullOr str;
        default = null;
        example = "ghcr.io/mirkolenz/llmhop:latest";
        description = ''
          Container image reference, including a tag or digest, or `null`
          for an archive of `package`, which validated the config at build
          time and never auto-updates.
          Only used if `runtime` is `"quadlet"`.
        '';
      };
    }
    // util.identityOptions {
      inherit name cfg;
      prefix = owner;
      runsAs = "the gateway runs as";
      nativeOnly = true;
    }
    // {
      package = lib.mkPackageOption pkgs "llmhop" { } // {
        default = config.services.llmhop.package;
        defaultText = lib.literalExpression "config.services.llmhop.package";
      };
      credentials = util.credentialsOption // {
        description = util.credentialsOption.description + ''

          llmhop reads its own config, so in `settings` the reference expands
          to the credential's contents rather than to its path.
        '';
      };
      settings = mkOption {
        type = with types; attrsOf json;
        default = { };
        example = {
          authTokens.client = "\${cred:llmhop.client-token}";
          models."openai/*".urls = [ "https://api.openai.com" ];
        };
        description = ''
          llmhop's JSON config, validated at build time by the binary itself,
          with every endpoint of the backends as a model. Its listeners come
          from `listen`, so `settings` must not set it.
        '';
      };
      ctl = {
        enable =
          lib.mkEnableOption "`llmhopctl`, which manages the client tokens of `settings.authTokenCredentials`"
          // {
            default = true;
          };
        package = mkOption {
          type = types.package;
          default = pkgs.callPackage ../../pkgs/llmhopctl/package.nix { };
          defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/llmhopctl/package.nix { }";
          description = "The `llmhopctl` package, which reads the gateway's config from `${configFile}`.";
        };
      };
      listen = mkOption {
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            {
              options = {
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
                  default = "${config.services.llmhop.socketDirectory}/${name}.sock";
                  defaultText = lib.literalExpression ''"''${config.services.llmhop.socketDirectory}/${name}.sock"'';
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
                trusted = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Whether requests on `socket` need no token and count as the client
                    named after the listener, since `socketUser`, `socketGroup` and
                    `socketMode` decide who may connect. Browsers must send same-origin
                    requests to a loopback host, so web pages cannot use a port forward
                    of it. Requires `settings.authTokens` or `settings.authTokenCredentials`.
                  '';
                };
              };
            }
          )
        );
        default = { };
        example = {
          default.host = "";
          caddy.socketGroup = "caddy";
          ssh = {
            socketGroup = "wheel";
            trusted = true;
          };
        };
        description = ''
          Listeners of the gateway, each a `llmhop-<name>.socket` unit handing
          its socket to it through socket activation. The `default` one always
          exists, on port `8080` unless configured otherwise.
        '';
      };
    };

  config = lib.mkIf (gateway.enabled config name) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = !cfg.settings ? listen;
            message = "services.llmhop: `${owner}.settings` sets `listen`, which the sockets of `${owner}.listen` replace.";
          }
        ]
        ++ lib.mapAttrsToList (
          listenerName: util.firewallAssertion "${owner}.listen.${listenerName}"
        ) tcpListeners
        ++ lib.mapAttrsToList (listenerName: listener: {
          assertion = listener.port == null;
          message = "services.llmhop: `${owner}.listen.${listenerName}` is trusted, which only a unix socket may be, so unset `port`.";
        }) trustedListeners
        # A container reaches the endpoints on TCP only.
        ++ gateway.routeAssertions {
          inherit name endpoints;
          tcp = !native;
        };

        services.llmhop = {
          gateway.${name} = {
            listen.default.port = lib.mkDefault 8080;
            settings.trustedSockets = lib.mkIf (trustedListeners != { }) (
              lib.mapAttrs (_: listener: listener.socket) trustedListeners
            );
            # Every endpoint is probed by readiness.
            settings.models = lib.genAttrs' endpoints (
              endpoint:
              lib.nameValuePair endpoint.name {
                urls = [ endpoint.url ];
                inherit (endpoint) unlisted aliases dataParallelSize;
                inherit (util) healthPath;
              }
            );
          };
          claims = {
            unit.${name} = [ owner ];
            port = lib.mkMerge (
              lib.mapAttrsToList (listenerName: listener: {
                ${toString listener.port} = [ "${owner}.listen.${listenerName}" ];
              }) tcpListeners
            );
          };
        };

        environment.etc.${etcConfigFile}.source = file;
        environment.systemPackages = lib.mkIf cfg.ctl.enable [ cfg.ctl.package ];

        networking.firewall.allowedTCPPorts = lib.pipe tcpListeners [
          lib.attrValues
          (lib.filter (listener: listener.openFirewall))
          (lib.catAttrs "port")
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
              # `ListenStream=` takes IP literals only.
              listenStreams = [
                (
                  if listener.port == null then
                    listener.socket
                  else if listener.host == "" then
                    toString listener.port
                  else
                    util.hostPort listener.host listener.port
                )
              ];
              socketConfig = {
                Service = "${name}.service";
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
      }
      (gateway.unit {
        inherit config utils name;
        description = "llmhop model gateway";
        command = [
          (lib.getExe cfg.package)
          "serve"
          configFile
        ];
        # Tighter than the worker baseline: `@resources` syscalls are blocked
        # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited
        # baseline for the sd_notify datagram and the worker sockets. Named,
        # not `DynamicUser`, so the sockets' ACL can grant this user alone.
        # Never give it a `RuntimeDirectory=` of `socketDirectory`: stopping
        # llmhop would delete every socket. Its `Type=notify-reload` pairs with
        # the binary's sd_notify calls: the unit reaches `active` only once
        # llmhop serves, so anything ordered after it can assume it answers,
        # and a reload re-imports the credentials, then waits until llmhop
        # reloaded its config. The listeners arrive from
        # `llmhop-<name>.socket`, so nothing is bound here.
        serviceConfig = baseServiceConfig // {
          DynamicUser = false;
          Type = "notify-reload";
          RefreshOnReload = "credentials";
          Sockets = sockets;
          SystemCallFilter = baseServiceConfig.SystemCallFilter ++ [ "~@resources" ];
        };
        unitConfig.PartOf = sockets;
        container = {
          image = if cfg.container.image == null then "docker-archive:${archive}" else cfg.container.image;
          imageTag = if cfg.container.image == null then "localhost/llmhop:${archive.imageTag}" else null;
          arguments = [
            "serve"
            containerConfigFile
          ];
          volumes = [ "${file}:${containerConfigFile}:ro" ];
          # Podman hands the sockets to the container, which pairs with the
          # binary's sd_notify call as natively. Its credential mount keeps the
          # credentials of the start, so only a restart picks up new tokens.
          serviceConfig.Sockets = sockets;
          containerConfig.Notify = true;
        };
      })
      (lib.mkIf native (
        lib.mkMerge [
          {
            services.llmhop.socketClients = [ cfg.user ];
            systemd.services.${name} = {
              restartTriggers = [ (lib.toJSON cfg.listen) ];
              reloadTriggers = [ file ];
            };
          }
          (util.identityConfig { inherit name cfg; })
        ]
      ))
      (lib.mkIf (!native) { virtualisation.quadlet.bundle.sockets = socketUnits; })
      (lib.mkIf (tokenCredentials != null) {
        assertions = [
          {
            # Any other credential matching the glob would become a client token.
            assertion = lib.all (
              credential:
              credential == tokenCredentials || !lib.hasPrefix (lib.removeSuffix "*" tokenCredentials) credential
            ) (lib.attrNames cfg.credentials);
            message = "services.llmhop: `${owner}.credentials` names a credential matching `settings.authTokenCredentials`, which would make it a client token.";
          }
        ];
        services.llmhop.gateway.${name}.credentials.${tokenCredentials} = lib.mkDefault null;
      })
    ]
  );
}
