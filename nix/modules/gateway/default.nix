# llmhop in front of every workload of every backend under
# `services.llmhop.gateway`, listening on the sockets of its `listen` units,
# natively or in a container on the host network, which reaches every
# workload on loopback. Its options are in `options.nix`.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  util = import ../lib lib;
  wl = import ../backends/workload lib;
  llmhop = config.services.llmhop;
  cfg = llmhop.gateway;
  owner = "services.llmhop.gateway";

  workloads = wl.allWorkloads llmhop;
  containerCredentials = util.containerCredentials llmhop cfg.credentials;

  # The socket units of the listeners, which the gateway service holds.
  socketUnit = listenerName: "llmhop-${listenerName}";
  socketUnits = map socketUnit (lib.attrNames cfg.listen);
  sockets = map (unit: "${unit}.socket") socketUnits;

  # A stable path, so a changed config reloads the native gateway in place,
  # where `llmhopctl` finds it in either runtime.
  etcConfigFile = "llmhop/config.json";
  configFile = "/etc/${etcConfigFile}";

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

  restart = {
    Restart = "on-failure";
    RestartSec = 5;
  };

  tcpListeners = lib.filterAttrs (_: listener: listener.port != null) cfg.listen;
  trustedListeners = lib.filterAttrs (_: listener: listener.trusted) cfg.listen;
  # The glob of credentials loaded as auth tokens, imported from the system
  # credential store.
  tokenCredentials = cfg.settings.authTokenCredentials or null;
  baseServiceConfig = util.accountServiceConfig cfg;
  containerConfigFile = "${util.containerRuntimeDirectory}/llmhop.json";
  # The image of the binary that validated `file`, unless `container.image`
  # replaces it.
  archive = pkgs.callPackage ../../docker.nix {
    llmhop = cfg.package;
    stream = false;
  };
  image = config.virtualisation.quadlet.images.llmhop;
