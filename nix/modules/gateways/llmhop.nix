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
  # The socket units of the listeners, which the gateway service holds.
  socketUnits = map socketUnit (lib.attrNames cfg.listen);
  sockets = map (unit: "${unit}.socket") socketUnits;

  containerConfigFile = "${util.containerRuntimeDirectory}/llmhop.json";

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
          models."openai/gpt-4".url = "https://api.openai.com";
        };
        description = ''
          llmhop's JSON config, validated at build time by the binary itself,
          with every endpoint of the backends as a model. Its listeners come
          from `listen`, so `settings` must not set it.
        '';
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
              };
            }
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

  config = lib.mkIf (config.services.llmhop.gateway.type == name) (
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
        # A container reaches the endpoints on TCP only.
        ++ gateway.routeAssertions {
          inherit name endpoints;
          tcp = !native;
        };

        services.llmhop = {
          gateway.${name} = {
            listen.default.port = lib.mkDefault 8080;
            # Every endpoint is probed by readiness.
            settings.models = lib.genAttrs' endpoints (
              endpoint:
              lib.nameValuePair endpoint.name {
                inherit (endpoint) url unlisted;
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
          file
        ];
        # Tighter than the worker baseline: `@resources` syscalls are blocked
        # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited
        # baseline for the sd_notify datagram and the worker sockets. Named,
        # not `DynamicUser`, so the sockets' ACL can grant this user alone.
        # Never give it a `RuntimeDirectory=` of `socketDirectory`: stopping
        # llmhop would delete every socket. Its `Type=notify` pairs with the
        # binary's sd_notify call: the unit reaches `active` only once llmhop
        # serves, so anything ordered after it can assume it answers. The
        # listeners arrive from `llmhop-<name>.socket`, so nothing is bound
        # here.
        serviceConfig = baseServiceConfig // {
          DynamicUser = false;
          Type = "notify";
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
          # binary's sd_notify call as natively.
          serviceConfig.Sockets = sockets;
          containerConfig.Notify = true;
        };
      })
      (lib.mkIf native (
        lib.mkMerge [
          {
            services.llmhop.socketClients = [ cfg.user ];
            systemd.services.${name}.restartTriggers = [ (lib.toJSON cfg.listen) ];
          }
          (util.identityConfig { inherit name cfg; })
        ]
      ))
      (lib.mkIf (!native) { virtualisation.quadlet.bundle.sockets = socketUnits; })
    ]
  );
}
