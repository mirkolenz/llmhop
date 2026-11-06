# The Quadlet containers of the backend `backend` of `common.nix`, each workload
# and its fetcher running in the backend's image.
{
  backend,
  config,
  lib,
}:
let
  util = import ../lib.nix lib;
  inherit (backend)
    name
    engine
    owner
    cfg
    socketUMask
    cacheDirectory
    hubDirectories
    fetches
    fetchUnit
    fetchServices
    fetchOrder
    fetch
    serverServiceConfig
    serverEnvironment
    environmentFiles
    credentialDirectory
    workloads
    ;

  # The image unit `<name>-image`, shared by every container, unless they
  # reference the image directly.
  image = util.containerImage {
    inherit (config.virtualisation.quadlet) images;
    inherit name owner;
    inherit (cfg.container) image;
    unit = cfg.container.imageUnit;
  };
  fetchScriptPath = "${util.containerRuntimeDirectory}/fetch.sh";

  # The containers of `workload`, those of `services` in the backend's image.
  containers =
    workload: after:
    let
      inherit (workload) unit listener;
      cacheMount =
        source: target: options:
        "${source}:${target}${util.mountSuffix (options ++ cfg.container.mountOptions.cache)}";
      # The host directory at the same path, or else the named volume.
      cacheSource = if cfg.cache.directory == null then unit else cacheDirectory workload;
      cache = cacheMount cacheSource (cacheDirectory workload) [ ];
      fetcher = fetch workload;
      credentials = util.credentialMount cfg.container.mountOptions.credentials;
      healthTarget =
        if listener.socket != null then
          "--unix-socket ${lib.escapeShellArg listener.socket} http://localhost${util.healthPath}"
        else
          "${util.probeUrl listener}${util.healthPath}";
      # A socket in a mounted directory and, offline, no network, or else the
      # published port.
      network =
        if workload.socket != null then
          {
            # Quadlet's own `Umask=` is newer than podman 6.1.
            PodmanArgs = [ "--umask=${socketUMask}" ];
          }
          // lib.optionalAttrs workload.offline { Network = "none"; }
        else
          {
            PublishPort = [ "${util.hostPort workload.host workload.port}:${toString listener.port}" ];
          };
    in
    {
      ${unit} = {
        serviceConfig = serverServiceConfig workload;
        unitConfig =
          util.startLimitConfig
          // image.unitConfig
          // {
            Wants = fetchServices workload;
            After = fetchOrder workload ++ after;
          };
        containerConfig =
          util.baseContainerConfig
          // image.containerConfig
          // {
            Entrypoint = lib.toJSON workload.command;
            Notify = "healthy";
            HealthCmd = "curl --fail --silent --show-error ${healthTarget}";
            HealthStartPeriod = "30m";
            HealthInterval = "10s";
            HealthTimeout = "5s";
            # The server only reads the hub cache. `U` hands the socket
            # directory to whatever host UID the container user maps to, so
            # the socket works under any `User=` and `UserNS=`.
            Volume = [
              cache
            ]
            ++ map (directory: cacheMount directory directory [ "ro" ]) (hubDirectories workload)
            ++ workload.mounts
            ++ lib.optional (
              workload.socket != null
            ) "${dirOf workload.socket}:${util.containerSocketDirectory}:U"
            ++ credentials workload.credentials;
            EnvironmentFile = environmentFiles workload;
            Environment =
              serverEnvironment workload engine.quadlet.environment
              // util.credentialEnvironment workload.credentials;
            Exec = lib.escapeShellArgs (
              util.renderCliArgs engine (
                util.resolveCredentialRefs credentialDirectory workload.credentials workload.settings
              )
            );
          }
          // network
          // lib.optionalAttrs (workload.kind == "model") {
            AddDevice = workload.container.devices;
            ShmSize = workload.container.shmSize;
            Ulimit = "host";
          }
          // cfg.container.config;
      };
    }
    // lib.optionalAttrs (fetches workload) {
      ${fetchUnit workload} = {
        inherit (fetcher) serviceConfig;
        unitConfig = image.unitConfig // fetcher.unitConfig;
        containerConfig =
          util.baseContainerConfig
          // image.containerConfig
          // {
            AutoUpdate = "disabled";
            Entrypoint = lib.toJSON [
              "/bin/sh"
              fetchScriptPath
            ];
            Volume = [
              cache
              "${lib.toFile "fetch.sh" fetcher.script}:${fetchScriptPath}:ro"
            ]
            ++ credentials cfg.fetch.credentials;
            EnvironmentFile = fetcher.environmentFile;
            Environment = fetcher.environment // util.credentialEnvironment cfg.fetch.credentials;
          }
          // cfg.container.config;
      };
    };
in
{
  config = lib.mkIf (cfg.enable && !backend.native && workloads != [ ]) {
    services.llmhop.claims = image.claims;
    virtualisation.quadlet = {
      enable = true;
      inherit (image) images;
      containers = backend.chain containers;
      bundle.services = lib.attrNames backend.maintenanceServices;
    };
  };
}
