# The Shepherd Model Gateway (SMG) in front of every listed endpoint under
# `services.llmhop.gateway.smg`.
sectionType:
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
  gateway = import ./shared.nix lib;

  name = "smg";
  displayName = "SMG";
  cfg = config.services.llmhop.gateway.${name};
  native = cfg.runtime == "native";
  endpoints = gateway.listedEndpoints config;

  # A discovery file rather than `--worker-urls`: SMG keeps retrying the
  # workers it lists, while it gives up on one of the command line after
  # `--worker-startup-timeout-secs`, which loading a model may well exceed.
  discoveryFile = (pkgs.formats.json { }).generate "smg-workers.json" {
    version = 1;
    workers = map (e: {
      id = e.name;
      inherit (e) url;
      model_id = e.name;
    }) endpoints;
  };
  containerDiscoveryFile = "${util.containerRuntimeDirectory}/workers.json";

  # SMG's launcher parses its flags with argparse.
  arguments = [
    "-m"
    "smg.launch_router"
  ]
  ++ util.renderCliArgs {
    negateBools = false;
    listStyle = "values";
  } cfg.settings;
in
{
  options.services.llmhop.gateway.${name} =
    gateway.options {
      inherit config sectionType displayName;
      image = util.imageOption // {
        example = "ghcr.io/smg-project/smg:nightly";
      };
    }
    // gateway.tcpOptions displayName
    // {
      package = mkOption {
        type = types.package;
        description = ''
          Python environment providing the `smg` package, built with the
          flake's `mkUvEnv`, since nixpkgs lacks SMG.
          Only used if `runtime` is `"native"`.
        '';
      };
      settings = mkOption {
        type = with types; attrsOf json;
        default = { };
        example = {
          api-key-file = "\${cred:smg.api-key}";
          policy = "cache_aware";
        };
        description = ''
          CLI flags of SMG, rendered as `--<key> <value>` with `false`
          dropped. The listener and the discovery file of every listed model
          always win, while metrics on `127.0.0.1:29000` and disabled
          tokenizer downloads are defaults. Credential references
          resolve to file paths for upstream options such as `api-key-file`
          and `tenant-api-keys-file`, which require a supporting SMG build.
        '';
      };
    };

  config = lib.mkIf (config.services.llmhop.gateway.type == name) (
    lib.mkMerge [
      (gateway.tcpConfig { inherit name cfg endpoints; })
      {
        # The listener wins, so the port claim and the firewall agree with SMG.
        services.llmhop.gateway.${name}.settings =
          lib.mapAttrs (_: lib.mkForce) {
            inherit (cfg) host port;
            discovery-provider = "file";
            discovery-file = if native then discoveryFile else containerDiscoveryFile;
          }
          // lib.mapAttrs (_: lib.mkOptionDefault) {
            enable-igw = true;
            prometheus-host = "127.0.0.1";
            prometheus-port = 29000;
            disable-tokenizer-autoload = true;
          };
        services.llmhop.claims.port = lib.optionalAttrs (cfg.settings.prometheus-port or null != null) {
          ${toString cfg.settings.prometheus-port} = [ (gateway.owner name) ];
        };
      }
      (gateway.unit {
        inherit config utils name;
        description = "SMG model gateway";
        command = [ (lib.getExe' cfg.package "python") ] ++ arguments;
        container = {
          entrypoint = "python3";
          inherit arguments;
          volumes = [ "${discoveryFile}:${containerDiscoveryFile}:ro" ];
        };
      })
    ]
  );
}
