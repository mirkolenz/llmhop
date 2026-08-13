{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.sglang-quadlet;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib) cliOptionFormat resolveImageRef sortedModels;
  inherit (llmhopLib.quadlet)
    mkConfig
    mkContainerArgs
    mkModelSubmodule
    mkOptions
    mkWorker
    ;

  # SGLang uses plain `store_true` booleans paired as `--enable-X` /
  # `--disable-X` (and the Rust SGL Model Gateway's clap `SetTrue` likewise
  # has no auto-negation), so we deliberately do NOT apply `flipBoolFlags`
  # here. `true` collapses to `--key`, `null`/`false` are dropped; users
  # write the negated key explicitly (e.g. `disable-radix-cache = true`).
  renderArgs = lib.cli.toCommandLineShell (cliOptionFormat "=");

  # Internal port every worker binds to inside its container.
  workerPort = 30000;

  # Sort by port so the After= chain is deterministic across rebuilds.
  models = sortedModels cfg;

  mkContainer =
    i: model:
    lib.nameValuePair "sglang-${model.name}" (mkWorker {
      inherit cfg;
      healthPort = workerPort;
      containerConfig =
        (mkContainerArgs {
          backend = "sglang-quadlet";
          inherit cfg model;
        })
        // {
          PublishPort = [ "127.0.0.1:${toString model.port}:${toString workerPort}" ];
          # Override the image's default entrypoint with the `sglang serve` CLI.
          Entrypoint = lib.toJSON [
            "sglang"
            "serve"
          ];
          Exec = renderArgs (
            {
              model-path = model.model;
              served-model-name = model.name;
              host = "0.0.0.0";
              port = workerPort;
            }
            // cfg.modelSettings
            // model.settings
          );
        };
      # Chain ascending so each worker finishes GPU-memory profiling before the next starts.
      unitConfig = {
        After =
          lib.optional (cfg.startupOrdering && i > 0)
            "${
              config.virtualisation.quadlet.containers."sglang-${(lib.elemAt models (i - 1)).name}".serviceName
            }.service";
      };
    });

  # The gateway calls /get_model_info on each `worker-urls` entry and uses
  # the worker's `--served-model-name` as the routing key. Host networking
  # lets it reach workers at their published loopback ports without a
  # dedicated podman network.
  gatewayBaseSettings = {
    host = cfg.gateway.bindAddress;
    port = cfg.gateway.port;
    prometheus-host = if cfg.gateway.enableMetrics then cfg.gateway.bindAddress else null;
    prometheus-port = if cfg.gateway.enableMetrics then cfg.gateway.metricsPort else null;
    enable-igw = true;
  };

  # `--worker-urls` is `nargs='*'`, so each URL becomes its own argv entry;
  # we build the full argv list and shell-escape once for Quadlet's `Exec=`.
  gatewayExec = lib.escapeShellArgs (
    lib.cli.toCommandLine (cliOptionFormat "=") (gatewayBaseSettings // cfg.gateway.settings)
    ++ lib.optionals (models != [ ]) (
      [ "--worker-urls" ] ++ map (m: "http://127.0.0.1:${toString m.port}") models
    )
  );

  workerServices = map (
    m: "${config.virtualisation.quadlet.containers."sglang-${m.name}".serviceName}.service"
  ) models;

  mkGatewayContainer = lib.nameValuePair "sglang-gateway" (mkWorker {
    inherit cfg;
    healthPort = cfg.gateway.port;
    healthStartPeriod = "5m";
    containerConfig = {
      Image = resolveImageRef {
        inherit (cfg.gateway) image tag digest;
        defaultTag = "latest";
        label = "services.llmhop.sglang-quadlet.gateway";
      };
      Pull = if cfg.gateway.digest != null then "missing" else "newer";
      # Host networking lets the gateway reach each worker at
      # `127.0.0.1:<model.port>` and binds its own listeners directly on
      # `bindAddress`, so no `PublishPort` is required.
      Network = "host";
      EnvironmentFile = lib.optional (cfg.gateway.environmentFile != null) cfg.gateway.environmentFile;
      Environment = cfg.gateway.environment;
      Exec = gatewayExec;
    };
    # The gateway is a stateless Rust binary — short timing overrides the
    # worker-scale defaults baked into `mkWorker`.
    serviceConfig = {
      TimeoutStartSec = 600;
      RestartSec = 10;
    };
    unitConfig = {
      StartLimitBurst = 5;
      StartLimitIntervalSec = 600;
      # Requires=+After= paired with Notify=healthy on workers gives us
      # `depends_on: service_healthy` — the gateway starts only after every
      # worker answers /health, so /get_model_info discovery succeeds.
      After = workerServices;
      Requires = workerServices;
    };
  });
in
{
  options.services.llmhop.sglang-quadlet =
    mkOptions {
      backend = "sglang-quadlet";
      inherit cfg config;
      defaultImage = "docker.io/lmsysorg/sglang";
      defaultCacheDir = "/var/cache/sglang";
    }
    // {
      enable = lib.mkEnableOption "SGLang model serving via Quadlet, optionally fronted by the SGL Model Gateway";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            imports = [
              (mkModelSubmodule {
                backend = "sglang-quadlet";
                inherit cfg;
              })
            ];
            options.port = lib.mkOption {
              type = lib.types.port;
              description = ''
                Loopback host port forwarded to the container's SGLang API.
                Must be unique per model and must not collide with `gateway.port` /
                `gateway.metricsPort` when the gateway is enabled.
              '';
            };
          }
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen3-8b" = {
              model = "Qwen/Qwen3-8B";
              port = 19001;
              settings = {
                reasoning-parser = "qwen3";
                tool-call-parser = "qwen3_coder";
                mem-fraction-static = 0.6;
                cuda-graph-max-bs = 4;
              };
            };
          }
        '';
        description = ''
          Models to serve.
          Each entry produces one quadlet container; the attribute name is the routing key
          (advertised via `--served-model-name` and surfaced through both llmhop and the
          optional SGL Model Gateway as the OpenAI `model` field).
          Enabled entries are sorted by ascending `port`.
        '';
      };

      gateway = {
        enable = lib.mkEnableOption ''
          the SGL Model Gateway in front of the workers.
          Disabled by default — llmhop already routes between every backend, and the
          gateway is only needed when you want SGLang's IGW dispatch features
          (custom routing, prefix caching across workers, etc.)
        '';

        image = lib.mkOption {
          type = lib.types.str;
          default = "docker.io/lmsysorg/sgl-model-gateway";
          description = "Container image used for the gateway.";
        };

        tag = lib.mkOption {
          type = with lib.types; nullOr str;
          default = "latest";
          description = "Default tag of the gateway image. Mutually exclusive with `digest`.";
        };

        digest = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = "Immutable digest of the gateway image. Mutually exclusive with `tag`.";
        };

        bindAddress = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = ''
            Host address the gateway binds its listeners to.
            Defaults to the loopback so external clients must go through Caddy / llmhop.
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          description = "Host port the gateway listens on.";
        };

        enableMetrics = lib.mkEnableOption "Prometheus metrics on the gateway" // {
          default = true;
        };

        metricsPort = lib.mkOption {
          type = lib.types.port;
          default = 29000;
          description = ''
            Host port the gateway exposes Prometheus metrics on.
            Ignored when `enableMetrics` is false.
          '';
        };

        environment = lib.mkOption {
          type = with lib.types; attrsOf str;
          default = { };
          description = "Additional environment variables set on the gateway container.";
        };

        environmentFile = lib.mkOption {
          type = with lib.types; nullOr path;
          default = null;
          example = "/etc/sglang/gateway.env";
          description = ''
            File in `KEY=VALUE` format forwarded to the gateway via `--env-file`.
            Use for secrets like API keys; the gateway's `--api-key` flag may also be passed via
            `settings` if the value is non-secret.
          '';
        };

        settings = lib.mkOption {
          type = with lib.types; attrsOf anything;
          default = { };
          example = {
            api-key = "secret";
            tls-cert-path = "/etc/sglang/tls/server.crt";
          };
          description = ''
            Additional CLI flags forwarded to `sgl-model-gateway`.
            `true` collapses to `--<key>`; `null` and `false` are dropped (write
            the negated key explicitly when the upstream CLI registers one).
          '';
        };
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig {
        backend = "sglang-quadlet";
        inherit cfg config pkgs;
        extras =
          lib.optionalAttrs cfg.gateway.enable { gateway = cfg.gateway.port; }
          // lib.optionalAttrs (cfg.gateway.enable && cfg.gateway.enableMetrics) {
            gateway-metrics = cfg.gateway.metricsPort;
          };
        # `gateway-metrics` is only a second port on the gateway, not its own unit.
        extraUnits = lib.optionalAttrs cfg.gateway.enable { gateway = "sglang-gateway"; };
      })
      {
        virtualisation.quadlet.containers = lib.listToAttrs (
          (lib.imap0 mkContainer models) ++ lib.optional cfg.gateway.enable mkGatewayContainer
        );
      }
    ]
  );
}
