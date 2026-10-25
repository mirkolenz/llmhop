# Option builders of the Quadlet backends.
lib: self:
let
  inherit (lib)
    mkOption
    types
    ;
  inherit (self)
    baseModelOptions
    baseOptions
    mkQuadletImageOptions
    mkQuadletObjectOptions
    quadletServiceName
    socketCapable
    startupOrderingOption
    ;
in
{
  # `socket` adds the options of a container that may bind a unix socket.
  mkQuadletObjectOptions =
    {
      description ? "this container",
      socket ? false,
    }:
    let
      sectionOption =
        section:
        mkOption {
          type = with types; attrsOf anything;
          default = { };
          description = "Extra `[${section}]` settings applied to ${description}.";
        };
    in
    {
      containerConfig = mkOption {
        type = with types; attrsOf anything;
        default = { };
        description = ''
          Extra `[Container]` settings applied to ${description}.
          Keys use Quadlet's native `PascalCase` names, including `User`,
          `UserNS`, `UIDMap`, `GIDMap`, `SubUIDMap`, and `SubGIDMap`.
        '';
      };
      serviceConfig = sectionOption "Service";
      unitConfig = sectionOption "Unit";
      quadletConfig = sectionOption "Quadlet";
      extraConfig = mkOption {
        type = with types; attrsOf (attrsOf anything);
        default = { };
        description = ''
          Extra unit sections applied to ${description} after all generated
          sections. This is the final escape hatch for settings that do not
          fit one of the dedicated `*Config` options.
        '';
      };
      mountOptions = {
        credentials = mkOption {
          type = with types; listOf str;
          default = [ ];
          example = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
          description = ''
            Podman volume options appended to ${description}'s systemd
            credential mount. Use an `idmap` mapping when `[Container] User=`
            selects a non-root identity. The mount is always read-only.
          '';
        };
      }
      // lib.optionalAttrs socket {
        socket = mkOption {
          type = with types; listOf str;
          default = [ "U" ];
          example = [
            "U"
            "z"
          ];
          description = ''
            Podman volume options of ${description}'s socket directory mount.
            `U` hands the directory to whatever host UID the container user maps
            to, so the socket works under any `User=` and `UserNS=`. Add `z` on
            SELinux hosts.
          '';
        };
      };
    };

  # Per-workload overrides of the backend's image.
  mkQuadletImageOptions =
    { noun }:
    {
      tag = mkOption {
        type = with types; nullOr str;
        default = null;
        description = ''
          Tag of the container image used for this ${noun}.
          Mutually exclusive with `digest`.
        '';
      };
      digest = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "sha256:a73fb0b9046fee099f7c1829d2548e6cc1740f4c2776a6855fa659ae5d0deb49";
        description = ''
          Immutable digest of the container image (e.g. `sha256:…`).
          Mutually exclusive with `tag`.
        '';
      };
    };

  # Top-level options for a quadlet-based backend. Spread under
  # `options.services.llmhop.<backend>` via `//`; the caller adds `enable`,
  # `models`, and any backend-specific extras (gateway sub-options, etc.).
  # `cfg` (the corresponding `config.services.llmhop.<backend>`) is read for
  # the defaults of `cache.user` and `cache.group`, and `config` (the
  # top-level NixOS config) so `devices` can derive its default from
  # `hardware.nvidia-container-toolkit.enable`.
  quadletOptions =
    {
      backend,
      cfg,
      config,
      defaultImage,
      tagExample ? "latest",
    }:
    let
      serviceName = quadletServiceName backend;
      base = baseOptions { inherit backend; };
      userType = types.submodule (
        { config, ... }:
        {
          options = {
            manage = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether llmhop creates and configures this account. Disable
                this for an account managed elsewhere, including its home,
                linger setting, group, and subordinate ID ranges.
              '';
            };
            name = mkOption {
              type = types.str;
              default = serviceName;
              description = "Host account whose systemd user manager owns the Quadlets.";
            };
            uid = mkOption {
              type = types.ints.positive;
              example = 503;
              description = "UID of the systemd user manager that owns the Quadlets.";
            };
            group = mkOption {
              type = types.str;
              default = config.name;
              defaultText = lib.literalExpression "config.name";
              description = "Primary group of the managed account.";
            };
            gid = mkOption {
              type = types.ints.positive;
              default = config.uid;
              defaultText = lib.literalExpression "config.uid";
              description = "GID of the managed account's primary group.";
            };
            home = mkOption {
              type = types.path;
              default = "/var/lib/${serviceName}";
              description = ''
                Home directory used for rootless Podman storage. This must
                live on a filesystem that supports the selected storage driver.
              '';
            };
          };
        }
      );
    in
    base
    // {
      image = mkOption {
        type = types.str;
        default = defaultImage;
        description = "Container image used for every model worker.";
      };
      tag = mkOption {
        type = types.str;
        example = tagExample;
        description = ''
          Default tag of the container image used for models that do not set their own
          `tag` or `digest`.
        '';
      };
      # Mounts are per container: the global layer would apply a mapping to
      # containers that do not share the same `User=`.
      quadlet =
        removeAttrs (mkQuadletObjectOptions {
          description = "every generated container";
        }) [ "mountOptions" ]
        // {
          user = mkOption {
            type = types.nullOr userType;
            default = null;
            description = ''
              Host account whose systemd user manager owns these Quadlets.
              `null` installs system units and runs Podman rootfully. An
              attribute set installs user units for its `uid` and runs Podman
              rootlessly. This is independent of `[Container] User=` and the
              container's user namespace configuration.

              A managed account gets NixOS-allocated subordinate ID ranges.
              Set `users.users.<name>.subUidRanges` and `subGidRanges` (with
              `autoSubUidGidRange = false`) to pick them yourself.
            '';
          };
        };
      cache = base.cache // {
        mountOptions = mkOption {
          type = with types; listOf str;
          default = [ ];
          example = [ "idmap" ];
          description = ''
            Options appended to the Quadlet `Volume=` entries of `directory`
            and of each server's own cache directory. This can be used for
            Podman ownership mechanisms such as `idmap` or SELinux
            relabeling. `U` works too, but systemd and Podman then hand the
            server's cache directory back and forth on every start.
          '';
        };
        user = mkOption {
          type = types.str;
          default = if cfg.quadlet.user == null then "root" else cfg.quadlet.user.name;
          defaultText = lib.literalExpression ''
            if config.services.llmhop.${backend}.quadlet.user == null then
              "root"
            else
              config.services.llmhop.${backend}.quadlet.user.name
          '';
          description = ''
            Host owner used when `cache.manage` is enabled. Override it when a
            `UIDMap`/`idmap` mapping makes the container see a different owner
            than the host account running Podman.
          '';
        };
        group = mkOption {
          type = types.str;
          default = if cfg.quadlet.user == null then "root" else cfg.quadlet.user.group;
          defaultText = lib.literalExpression ''
            if config.services.llmhop.${backend}.quadlet.user == null then
              "root"
            else
              config.services.llmhop.${backend}.quadlet.user.group
          '';
          description = "Host group used when `cache.manage` is enabled.";
        };
      };
      startupOrdering = startupOrderingOption { pinNote = "via its own `devices`"; };
      devices = mkOption {
        type = with types; listOf str;
        default =
          if config.hardware.nvidia-container-toolkit.enable or false then [ "nvidia.com/gpu=all" ] else [ ];
        defaultText = lib.literalExpression ''
          if config.hardware.nvidia-container-toolkit.enable then
            [ "nvidia.com/gpu=all" ]
          else
            [ ]
        '';
        example = [ "amd.com/gpu=all" ];
        description = ''
          Devices exposed to every model container — passed verbatim as Quadlet
          `AddDevice=` lines. Accepts both CDI references (recommended:
          `nvidia.com/gpu=…`, `amd.com/gpu=…`, `intel.com/gpu=…`, ...) and raw
          host device paths (e.g. `/dev/dri/renderD128`). For CDI, the
          corresponding spec must be generated on the host (e.g.
          `nvidia-ctk cdi generate`).
          Defaults to `[ "nvidia.com/gpu=all" ]` when
          `hardware.nvidia-container-toolkit.enable` is set, otherwise empty
          (CPU-only). Per-model `devices` overrides this.
        '';
      };
    };

  # Per-model submodule for a quadlet-based backend. `cfg` (the top-level
  # backend config) is passed so `devices` can lazily default to the
  # backend-wide value.
  quadletModelSubmodule =
    {
      backend,
      cfg,
      socketDirectory ? null,
      portDescription,
      modelDescription,
      modelExample,
    }:
    let
      serviceName = quadletServiceName backend;
    in
    { name, config, ... }:
    {
      options =
        (baseModelOptions {
          inherit
            backend
            serviceName
            name
            socketDirectory
            portDescription
            modelDescription
            modelExample
            ;
          workload = config;
        })
        // mkQuadletImageOptions { noun = "model"; }
        // {
          devices = mkOption {
            type = with types; listOf str;
            default = cfg.devices;
            defaultText = lib.literalExpression "config.services.llmhop.${backend}.devices";
            example = [ "nvidia.com/gpu=0" ];
            description = ''
              Devices exposed to this model's container — passed verbatim as
              Quadlet `AddDevice=` lines. Replaces (does not extend)
              `services.llmhop.${backend}.devices` for this model.
              Use to pin a model to specific device indices
              (e.g. `[ "nvidia.com/gpu=0" ]`).
            '';
          };
          shmSize = mkOption {
            type = types.str;
            default = "32g";
            example = "64g";
            description = ''
              Size of the container's private `/dev/shm` tmpfs.
              PyTorch and friends use shared memory for NCCL/tensor-parallel inference;
              upstream recommends 32g (or `--ipc=host`). A private tmpfs is preferred for
              isolation: raise the value for larger models or higher tensor-parallel sizes.
            '';
          };
          quadlet = mkQuadletObjectOptions {
            description = "this model's server and fetcher containers";
            socket = socketCapable backend;
          };
        };
    };
}
