# The config of the Quadlet containers of a backend, each workload running
# the backend's image on its published loopback port, downloading what it
# serves into its own Podman volume at `cache`.
{
  lib,
  engine,
  llmhop,
  cfg,
  workloads,
  ...
}:
let
  util = import ../lib lib;
  wl = import ./workload lib;
  cache = "/var/cache/llmhop";

  containers =
    workload: after:
    let
      credentials = util.containerCredentials llmhop workload.credentials;
    in
    {
      ${workload.unit} = {
        # Podman stops the server, and systemd Podman.
        serviceConfig = wl.serverServiceConfig cfg workload // {
          TimeoutStopSec = wl.stopTimeout cfg + 10;
        };
        unitConfig = util.startLimitConfig // {
          Wants = after;
          After = after;
        };
        containerConfig =
          util.baseContainerConfig llmhop
          // util.autoUpdate cfg.container.image
          // {
            Image = cfg.container.image;
            Entrypoint = lib.toJSON workload.command;
            Exec = lib.escapeShellArgs (util.renderCliArgs engine (credentials.resolve workload.settings));
            Notify = "healthy";
            StopTimeout = wl.stopTimeout cfg;
            HealthCmd = "curl --fail --silent --show-error http://127.0.0.1:${toString workload.port}${util.healthPath}";
            HealthStartPeriod = "30m";
            HealthInterval = "10s";
            HealthTimeout = "5s";
            PublishPort = [ "${util.hostPort workload.host workload.port}:${toString workload.port}" ];
            # Its named volume, created on first use, holds every cache.
            Volume = [
              "${workload.unit}:${cache}${util.mountSuffix (util.idmap llmhop)}"
            ]
            ++ workload.mounts
            ++ credentials.volumes;
            EnvironmentFile = wl.environmentFiles cfg workload;
            Environment =
              wl.serverEnvironment {
                inherit
                  engine
                  cfg
                  workload
                  cache
                  ;
                inherit (credentials) resolve;
              }
              // credentials.environment;
          }
          // lib.optionalAttrs (workload.gpu != null) {
            AddDevice = workload.gpu.containerDevices;
            ShmSize = workload.gpu.shmSize;
            Ulimit = "host";
          }
          // llmhop.container.config;
      };
    };
in
lib.mkIf (workloads != [ ]) {
  virtualisation.quadlet = {
    enable = true;
    containers = wl.chain cfg.startupOrdering workloads containers;
  };
}
