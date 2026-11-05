# Options and units shared by the gateways, each the one entry point routing
# the endpoints of every backend. See "Gateways" in the module internals
# documentation.
lib:
let
  inherit (lib) mkOption types;
  util = import ../lib.nix lib;
in
rec {
  # Option path of the gateway `name`, naming it in `services.llmhop.claims`.
  owner = name: "services.llmhop.gateway.${name}";

  # The endpoints an external gateway routes, in a stable order.
  listedEndpoints =
    config:
    lib.pipe config.services.llmhop.endpoints [
      lib.attrValues
      (lib.filter (e: !e.unlisted))
      (lib.sortOn (e: e.name))
    ];

  openFirewallOption = mkOption {
    type = types.bool;
    default = false;
    description = "Whether to open `port` in the host firewall, which requires a `host` other than loopback.";
  };

  # Options of every gateway, running `image` in a container.
  options =
    {
      config,
      sectionType,
      displayName,
      image,
    }:
    {
      runtime = util.runtimeOption config.services.llmhop.runtime;
      credentials = util.credentialsOption;
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Environment variables of ${displayName}. With `credentials`,
          `''${cred:<name>}` expands to the path of one of them.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr externalPath;
        default = null;
        description = ''
          File outside the Nix store in `KEY=VALUE` format, loaded by
          systemd or Podman and forwarded to ${displayName}.
        '';
      };
      container = {
        inherit image;
        config = util.containerConfigOption sectionType displayName;
        mountOptions.credentials = util.credentialMountOptionsOption displayName;
      };
    };

  # Options of every external gateway listening on TCP.
  tcpOptions = displayName: {
    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = "IP address ${displayName} listens on.";
    };
    port = mkOption {
      type = types.port;
      default = 8080;
      description = "TCP port ${displayName} listens on.";
    };
    openFirewall = openFirewallOption;
  };

  # Assertions that the gateway `name` routes `endpoints` on loopback only, and
  # reaches them on TCP while `tcp`.
  routeAssertions =
    {
      name,
      endpoints,
      tcp,
    }:
    lib.concatMap (
      e:
      [
        {
          assertion = !e.exposed;
          message = "services.llmhop: `${e.owner}` is routed by the gateway `${name}`, but binds a `host` beyond loopback, so clients could bypass the gateway.";
        }
      ]
      ++ lib.optional tcp {
        assertion = e.socket == null;
        message = "services.llmhop: `${e.owner}` is routed by the gateway `${name}`, but binds a unix socket, which the gateway cannot reach, so set its `port`.";
      }
    ) endpoints;

  # Configuration of the TCP gateway `name`, which routes `endpoints` and
  # binds `port`.
  tcpConfig =
    {
      name,
      cfg,
      endpoints,
    }:
    {
      assertions = [
        (util.firewallAssertion (owner name) cfg)
      ]
      ++ routeAssertions {
        inherit name endpoints;
        tcp = true;
      };
      services.llmhop.claims = {
        unit.${name} = [ (owner name) ];
        port.${toString cfg.port} = [ (owner name) ];
      };
      networking.firewall.allowedTCPPorts = lib.optional cfg.openFirewall cfg.port;
    };

  # The unit `name` of the gateway, which exits only on failure. Natively, it
  # is a hardened service running `command`, as a dynamic user unless
  # `serviceConfig` names one. In a container, it runs the `image` of `cfg`
  # unless `container.image` and `container.imageTag` replace it, with its
  # entrypoint unless `container.entrypoint` replaces it, followed by
  # `container.arguments`. A container runs on the host network, which reaches
  # every endpoint on loopback and binds its listener there directly. With
  # `credentials`, it runs as root to read their mount. `container.config` is
  # merged last and wins.
  unit =
    {
      config,
      utils,
      name,
      description,
      command,
      serviceConfig ? { },
      unitConfig ? { },
      container ? { },
    }:
    let
      cfg = config.services.llmhop.gateway.${name};
      spec = {
        inherit (cfg.container) image;
        imageTag = null;
        entrypoint = null;
        arguments = [ ];
        environment = { };
        volumes = [ ];
        serviceConfig = { };
        containerConfig = { };
      }
      // container;
      restart = {
        Restart = "on-failure";
        RestartSec = 5;
      };
      online = !util.isLoopback (cfg.host or "");
      imageUnit = util.imageUnit {
        inherit (config.virtualisation.quadlet) images;
        inherit name;
        inherit (spec) image;
        tag = spec.imageTag;
        owner = owner name;
      };
    in
    lib.mkMerge [
      (lib.mkIf (cfg.runtime == "native") {
        systemd.services.${name} = {
          inherit description;
          wantedBy = [ "multi-user.target" ];
          # It reaches every endpoint on loopback, so only a listener beyond it
          # waits for the network.
          wants = lib.optional online "network-online.target";
          after = [ "network.target" ] ++ lib.optional online "network-online.target";
          environment = util.resolveCredentialRefs util.credentialDirectory cfg.credentials cfg.environment;
          unitConfig = util.startLimitConfig // unitConfig;
          serviceConfig =
            util.hardenedServiceConfig
            // util.credentialServiceConfig cfg.credentials
            // restart
            // {
              DynamicUser = true;
              EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
              ExecStart = util.execStart utils cfg.credentials command;
              UMask = "0077";
            }
            // serviceConfig;
        };
      })
      (lib.mkIf (cfg.runtime == "quadlet") {
        services.llmhop.claims = imageUnit.claims;
        virtualisation.quadlet = {
          enable = true;
          inherit (imageUnit) images;
          containers.${name} = {
            unitConfig = lib.mkMerge [
              (util.startLimitConfig // imageUnit.unitConfig)
              unitConfig
            ];
            serviceConfig = util.credentialServiceConfig cfg.credentials // restart // spec.serviceConfig;
            containerConfig =
              util.baseContainerConfig
              // imageUnit.containerConfig
              // {
                Network = "host";
                Environment =
                  util.resolveCredentialRefs util.containerCredentialDirectory cfg.credentials cfg.environment
                  // util.credentialEnvironment cfg.credentials
                  // spec.environment;
                EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
                Volume =
                  spec.volumes ++ util.credentialMount cfg.container.mountOptions.credentials cfg.credentials;
              }
              // lib.optionalAttrs (spec.entrypoint != null) {
                Entrypoint = lib.toJSON [ spec.entrypoint ];
              }
              // lib.optionalAttrs (spec.arguments != [ ]) {
                Exec = lib.escapeShellArgs (
                  util.resolveCredentialRefs util.containerCredentialDirectory cfg.credentials spec.arguments
                );
              }
              # The credential mount belongs to host root, so the container
              # runs as root to read it, without any capability like every
              # backend, unless `container.config` maps another identity.
              // lib.optionalAttrs (cfg.credentials != { }) { User = "0:0"; }
              // spec.containerConfig
              // cfg.container.config;
          };
        };
      })
    ];
}
