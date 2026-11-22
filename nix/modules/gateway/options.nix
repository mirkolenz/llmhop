# The options of llmhop in front of every backend under
# `services.llmhop.gateway`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  util = import ../lib lib;
  wl = import ../backends/workload lib;
  llmhop = config.services.llmhop;
  cfg = llmhop.gateway;
  owner = "services.llmhop.gateway";
  workloads = wl.allWorkloads llmhop;
in
{
  options.services.llmhop.gateway =
    util.identityOptions {
      name = "llmhop";
      inherit cfg;
      prefix = owner;
      runsAs = "the gateway runs as";
    }
    // {
      enable = lib.mkEnableOption ''
        llmhop in front of every backend, routing every workload by its
        `name`, which must then stay on loopback and leave authentication to
        the gateway. Without it, clients connect to each workload directly
      '';

      active = mkOption {
        type = types.bool;
        readOnly = true;
        default = cfg.enable && workloads != [ ];
        defaultText = lib.literalMD "whether `enable` is set and any backend serves a workload";
        description = ''
          Whether the gateway runs, which needs a workload to route, so a host
          whose backends are all disabled, such as a test VM without GPUs,
          keeps its gateway config without running it. Units relying on the
          gateway, such as clients joining its socket group, can follow it.
        '';
      };

      package = lib.mkPackageOption pkgs "llmhop" { } // {
        default = llmhop.package;
        defaultText = lib.literalExpression "config.services.llmhop.package";
      };

      credentials = util.credentialsOption // {
        description = util.credentialsOption.description + ''

          llmhop reads its own config, so in `settings` the reference expands
          to the credential's contents rather than to its path.
        '';
      };

      settings = mkOption {
        type = with types; attrsOf json;
        default = { };
        example = {
          authTokens.client = "\${cred:llmhop.client-token}";
          models."openai/*".urls = [ "https://api.openai.com" ];
        };
        description = ''
          llmhop's JSON config, validated at build time by the binary itself,
          with every workload of the backends as a model. Its listeners come
          from `listen`, so `settings` must not set it.
        '';
      };

      ctl = {
        enable =
          lib.mkEnableOption "`llmhopctl`, which manages the client tokens of `settings.authTokenCredentials`"
          // {
            default = true;
          };
        package = mkOption {
          type = types.package;
          default = pkgs.callPackage ../../pkgs/llmhopctl/package.nix { };
          defaultText = lib.literalExpression "pkgs.callPackage ./pkgs/llmhopctl/package.nix { }";
          description = "The `llmhopctl` package, which reads the gateway's config from `/etc/llmhop/config.json`.";
        };
      };

      container.image = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "ghcr.io/mirkolenz/llmhop:latest";
        description = ''
          Container image reference, including a tag or digest, or `null`
          for an archive of `package`, which validated the config at build
          time and updates with the system rather than the registry.
          ${util.runtimeOnly "container"}
        '';
      };

      listen = mkOption {
        type = types.attrsOf (
          types.submodule (
            { name, ... }:
            {
              options = {
                port = mkOption {
                  type = with types; nullOr port;
                  default = null;
                  example = 8080;
                  description = ''
                    TCP port to listen on. `null` listens on the unix socket `socket`
                    instead. The `default` listener defaults to `8080`.
                  '';
                };
                host = mkOption {
                  type = types.str;
                  default = "127.0.0.1";
                  example = "";
                  description = ''
                    IP address to bind `port` to. An empty string binds every interface,
                    leaving access control to the firewall. IPv6 literals are written
                    plain (e.g. `::1`).
                  '';
                };
                openFirewall = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Whether to open `port` in the host firewall, which requires a `host` other than loopback.";
                };
                socket = mkOption {
                  type = types.str;
                  default = "${llmhop.socketDirectory}/${name}.sock";
                  defaultText = lib.literalExpression ''"''${config.services.llmhop.socketDirectory}/${name}.sock"'';
                  description = "Unix socket to listen on while `port` is null.";
                };
                socketUser = mkOption {
                  type = types.str;
                  default = "root";
                  description = "Owner of `socket`.";
                };
                socketGroup = mkOption {
                  type = types.str;
                  default = "root";
                  example = "caddy";
                  description = "Group of `socket`, typically the one of a reverse proxy in front of llmhop.";
                };
                socketMode = mkOption {
                  type = types.str;
                  default = "0660";
                  description = "Mode of `socket`. Connecting needs write permission.";
                };
                trusted = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Whether requests on `socket` need no token and count as the client
                    named after the listener, since `socketUser`, `socketGroup` and
                    `socketMode` decide who may connect. Browsers must send same-origin
                    requests to a loopback host, so web pages cannot use a port forward
                    of it. Requires `settings.authTokens` or `settings.authTokenCredentials`.
                  '';
                };
              };
            }
          )
        );
        default = { };
        example = {
          default.host = "";
          caddy.socketGroup = "caddy";
          ssh = {
            socketGroup = "wheel";
            trusted = true;
          };
        };
        description = ''
          Listeners of the gateway, each a `llmhop-<name>.socket` unit handing
          its socket to it through socket activation. The `default` one always
          exists, on port `8080` unless configured otherwise.
        '';
      };
    }
    // util.environmentOptions {
      environment.description = ''
        Environment variables of the gateway. With `credentials`,
        `''${cred:<name>}` expands to the path of one of them.
      '';
      environmentFile.description = ''
        File outside the Nix store in `KEY=VALUE` format, loaded by
        systemd or Podman and forwarded to the gateway.
      '';
    };
}