in
{
  imports = [ ./options.nix ];

  config = lib.mkMerge [
    (lib.mkIf cfg.active {
      assertions = [
        {
          assertion = !cfg.settings ? listen;
          message = "services.llmhop: `${owner}.settings` sets `listen`, which the sockets of `${owner}.listen` replace.";
        }
      ]
      ++ lib.mapAttrsToList (
        listenerName: util.firewallAssertion "${owner}.listen.${listenerName}"
      ) tcpListeners
      ++ lib.mapAttrsToList (listenerName: _: {
        assertion = false;
        message = "services.llmhop: `${owner}.listen.${listenerName}` is trusted, which only a unix socket may be, so unset `port`.";
      }) (lib.intersectAttrs trustedListeners tcpListeners)
      ++ map (w: {
        assertion = !w.exposed;
        message = "services.llmhop: `${w.owner}` is routed by the gateway, but binds a `host` beyond loopback, so clients could bypass it.";
      }) workloads
      ++ lib.optional (tokenCredentials != null) {
        # Any other credential matching the glob would become a client token.
        assertion = lib.all (
          credential:
          credential == tokenCredentials || !lib.hasPrefix (lib.removeSuffix "*" tokenCredentials) credential
        ) (lib.attrNames cfg.credentials);
        message = "services.llmhop: `${owner}.credentials` names a credential matching `settings.authTokenCredentials`, which would make it a client token.";
      };

      services.llmhop = {
        gateway = {
          listen.default.port = lib.mkDefault 8080;
          credentials = lib.mkIf (tokenCredentials != null) {
            ${tokenCredentials} = lib.mkDefault null;
          };
          settings.trustedSockets = lib.mkIf (trustedListeners != { }) (
            lib.mapAttrs (_: listener: listener.socket) trustedListeners
          );
          # Every workload is probed by readiness, and pinned to its ranks.
          settings.models = lib.genAttrs' workloads (
            w:
            lib.nameValuePair w.name {
              urls = [ (util.probeUrl w) ];
              inherit (w) unlisted dataParallelSize;
              aliases = lib.mapAttrs (_: model: lib.optionalAttrs (model != null) { inherit model; }) w.aliases;
              inherit (util) healthPath;
            }
          );
        };
        claims = {
          unit.llmhop = [ owner ];
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
        )) (util.rootDirectoryRule llmhop.socketDirectory);

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
      };
    })

    # Tighter than the worker baseline: `@resources` syscalls are blocked
    # (no setrlimit/setpriority). `AF_UNIX` stays in the inherited baseline
    # for the sd_notify datagram and the worker sockets. Named, not
    # `DynamicUser`, so it joins the groups owning the worker sockets.
    # Never give it a `RuntimeDirectory=` of `socketDirectory`: stopping
    # llmhop would delete every socket. Its `Type=notify-reload` pairs with
    # the binary's sd_notify calls: the unit reaches `active` only once
    # llmhop serves, so anything ordered after it can assume it answers, and
    # a reload re-imports the credentials, then waits until llmhop reloaded
    # its config. The listeners arrive from `llmhop-<name>.socket`, so
    # nothing is bound here.
    (lib.mkIf (cfg.active && llmhop.runtime == "native") (
      lib.mkMerge [
        {
          services.llmhop.socketClients = [ cfg.user ];
          systemd.services.llmhop = {
            description = "llmhop model gateway";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            environment = util.resolveCredentialRefs util.credentialDirectory cfg.credentials cfg.environment;
            restartTriggers = [ (lib.toJSON cfg.listen) ];
            reloadTriggers = [ file ];
            unitConfig = util.startLimitConfig // {
              PartOf = sockets;
            };
            serviceConfig =
              baseServiceConfig
              // util.credentialServiceConfig cfg.credentials
              // restart
              // {
                Type = "notify-reload";
                RefreshOnReload = "credentials";
                Sockets = sockets;
                SystemCallFilter = baseServiceConfig.SystemCallFilter ++ [ "~@resources" ];
                EnvironmentFile = util.environmentFiles [ cfg ];
                ExecStart = utils.escapeSystemdExecArgs [
                  (lib.getExe cfg.package)
                  "serve"
                  configFile
                ];
                UMask = "0077";
              };
          };
        }
        (util.identityConfig {
          name = "llmhop";
          inherit cfg;
        })
      ]
    ))

    # Podman hands the sockets to the container, which pairs with the
    # binary's sd_notify call as natively. Its credential mount keeps the
    # credentials of the start, so only a restart picks up new tokens. An
    # archive loads through the image unit, which restarts the gateway with
    # it.
    (lib.mkIf (cfg.active && llmhop.runtime == "container") {
      services.llmhop.claims.unit = lib.mkIf (cfg.container.image == null) {
        ${image.serviceName} = [ owner ];
      };
      virtualisation.quadlet = {
        enable = true;
        images.llmhop = lib.mkIf (cfg.container.image == null) {
          imageConfig = {
            Image = "docker-archive:${archive}";
            ImageTag = "localhost/llmhop:${archive.imageTag}";
          };
        };
        containers.llmhop = {
          unitConfig = util.startLimitConfig // {
            PartOf = sockets ++ lib.optional (cfg.container.image == null) "${image.serviceName}.service";
          };
          serviceConfig = util.credentialServiceConfig cfg.credentials // restart // { Sockets = sockets; };
          containerConfig =
            util.baseContainerConfig llmhop
            // (
              if cfg.container.image == null then
                {
                  Image = image.ref;
                  Pull = "never";
                }
              else
                { Image = cfg.container.image; } // util.autoUpdate cfg.container.image
            )
            // {
              Network = "host";
              Notify = true;
              Exec = lib.escapeShellArgs [
                "serve"
                containerConfigFile
              ];
              Environment = containerCredentials.resolve cfg.environment // containerCredentials.environment;
              EnvironmentFile = util.environmentFiles [ cfg ];
              Volume = [
                "${file}:${containerConfigFile}:ro"
              ]
              ++ containerCredentials.volumes;
            }
            # The credential mount belongs to host root, so the container
            # runs as its root to read it, without any capability.
            // lib.optionalAttrs (cfg.credentials != { }) { User = "0:0"; }
            // llmhop.container.config;
        };
        bundle.sockets = socketUnits;
      };
    })
  ];
}
