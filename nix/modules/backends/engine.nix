# The options and the shared configuration of the backend of the engine
# `name` under `services.llmhop.<name>`, whose units `native.nix` and
# `container.nix` define for its `runtime`.
sectionType: engine:
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
  wl = import ./workload.nix lib;
  llmhop = config.services.llmhop;
  inherit (engine) name;
  backend = import ./common.nix {
    inherit
      config
      lib
      pkgs
      utils
      engine
      ;
  };
  inherit (backend)
    owner
    cfg
    native
    cacheDirectory
    hubDirectories
    workloads
    fetchers
    workloadClaims
    ;
  inherit (engine.native) uv;
in
{
  imports = [
    (lib.modules.importApply ./native.nix {
      inherit
        backend
        config
        lib
        pkgs
        utils
        ;
    })
    (lib.modules.importApply ./container.nix { inherit backend config lib; })
  ];

  options.services.llmhop.${name} =
    util.identityOptions {
      inherit name cfg;
      prefix = owner;
      user = if native then name else "root";
      userText = lib.literalExpression ''if config.${owner}.runtime == "native" then "${name}" else "root"'';
      group = if native then cfg.user else "root";
      groupText = lib.literalExpression ''if config.${owner}.runtime == "native" then config.${owner}.user else "root"'';
    }
    // {
      enable = lib.mkEnableOption "${engine.displayName} model serving";
      runtime = util.runtimeOption llmhop.runtime;
      package =
        if uv then
          mkOption {
            type = types.package;
            description = ''
              Package providing ${engine.native.packageEntry}, built from
              a uv workspace with the flake's `mkUvEnv`, as in
              `inputs.llmhop.legacyPackages.''${pkgs.stdenv.hostPlatform.system}.mkUvEnv { workspaceRoot = ./${name}-env; }`.
              Only used if `runtime` is `"native"`.
            '';
          }
        else
          lib.mkPackageOption pkgs name { }
          // {
            description = "The ${name} package. Only used if `runtime` is `\"native\"`.";
          };
      fetch = {
        enable = lib.mkEnableOption "the fetchers" // {
          default = true;
          description = ''
            Whether every workload has a fetcher `<unit>-fetch` downloading
            its repositories before its server starts, with a refresh unit and
            `${name}-update`, after which the server runs offline. Otherwise
            each server downloads its repositories itself when it starts, which
            requires `offline = false`, and none of the other `fetch` options
            apply.
          '';
        };
        schedule = mkOption {
          type = with types; nullOr str;
          default = "weekly";
          example = "daily";
          description = ''
            `OnCalendar=` schedule of `${name}-update`, which runs every
            fetcher and restarts each running server after a successful fetch,
            even if its model did not change.
            `null` disables scheduled fetching.
          '';
        };
        environment = mkOption {
          type = with types; attrsOf str;
          default = { };
          example.HTTPS_PROXY = "http://proxy.example:3128";
          description = ''
            Environment variables set on every fetcher, such as a proxy. Values
            may reference `fetch.credentials` as `''${cred:<name>}`.
            The servers never see them.
          '';
        };
        environmentFile = mkOption {
          type = with types; nullOr externalPath;
          default = null;
          description = ''
            File in `KEY=VALUE` format forwarded to every fetcher, for
            variables that only exist as values.
          '';
        };
        hfTokenCredential = mkOption {
          type = with types; nullOr str;
          default = null;
          example = "llmhop.hf-token";
          description = ''
            Credential holding a Hugging Face token for gated repositories,
            imported from the system credential store unless
            `fetch.credentials` names a file for it. Only the fetchers receive
            it, as `HF_TOKEN`, and skip it while it is missing.
          '';
        };
        credentials = util.credentialsOption // {
          description = ''
            Credentials granted to every fetcher, in the format of a
            workload's `credentials`. Reference them from `fetch.environment`
            as `''${cred:<name>}`.
          '';
        };
      };
      cache.directory = mkOption {
        type = with types; nullOr externalPath;
        default = backend.defaultCacheDirectory;
        description = ''
          Root of the cache directories of this backend's workloads, created
          with mode `0711`, each `<name>` the `HF_HOME` of one fetcher and its
          server, created with mode `0700` for `user` and `group`. The
          fetcher writes its `hub/`, which the server only reads. Point it at
          a data disk for large models.
          `null` keeps each cache in the Podman named volume `<unit>` instead,
          which needs no tmpfiles rules but only works for a container backend
          without `fetch.enable`.
        '';
      };
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Environment variables set on every model service, under the
          `environment` of each model, where `''${cred:<name>}` expands to the
          path of a credential.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr externalPath;
        default = null;
        example = "/etc/${name}/.env";
        description = ''
          File in `KEY=VALUE` format forwarded to every server, loaded before
          the `environmentFile` of each model. Prefer `credentials` for any
          secret a server can read from a file.
        '';
      };
      modelSettings = mkOption {
        type = with types; attrsOf json;
        default = { };
        description = ''
          CLI flags forwarded to the server of every model, under the
          `settings` of each model.
          ${wl.settingsRendering engine}
        '';
      };
      openFilesLimit = mkOption {
        type = types.ints.positive;
        default = 1048576;
        description = ''
          File descriptor limit (`LimitNOFILE`) of every server of this
          backend. Increase it if a server logs `accept: Too many open files`.
        '';
      };
      startupOrdering = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to start model services one at a time by ascending `name`,
          so two workers profiling memory on the same GPU do not race into an
          OOM. Disable only when each model pins itself to a dedicated device,
          natively via its own `native.devices` or `environment`, e.g.
          `CUDA_VISIBLE_DEVICES`, or in a container via its own
          `container.devices`.
        '';
      };
      native.devices = mkOption {
        type = with types; nullOr (listOf str);
        default = null;
        example = [
          "/dev/nvidiactl"
          "char-nvidia-uvm"
          "/dev/nvidia0"
        ];
        description = ''
          Devices every model service may access as systemd `DeviceAllow=`
          entries under `DevicePolicy=closed`, while `null` allows all.
          Per-model `native.devices` replaces it.
          Only used if `runtime` is `"native"`.
        '';
      };
      container = {
        image = util.imageOption // {
          example = engine.quadlet.imageExample;
        };
        imageUnit = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether every container runs `image` through the image unit
            `${name}-image`, which pulls it once for all of them and restarts
            them when restarted. Otherwise each container references `image`
            directly and pulls it while it is missing.
            Only used if `runtime` is `"quadlet"`.
          '';
        };
        config = util.containerConfigOption sectionType "this backend, servers, fetchers and detectors alike";
        devices = mkOption {
          type = with types; listOf str;
          default =
            if config.hardware.nvidia-container-toolkit.enable or false then [ "nvidia.com/gpu=all" ] else [ ];
          defaultText = lib.literalExpression ''
            if config.hardware.nvidia-container-toolkit.enable then [ "nvidia.com/gpu=all" ] else [ ]
          '';
          example = [ "amd.com/gpu=all" ];
          description = ''
            Devices exposed to every model container as Quadlet `AddDevice=`
            lines, CDI references such as `nvidia.com/gpu=all` or host device
            paths. Per-model `container.devices` replaces it.
            Only used if `runtime` is `"quadlet"`.
          '';
        };
        mountOptions = {
          cache = mkOption {
            type = with types; listOf str;
            default = [ ];
            example = [ "idmap" ];
            description = ''
              Podman volume options of the cache mounts below
              `cache.directory`, such as `idmap` so a user namespace owns
              them, or SELinux relabeling.
              Only used if `runtime` is `"quadlet"`.
            '';
          };
          credentials = util.credentialMountOptionsOption "this backend";
        };
      };
      models = mkOption {
        type = types.attrsOf (
          types.submodule [
            (wl.workloadModule {
              inherit engine;
              inherit (cfg) runtime;
              inherit (llmhop) socketDirectory;
              fetch = cfg.fetch.enable;
              kind = "model";
              derivedSettings = engine.modelSettings;
              defaults = cfg.modelSettings;
            })
            (wl.modelModule {
              inherit engine;
              requiredRepositories = lib.optionals native engine.native.repositories;
            })
            (
              { config, ... }:
              {
                options = {
                  package = mkOption {
                    type = types.package;
                    default = cfg.package;
                    defaultText = lib.literalExpression "config.${owner}.package";
                    description = ''
                      Package providing this model's server, overriding the
                      backend-wide `package`, e.g. a nightly build for a
                      just-released architecture.
                      Only used if the backend's `runtime` is `"native"`.
                    '';
                  };
                  native.devices = mkOption {
                    type = with types; nullOr (listOf str);
                    default = cfg.native.devices;
                    defaultText = lib.literalExpression "config.${owner}.native.devices";
                    example = [ "/dev/nvidia0" ];
                    description = "Devices this model's service may access, replacing the backend's `native.devices`. Only used if the backend's `runtime` is `\"native\"`.";
                  };
                  container = {
                    devices = mkOption {
                      type = with types; listOf str;
                      default = cfg.container.devices;
                      defaultText = lib.literalExpression "config.${owner}.container.devices";
                      example = [ "nvidia.com/gpu=0" ];
                      description = "Devices exposed to this model's container, replacing the backend's `container.devices`. Only used if the backend's `runtime` is `\"quadlet\"`.";
                    };
                    shmSize = mkOption {
                      type = types.str;
                      default = "32g";
                      example = "64g";
                      description = ''
                        Size of the container's private `/dev/shm` tmpfs, which
                        PyTorch uses for tensor-parallel inference.
                        Only used if the backend's `runtime` is `"quadlet"`.
                      '';
                    };
                  };
                };
                config.command = lib.mkDefault (
                  if native then
                    engine.native.command config
                  else
                    engine.quadlet.entrypoint ++ engine.quadlet.arguments config
                );
              }
            )
          ]
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen3-8b".model = "${engine.modelExample}";
          }
        '';
        description = ''
          Models to serve, each as the unit `${name}-<name>` beside its
          fetcher `${name}-<name>-fetch`, natively a hardened system service
          and otherwise a container, whose units
          `virtualisation.quadlet.containers.<unit>` override.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    services.llmhop = {
      claims = lib.mkMerge (
        lib.optional (fetchers != [ ]) { unit."${name}-update" = [ owner ]; }
        ++ map workloadClaims workloads
      );
      ${name}.fetch.credentials = lib.mkIf (cfg.fetch.hfTokenCredential != null) {
        ${cfg.fetch.hfTokenCredential} = lib.mkDefault null;
      };
      # Keyed by the unique owner, so a clash of names reaches the claims
      # assertion rather than failing the merge.
      endpoints = lib.genAttrs' workloads (
        workload:
        lib.nameValuePair workload.owner {
          inherit (workload)
            name
            owner
            socket
            ;
          unlisted = workload.kind == "detector";
          engine = name;
          url = util.probeUrl workload;
          # Reachable beyond loopback.
          inherit (workload) exposed;
        }
      );
    };
    assertions =
      map (w: util.firewallAssertion w.owner w) workloads
      ++ map (w: {
        assertion = w.offline -> w.isolable;
        message = "services.llmhop: `${w.owner}` sets `offline = true`, which needs its socket${lib.optionalString native " or a loopback `host`"}, so drop `port` or set `offline = false`.";
      }) workloads
      ++ map (w: {
        assertion = !cfg.fetch.enable && w.repositories != [ ] -> !w.offline;
        message = "services.llmhop: `${w.owner}` downloads its repositories itself without the backend's `fetch.enable`, so it needs `offline = false`.";
      }) workloads
      ++ [
        {
          # A fetcher prunes the hub cache on the host.
          assertion = cfg.cache.directory == null -> !native && !cfg.fetch.enable;
          message = "services.llmhop: `${owner}.cache.directory` is null, which only a container backend without `fetch.enable` supports.";
        }
      ];
    networking.firewall.allowedTCPPorts = lib.catAttrs "port" (
      lib.filter (w: w.exposed && w.openFirewall) workloads
    );
    # Every workload owns its own directory below the root, and every rule of
    # llmhop shares one file.
    systemd.tmpfiles.settings."10-llmhop" = lib.mkIf (cfg.cache.directory != null) (
      lib.mkMerge (
        [ (util.rootDirectoryRule cfg.cache.directory) ]
        ++ map (util.directoryRule cfg "0700") (
          lib.concatMap (w: [ (cacheDirectory w) ] ++ hubDirectories w) workloads
        )
      )
    );
    systemd.services = backend.maintenanceServices;
  };
}
