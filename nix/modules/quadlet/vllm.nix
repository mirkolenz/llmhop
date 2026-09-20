{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.llmhop.vllm-quadlet;

  llmhopLib = import ../lib.nix lib;
  inherit (llmhopLib)
    credentialDirectory
    enabled
    renderCliArgsShell
    resolveCredentialRefs
    sortedModels
    vllmDetectorOptions
    vllmDetectorRegistry
    vllmDetectorSettings
    vllmDetectorUnit
    ;
  inherit (llmhopLib.quadlet)
    mkConfig
    mkContainerArgs
    mkContainerRuntime
    mkImageArgs
    mkModelSubmodule
    mkObjectOptions
    mkOptions
    mkStartupOrdering
    mkWorker
    ;

  renderArgs = renderCliArgsShell "vllm-quadlet";

  # Internal port every worker binds to inside its container.
  workerPort = 8000;

  # Sort by port so the After= chain is deterministic across rebuilds.
  models = sortedModels cfg;

  detectors = enabled cfg.detectors;
  detectorPort = 8000;

  mkDetectorContainer =
    detector:
    let
      settings = vllmDetectorSettings "0.0.0.0" detectorPort detector;
    in
    lib.nameValuePair (vllmDetectorUnit detector) (mkWorker {
      inherit cfg;
      inherit (detector) credentials;
      overrides = detector.quadlet;
      healthPort = detectorPort;
      healthPath = "/openapi.json";
      containerConfig =
        mkContainerRuntime cfg detector
        // mkImageArgs {
          inherit (cfg) image;
          defaultTag = cfg.tag;
          workload = detector;
          label = "services.llmhop.vllm-quadlet.detectors.${detector.name}";
        }
        // {
          PublishPort = [ "127.0.0.1:${toString detector.port}:${toString detectorPort}" ];
          Entrypoint = lib.toJSON [ "python" ];
          Exec = "${lib.escapeShellArg detector.script} ${
            renderArgs (resolveCredentialRefs credentialDirectory detector.credentials settings)
          }";
        };
      serviceConfig.Restart = "on-failure";
    });

  mkContainer =
    index: model:
    let
      settings = {
        served-model-name = model.name;
        host = "0.0.0.0";
        port = workerPort;
      }
      // cfg.modelSettings
      // model.settings;
    in
    lib.nameValuePair "vllm-${model.name}" (mkWorker {
      inherit cfg;
      inherit (model) credentials;
      overrides = model.quadlet;
      healthPort = workerPort;
      containerConfig =
        (mkContainerArgs {
          backend = "vllm-quadlet";
          inherit cfg model;
        })
        // {
          PublishPort = [ "127.0.0.1:${toString model.port}:${toString workerPort}" ];
          Exec = "${lib.escapeShellArg model.model} ${
            renderArgs (resolveCredentialRefs credentialDirectory model.credentials settings)
          }";
        };
      unitConfig = mkStartupOrdering {
        inherit
          config
          cfg
          models
          index
          ;
        prefix = "vllm";
      };
    });
in
{
  options.services.llmhop.vllm-quadlet =
    mkOptions {
      backend = "vllm-quadlet";
      inherit cfg config;
      defaultImage = "docker.io/vllm/vllm-openai";
      defaultCacheDir = "/var/cache/vllm";
      tagExample = "v0.11.0";
    }
    // {
      enable = lib.mkEnableOption "vLLM model serving via Quadlet, fronted by llmhop";

      models = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            imports = [
              (mkModelSubmodule {
                backend = "vllm-quadlet";
                inherit cfg;
              })
            ];
            options.port = lib.mkOption {
              type = lib.types.port;
              description = ''
                Loopback host port forwarded to the container's vLLM API.
                Must be unique per model.
              '';
            };
          }
        );
        default = { };
        example = lib.literalExpression ''
          {
            "qwen2-5-7b" = {
              model = "Qwen/Qwen2.5-7B-Instruct";
              port = 18001;
            };
            "llama-3-8b" = {
              model = "meta-llama/Meta-Llama-3-8B-Instruct";
              port = 18002;
              settings.max-model-len = 8192;
            };
          }
        '';
        description = ''
          Models to serve.
          Each entry produces one quadlet container; the attribute name is the routing key.
          Enabled entries are sorted by ascending `port`.
        '';
      };

      detectors = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = vllmDetectorOptions name // {
                script = lib.mkOption {
                  type = lib.types.str;
                  example = "/vllm-workspace/examples/basic/online_serving/watermark_detection_server.py";
                  description = ''
                    Path inside the selected image to vLLM's upstream
                    `watermark_detection_server.py`.
                  '';
                };
                tag = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = "Container image tag for this detector.";
                };
                digest = lib.mkOption {
                  type = with lib.types; nullOr str;
                  default = null;
                  description = "Immutable container image digest for this detector.";
                };
                quadlet = mkObjectOptions { description = "this detector container"; };
              };
            }
          )
        );
        default = { };
        description = "Standalone watermark detection containers.";
      };
    };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkConfig (
        {
          backend = "vllm-quadlet";
          inherit cfg config pkgs;
        }
        // vllmDetectorRegistry detectors
      ))
      {
        virtualisation.quadlet.containers = lib.listToAttrs (
          (lib.imap0 mkContainer models) ++ map mkDetectorContainer (lib.attrValues detectors)
        );
      }
    ]
  );
}
