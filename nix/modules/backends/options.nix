# The options of the backend of `engine` under `services.llmhop.<name>`.
engine:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  inherit (engine) name;
  util = import ../lib lib;
  wl = import ./workload lib;
  llmhop = config.services.llmhop;
  cfg = llmhop.${name};
  owner = "services.llmhop.${name}";
  nativeOnly = util.runtimeOnly "native";
  containerOnly = util.runtimeOnly "container";
in
{
  options.services.llmhop.${name} =
    util.identityOptions {
      inherit name cfg;
      prefix = owner;
      runsAs = "the servers, fetchers and refresh units run as, which owns their directories";
    }
    // {
      enable = lib.mkEnableOption "${engine.displayName} model serving";
      package =
        if engine.uv then
          mkOption {
            type = types.package;
            description = ''
              Package providing the `${name}` CLI at `bin/${name}`, built from a uv
              workspace with the flake's `mkUvEnv`, as in
              `inputs.llmhop.legacyPackages.''${pkgs.stdenv.hostPlatform.system}.mkUvEnv { workspaceRoot = ./${name}-env; }`.
              ${nativeOnly}
            '';
          }
        else
          lib.mkPackageOption pkgs name { }
          // {
            description = "The ${name} package. ${nativeOnly}";
          };
      fetch = {
        enable = lib.mkEnableOption "the fetchers" // {
          default = true;
          description = ''
            Whether every workload has a fetcher `<unit>-fetch` downloading
            its repositories before its server starts, with a refresh unit and
            `${name}-update`, after which the server runs offline. Otherwise
            each server downloads its repositories itself when it starts, which
            requires `offline = false`, as in containers, and none of the other
            `fetch` options apply. ${nativeOnly}
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
            it, as `HF_TOKEN`, and skip it while it is missing. A container
            downloads for itself, so it gets `HF_TOKEN` from `environmentFile`
            instead.
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
        type = types.externalPath;
        default = "/var/cache/${name}";
        description = ''
          Root of the cache directories of this backend's workloads, created
          with mode `0711`, each `<name>` the `HF_HOME` of one fetcher and its
          server, created with mode `0700` for `user` and `group`. The
          fetcher writes its `hub/`, which the server only reads. Point it at
          a data disk for large models. A container keeps its cache in the
          Podman volume of its unit instead. ${nativeOnly}
        '';
      };
      environment = mkOption {
        type = with types; attrsOf str;
        default = { };
        description = ''
          Environment variables set on every server, under the `environment`
          of each workload, where `''${cred:<name>}` expands to the path of a
          credential.
        '';
      };
      environmentFile = mkOption {
        type = with types; nullOr externalPath;
        default = null;
        example = "/etc/${name}/.env";
        description = ''
          File in `KEY=VALUE` format forwarded to every server, loaded before
          the `environmentFile` of each workload. Prefer `credentials` for any
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
      shutdownTimeoutSeconds = mkOption {
        type = types.ints.unsigned;
        default = 10;
        example = 300;
        description = ''
          Seconds a stopped server, as on every restart after a fetch, drains
          its in-flight requests before it aborts them, as vLLM's
          `--shutdown-timeout`. SGLang drains until its unit kills it, ten
          seconds later, like any other server. Raise it for long streaming
          responses, at the cost of slower restarts.
        '';
      };
      startupOrdering = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Whether to start the servers one at a time by ascending `name`,
          so two workers profiling memory on the same GPU do not race into an
          OOM. It does not split a GPU between them, which needs explicit
          budgets, see the README. Each server wants the one before it, so
          starting one also starts the stopped ones before it. Disable only when each model
          pins itself to a dedicated device, natively via its own
          `environment`, e.g. `CUDA_VISIBLE_DEVICES` with GPU UUIDs or indices
          in PCI bus order, or in a container via its own `container.devices`.
        '';
      };
      native.devices = mkOption {
        type = with types; nullOr (listOf str);
        default =
          if config.hardware.nvidia.enabled or false then
            [
              "char-nvidia"
              "char-nvidiactl"
              "char-nvidia-uvm"
            ]
          else
            null;
        defaultText = lib.literalExpression ''
          if config.hardware.nvidia.enabled then [ "char-nvidia" "char-nvidiactl" "char-nvidia-uvm" ] else null
        '';
        example = [
          "/dev/kfd"
          "char-drm"
        ];
        description = ''
          Devices every model service may access as systemd `DeviceAllow=`
          entries under `DevicePolicy=closed`, while `null` allows all.
          Prefer device groups of `/proc/devices` such as `char-nvidia` over
          nodes such as `/dev/nvidia0`, whose minor numbers follow probe order
          and may change between boots.
          A model's `environment`, e.g. `CUDA_VISIBLE_DEVICES` with GPU UUIDs
          or indices in PCI bus order, then picks its GPUs.
          Per-model `native.devices` replaces it. ${nativeOnly}
        '';
      };
      container = {
        image = mkOption {
          type = types.str;
          example = engine.imageExample;
          description = "Container image reference, including a tag or digest. ${containerOnly}";
        };
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
            paths. Per-model `container.devices` replaces it. ${containerOnly}
          '';
        };
      };
      models = mkOption {
        type = types.attrsOf (
          types.submodule (
            wl.modelModule {
              inherit engine llmhop cfg;
            }
          )
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen3-8b".model = "${engine.modelExample}";
          }
        '';
        description = ''
          Models to serve, each as the unit `${name}-<name>`, natively a
          hardened system service beside its fetcher `${name}-<name>-fetch`,
          otherwise a container, whose units
          `virtualisation.quadlet.containers.<unit>` override.
        '';
      };
    }
    // {
      workloads = mkOption {
        type = types.listOf types.attrs;
        internal = true;
        readOnly = true;
        default = wl.workloads {
          inherit engine llmhop pkgs;
        };
        defaultText = lib.literalMD "the records of the enabled models and detectors";
        description = ''
          The record of every enabled model and detector, from which every
          unit, the gateway and the assertions derive what they render.
        '';
      };
    }
    // lib.optionalAttrs (engine.watermark != null) {
      detectors = mkOption {
        type = types.attrsOf (
          types.submodule (
            wl.detectorModule {
              inherit
                engine
                llmhop
                cfg
                pkgs
                ;
            }
          )
        );
        default = { };
        description = ''
          Watermark detection services serving `POST /detect` for the
          watermarks of this backend's models, each as the unit
          `${name}-<name>`, which the gateway routes as an unlisted model.
        '';
      };
    };
}
