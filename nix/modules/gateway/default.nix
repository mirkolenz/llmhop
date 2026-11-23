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
  inherit (import ./common.nix { inherit config lib; })
    util
    llmhop
    cfg
    owner
    workloads
    ;
  containerCredentials = util.containerCredentials llmhop cfg.credentials;

  # The socket units of the listeners, which the gateway service holds.
  socketUnit = listenerName: "llmhop-${listenerName}";
  socketUnits = map socketUnit (lib.attrNames cfg.listen);
  sockets = map (unit: "${unit}.socket") socketUnits;

  # A stable path, so a changed config reloads the native gateway in place,
  # where `llmhopctl` finds it in either runtime.
  etcConfigFile = "llmhop/config.json";
  configFile = "/etc/${etcConfigFile}";

  # `settings` without the options left `null`, while the nulls in the
  # metadata of a model are JSON values.
  settings = util.withoutNulls cfg.settings // {
    models = lib.mapAttrs (
      _: model:
      util.withoutNulls model // lib.optionalAttrs (model.metadata != null) { inherit (model) metadata; }
    ) cfg.settings.models;
  };
  # The config file of `settings`, validated by `package` itself, so a typo
  # fails the build instead of the service. Secret references stay
  # unexpanded, since what they name does not exist in a build sandbox.
  unchecked = (pkgs.formats.json { }).generate "llmhop.json" settings;
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
  # The replicas of every served name, in the order of their backends and
  # keys, and the model of the gateway that each of them describes.
  replicas = lib.groupBy (w: w.name) workloads;
  gatewayModel = w: {
    inherit (w) unlisted dataParallelSize aliases;
    inherit (util) healthPath;
  };
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
          assertion = cfg.listen != { };
          message = "services.llmhop: `${owner}.listen` has no listener, so nothing could reach the gateway.";
        }
      ]
      ++ lib.mapAttrsToList (
        listenerName: util.firewallAssertion "${owner}.listen.${listenerName}"
      ) tcpListeners
      ++ map (w: {
        assertion = !w.exposed;
        message = "services.llmhop: `${w.owner}` is routed by the gateway, but binds a `host` beyond loopback, so clients could bypass it.";
      }) workloads
      ++ lib.mapAttrsToList (name: ws: {
        assertion = lib.length (lib.unique (map gatewayModel ws)) == 1;
        message = "services.llmhop: the replicas ${
          lib.concatMapStringsSep ", " (w: "`${w.owner}`") ws
        } of `${name}` differ in their `aliases`, `dataParallelSize` or `unlisted`, which the gateway routes once per name.";
      }) replicas;

      services.llmhop = {
        gateway = {
          credentials = lib.mkIf (cfg.settings.clientCredentials == true) {
            "llmhop.api-key.*" = lib.mkDefault null;
          };
          # Every served name is probed by readiness, pinned to its ranks
          # and balanced over its replicas.
          settings.models = lib.mapAttrs (
            _: ws: gatewayModel (lib.head ws) // { urls = map util.probeUrl ws; }
          ) replicas;
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
        sockets = lib.mapAttrs' (
          listenerName: listener:
          lib.nameValuePair (socketUnit listenerName) {
            wantedBy = [ "sockets.target" ];
            listenStreams = [ (util.listenStream listener) ];
            socketConfig = {
              Service = "llmhop.service";
              FileDescriptorName = listenerName;
            }
            // lib.optionalAttrs (listener.port == null) {
              SocketUser = listener.socketUser;
              SocketGroup = listener.socketGroup;
              SocketMode = listener.socketMode;
              # Its socket listeners share the root of the worker sockets,
              # which anyone may pass but not list, also in a bundle that
              # has no tmpfiles. See "Unix sockets" in the module internals
              # documentation.
              DirectoryMode = "0711";
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
            environment = util.systemdEnvironment cfg.credentials cfg.environment;
            # A reload keeps the groups of the process, such as those of the
            # worker sockets.
            restartTriggers = [
              (lib.toJSON cfg.listen)
              (lib.toJSON config.users.users.${cfg.user}.extraGroups)
            ];
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
    # credentials of the start, so only a restart picks up new keys. An
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
              Exec = util.containerExec [
                "serve"
                containerConfigFile
              ];
              Environment = util.containerEnvironment (
                containerCredentials.resolve cfg.environment // containerCredentials.environment
              );
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
