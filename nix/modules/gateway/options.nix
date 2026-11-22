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
  inherit (import ./common.nix { inherit config lib; })
    util
    llmhop
    cfg
    owner
    workloads
    listeners
    ;
  # The ports of the listeners with metrics, as reached from the host, since
  # Prometheus cannot scrape a unix socket.
  metricsTargets = lib.pipe listeners [
    lib.attrValues
    (lib.filter (listener: listener.metrics && listener.port != null))
    (map (listener: util.listenStream (listener // { host = util.reachableHost listener.host; })))
  ];

  # A field of llmhop's JSON config, left out of it while null, since a set
  # one, even `0` or empty, replaces the layers below it.
  field =
    type: description:
    mkOption {
      type = types.nullOr type;
      default = null;
      inherit description;
    };
  # The fields of every layer of a client's policy, `0` meaning no limit.
  policyOptions = {
    models = field (types.listOf types.str) ''
      Allowlist of model names, aliases and detectors, also for
      `/llmhop/proxy/<model>/`, with wildcards such as `qwen3-*`.
    '';
    maxConcurrentRequests = field types.ints.u32 "Requests in flight at once, beyond which a request waits in the model's queue.";
    requestsPerMinute = field types.ints.u32 "Requests per minute, refilled as a token bucket.";
    weight = field types.ints.u32 "Share of a client among those waiting for a saturated model, one by default.";
  };
  policy = types.submodule { options = policyOptions; };
  client = types.submodule {
    options = policyOptions // {
      key = field types.str ''
        Bearer key of the client, typically a `''${cred:<name>}` reference.
        Exactly one of `key` and `listener` must be set.
      '';
      listener = field types.str ''
        Name of a unix socket listener of `listen` whose requests count as
        the client's without a key, since its `socketUser`, `socketGroup`
        and `socketMode` decide who may connect. Browsers must send
        same-origin requests to a loopback host, so web pages cannot use a
        port forward of it.
      '';
      policy = field types.str "Name of the entry of `policies` below the client's own fields.";
      expiresAt = field types.str "RFC 3339 time after which the client is rejected.";
    };
  };
  affinitySource = types.submodule {
    options = {
      header = field types.str "Request header carrying the affinity key.";
      body = field (types.nonEmptyListOf types.str) "Path of member names to a string in the JSON body carrying the affinity key.";
      pinned = field types.bool "Whether the requests of the key never leave their server, since their state lives there.";
    };
  };
  model = types.submodule {
    options = {
      urls = mkOption {
        type = types.nonEmptyListOf types.str;
        example = [ "http://127.0.0.1:8001" ];
        description = "Servers of the model, each an absolute `http(s)` URL or `unix:///<socket path>`, between which requests are balanced.";
      };
      aliases = field (types.attrsOf (
        types.submodule {
          options.model = field types.str "`model` a JSON body routed by the alias is rewritten to, or `null` to forward it verbatim.";
        }
      )) "Further names routed to the model and listed beside it, such as its LoRA adapters.";
      headers = field (types.attrsOf types.str) "Headers of every request to the model, applied last, with secret references such as `\${cred:<name>}`.";
      metadata = field (types.attrsOf types.json) "Members of the model's object in the models API, such as `max_model_len`, or replacing `created` and `owned_by`.";
      unlisted = field types.bool "Whether the model is routed but left out of the models API, such as a watermark detector.";
      maxConcurrentRequests = field types.ints.u32 "Requests in flight over all `urls`, beyond which a request waits in the model's queue, `0` meaning no limit.";
      queueTimeoutSeconds = field types.ints.u32 "Seconds a request waits for a free slot before it gets `429`, `0` rejecting it at once.";
      responseTimeoutSeconds = field types.ints.u32 "Seconds a server may take until its response headers, before the request gets `504`, `0` meaning no limit.";
      dataParallelSize = field (types.ints.between 1 256) "Data-parallel ranks of every URL, which requests with an affinity key are pinned to.";
      failoverSeconds = field types.ints.u32 "Seconds a server is avoided after it refused a connection or failed three requests in a row, `5` by default.";
      healthPath = field types.str "Path that readiness and `llmhop_backend_up` probe on every URL, or `null` to skip the model.";
    };
  };
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
        type = types.submodule {
          options = {
            defaults = field policy ''
              Policy below every client and its `policy`, which alone limits
              the anonymous client while no client exists.
            '';
            policies = field (types.attrsOf policy) "Named policies, each below the clients naming it in `policy`.";
            clients = field (types.attrsOf client) ''
              Clients by name, which the backends learn from `X-Llmhop-Client`.
              With any client or `clientCredentials`, every route but
              `/llmhop/health`, `/llmhop/readiness` and the metrics requires one.
            '';
            listen = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    host = field types.str "IP address `port` is bound to, every interface if empty.";
                    port = field types.port "TCP port of the listener.";
                    socket = field types.str "Unix socket of the listener.";
                    metrics = field types.bool "Whether the listener serves the metrics without a key.";
                  };
                }
              );
              readOnly = true;
              default = lib.mapAttrs (
                _: listener:
                lib.getAttrs (
                  [ "metrics" ]
                  ++ (
                    if listener.port == null then
                      [ "socket" ]
                    else
                      [
                        "host"
                        "port"
                      ]
                  )
                ) listener
              ) listeners;
              defaultText = lib.literalMD "the `host` and `port`, or the `socket`, and `metrics` of the enabled listeners of `listen`";
              description = ''
                Listeners by name, whose sockets systemd passes by the same
                `FileDescriptorName=`, with the fields llmhop knows of the
                enabled ones of `listen`, which tools such as `llmhopctl`
                read.
              '';
            };
            models = mkOption {
              type = types.attrsOf model;
              default = { };
              description = ''
                Models by the name clients send, into which every workload of
                the backends merges.
              '';
            };
            maxBodyBytes = field types.ints.unsigned "Size of a request body, beyond which it gets `413`, 100 MiB by default, `0` meaning no limit.";
            maxBufferedBytes = field types.ints.unsigned "Bytes of all bodies held in memory at once to read their `model`, beyond which a request gets `503`, 1 GiB by default, `0` meaning no limit.";
            corsOrigins = field (types.listOf types.str) ''
              Origins whose pages may call the API with a bearer key, such as
              `https://chat.example`, or only `*` for every origin, which
              requires `clients` or `clientCredentials`.
            '';
            affinity = field (types.listOf affinitySource) ''
              Sources of the key keeping the requests of a conversation on one
              server, tried in order, each setting exactly one of `header` and
              `body`. `null` keeps llmhop's defaults, while `[ ]` disables
              affinity.
            '';
            clientCredentials = field types.bool ''
              Whether every credential `llmhop.api-key.<client>` of the
              system credential store becomes the client `<client>`, unless
              declared in `clients`. It holds a bare key or a JSON object
              with a `key` and optionally its `policy` and `expiresAt`.
            '';
          };
        };
        default = { };
        example = {
          defaults.models = [ "qwen3-8b" ];
          policies.research = {
            models = [ "qwen3-*" ];
            maxConcurrentRequests = 16;
          };
          clientCredentials = true;
          models."openai/*".urls = [ "https://api.openai.com" ];
        };
        description = ''
          llmhop's JSON config, validated at build time by the binary itself,
          with every workload of the backends as a model. Its `listen` comes
          from the listeners of the gateway. An option left `null` stays out
          of the config, so llmhop's default applies.
        '';
      };

      ctl = {
        enable =
          lib.mkEnableOption "`llmhopctl`, which manages the client keys of `settings.clientCredentials`"
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
                enable = lib.mkEnableOption "the listener" // {
                  default = true;
                };
                metrics = mkOption {
                  type = types.bool;
                  default = false;
                  description = ''
                    Whether the listener serves `/llmhop/metrics` without a
                    key, so it should be a loopback port for Prometheus or a
                    unix socket.
                  '';
                };
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
              };
            }
          )
        );
        default = { };
        example = {
          default.host = "";
          caddy.socketGroup = "caddy";
          prometheus = {
            port = 9464;
            metrics = true;
          };
          ssh.socketGroup = "wheel";
        };
        description = ''
          Listeners of the gateway, each a `llmhop-<name>.socket` unit handing
          its socket to it through socket activation under the name of the
          listener. The `default` one serves port `8080` unless configured
          otherwise, and `metrics` serves the metrics on the unix socket
          `metrics.sock` for the group `wheel` on NixOS, where `llmhopctl top`
          finds it. `settings.clients.<name>.listener` makes the requests on a
          unix socket count as a client's.
        '';
      };
      scrapeConfigs = mkOption {
        type = with types; listOf (attrsOf json);
        readOnly = true;
        default = lib.optional (cfg.active && metricsTargets != [ ]) {
          job_name = "llmhop";
          metrics_path = "/llmhop/metrics";
          static_configs = [ { targets = metricsTargets; } ];
        };
        defaultText = lib.literalMD "the job of the gateway on the ports of `listen` with `metrics`";
        description = ''
          Prometheus scrape jobs of the gateway, for
          `services.prometheus.scrapeConfigs`, on the ports of the listeners
          with `metrics`, or none without one.
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
