# Option builders of the native systemd backends.
lib: self:
let
  inherit (lib)
    mkOption
    types
    ;
  inherit (self)
    baseModelOptions
    baseOptions
    identityOptions
    nativeModelSubmodule
    nativeOptions
    serviceConfigOption
    startupOrderingOption
    unitConfigOption
    ;
in
{

  # Top-level options for a systemd-service backend.
  nativeOptions =
    { backend, cfg }:
    baseOptions { inherit backend; }
    // identityOptions {
      inherit cfg;
      name = backend;
      prefix = "services.llmhop.${backend}";
    };

  # Per-workload escape hatches for native units: extra `[Service]` and `[Unit]`
  # settings merged last, so they win over the hardened baseline and any
  # backend relaxations.
  serviceConfigOption =
    { serviceName }:
    mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        MemoryHigh = "64G";
      };
      description = ''
        Extra `[Service]` settings merged into this workload's
        `${serviceName}-<name>` unit after the hardened baseline and
        backend-specific relaxations. The module retains ownership of
        `ExecStart`, `KillMode`, and `Type` because they implement readiness
        supervision as one lifecycle contract.
      '';
    };

  unitConfigOption =
    { serviceName }:
    mkOption {
      type = with types; attrsOf anything;
      default = { };
      example = {
        StartLimitBurst = 10;
      };
      description = ''
        Extra `[Unit]` settings merged into this workload's
        `${serviceName}-<name>` unit after the shared baseline.

        Ordering and dependency directives (`After=`, `Requires=`, `Wants=`)
        do not belong here: NixOS renders those from the `after`, `requires`
        and `wants` options, so a definition of the same key in `unitConfig`
        conflicts with it instead of merging. Declare them on
        `systemd.services."${serviceName}-<name>"` from your own module,
        where the module system concatenates them with what this one sets.
      '';
    };

  # Per-model submodule for a systemd-service backend.
  nativeModelSubmodule =
    {
      backend,
      socketDirectory ? null,
      portDescription,
      modelDescription,
      modelExample,
    }:
    { name, config, ... }:
    {
      options =
        baseModelOptions {
          inherit
            backend
            name
            socketDirectory
            portDescription
            modelDescription
            modelExample
            ;
          workload = config;
        }
        // {
          serviceConfig = serviceConfigOption { serviceName = backend; };
          unitConfig = unitConfigOption { serviceName = backend; };
        };
    };

  # Options for a uv/wheel-based GPU Python backend (vLLM, SGLang): the
  # shared base plus the service identity, the `startupOrdering` switch and
  # the required, no-default `package` templated per backend. Parallels
  # `quadlet.mkOptions` bundling its consumer-specific options; the module
  # adds only `enable` and `models`. `displayName`/`packageEntry` fill the
  # prose and `packageNote` appends an optional trailing paragraph.
  uvOptions =
    {
      backend,
      cfg,
      displayName,
      packageEntry,
      packageNote ? "",
    }:
    nativeOptions { inherit backend cfg; }
    // {
      startupOrdering = startupOrderingOption {
        pinNote = "via `environment` (the variable is stack-specific: `CUDA_VISIBLE_DEVICES`, `HIP_VISIBLE_DEVICES`, `ZE_AFFINITY_MASK`, ...)";
      };
      package = mkOption {
        type = types.package;
        description = ''
          Package providing ${packageEntry}.

          No default on purpose: ${displayName} has no one-derivation-fits-all
          (new model architectures routinely need dev snapshots, and the wheels
          come in per-accelerator variants), so you build the package from a uv
          workspace and pin / follow upstream there. The flake exposes a
          helper:

          ```nix
          inputs.llmhop.legacyPackages.''${pkgs.system}.mkUvEnv {
            workspaceRoot = ./${backend}-env; # your pyproject.toml + uv.lock
          }
          ```

          Individual models may override this with `models.<name>.package`.
        ''
        + packageNote;
        example = lib.literalExpression ''
          inputs.llmhop.legacyPackages.''${pkgs.system}.mkUvEnv {
            workspaceRoot = ./${backend}-env;
          }
        '';
      };
    };

  # Per-model submodule for a uv/wheel-based GPU Python backend: the shared
  # base, with `modelArgument` naming the CLI argument `model` is passed as,
  # plus a per-model `package` override that defaults to the
  # backend-wide `package`. The override lets a single model pin a different
  # release (e.g. a nightly wheel for a just-released architecture) without
  # disturbing the others. `cfg` is the backend config, read for that default.
  uvModelSubmodule =
    {
      backend,
      cfg,
      socketDirectory ? null,
      modelArgument,
      modelExample,
    }:
    {
      imports = [
        (nativeModelSubmodule {
          inherit backend socketDirectory modelExample;
          modelDescription = "Hugging Face repository passed as ${modelArgument}, or an absolute path.";
          portDescription = ''
            Loopback host port ${backend} binds to (`--host 127.0.0.1 --port <port>`).
            Must be unique per enabled model; llmhop reaches the backend at
            `http://127.0.0.1:<port>`.
          '';
        })
      ];
      options.package = mkOption {
        type = types.package;
        default = cfg.package;
        defaultText = lib.literalExpression "config.services.llmhop.${backend}.package";
        description = ''
          Package providing this model's worker, overriding the backend-wide
          `package`. Set it for a model that needs a different ${backend}
          release than the rest — e.g. a nightly wheel for a just-released
          architecture — built the same way with `mkUvEnv` over a per-model
          uv workspace. Defaults to the backend-wide `package`.
        '';
      };
    };
}
