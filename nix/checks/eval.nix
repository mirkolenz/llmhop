{
  lib,
  mkEvalCheck,
  nixosSystem,
  pkgs,
  self,
}:
let
  llmhopLib = import ../modules/lib lib;
  # Credentials live outside the Nix store, so only their paths are needed.
  apiKeys = "/run/secrets/api-keys";
  serverConfig = "/run/secrets/server.yaml";
  watermarkKey = "/run/secrets/watermark-key";
  # The fake `package` has no interpreter to check the default against.
  detectorScript = pkgs.writeText "watermark.py" "";
  watermark.algorithm = "dual_key_gumbel";
  watermarkConfig = lib.toJSON watermark;
  pinnedImage = "docker.io/vllm/vllm-openai@sha256:a73fb0b9046fee099f7c1829d2548e6cc1740f4c2776a6855fa659ae5d0deb49";

  # Not `lib.hasInfix`: it compiles the needle into a regex, and `lib.match`
  # rejects patterns carrying store-path context.
  containsAll =
    values: string: lib.all (value: lib.replaceStrings [ value ] [ "" ] string != string) values;

  # Evaluation is what rejects a misconfiguration.
  evaluates = expr: (lib.tryEval (lib.deepSeq expr null)).success;
  # The failing assertions whose message contains `needle`, since a bare
  # system already fails the ones about its file systems and boot loader.
  failing =
    needle: system:
    lib.count (
      assertion: !assertion.assertion && lib.hasInfix needle assertion.message
    ) system.assertions;

  volumeTargets =
    container: map (volume: lib.elemAt (lib.splitString ":" volume) 1) container.containerConfig.Volume;

  # The script a fetcher container mounts.
  fetchScript =
    container:
    lib.readFile (lib.head (lib.splitString ":" (lib.elemAt container.containerConfig.Volume 1)));

  credentialed = {
    credentials = {
      api-keys = apiKeys;
      server-config = serverConfig;
      "llmhop.hf-token" = null;
    };
    settings = {
      config = "\${cred:server-config}";
      api-key-file = "\${cred:api-keys}";
      hf-token-file = "\${cred:llmhop.hf-token}";
    };
  };

  mkSystem =
    llmhopConfig:
    (nixosSystem {
      modules = [
        self.nixosModules.quadlet
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = lib.trivial.release;
          virtualisation.quadlet.enable = true;
          services.llmhop = llmhopConfig;
        }
      ];
    }).config;

  mkQuadlet =
    overrides:
    mkSystem {
      vllm-quadlet = lib.recursiveUpdate {
        enable = true;
        image = "docker.io/vllm/vllm-openai:latest";
        models.test = {
          model = "example/test";
          port = 18001;
        };
      } overrides;
    };

  # Evaluates `credentials` alone, as the option type and `apply` see them.
  credentialsOf =
    credentials:
    (lib.evalModules {
      modules = [
        {
          options.credentials = llmhopLib.credentialsOption;
          config = { inherit credentials; };
        }
      ];
    }).config.credentials;

  fakeVllm = pkgs.writeShellScriptBin "vllm" "exit 0";

  quadlet = mkQuadlet {
    models.test = credentialed // {
      mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
    };
    models.marked = {
      image = pinnedImage;
      model = "example/marked";
      port = 18003;
      inherit watermark;
    };
    detectors.watermark = {
      image = "registry.example/detector:latest";
      tokenizer = "example/test";
      port = 18002;
      inherit watermark;
    };
  };

  # The VM test covers the native llama.cpp path end to end.
  native = mkSystem {
    gateway = {
      type = "builtin";
      builtin = {
        openFirewall = true;
        listen = {
          default.host = "::1";
          caddy.socketGroup = "caddy";
        };
      };
    };
    vllm = {
      enable = true;
      package = fakeVllm;
      fetch.credentials."llmhop.hf-token" = null;
      fetch.environment.HF_TOKEN_PATH = "\${cred:llmhop.hf-token}";
      models = {
        local = {
          model = "/srv/models/local";
          host = "::1";
          port = 21004;
          offline = false;
        };
        test = {
          model = "example/test";
          revision = "v1";
          port = 21001;
        };
        marked = {
          model = "example/marked";
          port = 21003;
          inherit watermark;
          credentials."vllm.watermark-key" = watermarkKey;
        };
      };
      detectors.watermark = {
        tokenizer = "example/test";
        port = 21002;
        script = detectorScript;
        inherit watermark;
      };
    };
  };

  # Without a `port`, workers bind a unix socket below a custom root. `b`
  # sorts after `a` despite being declared first, so it is the one chained on
  # its predecessor.
  sockets = mkSystem {
    gateway = {
      type = "builtin";
      builtin.user = "hop";
    };
    socketDirectory = "/run/sockets/llmhop";
    vllm = {
      enable = true;
      package = fakeVllm;
      models.test.model = "example/test";
    };
    llama-cpp-quadlet = {
      enable = true;
      image = "ghcr.io/ggml-org/llama.cpp:server";
      models = {
        b.model = "example/b";
        a.model = "example/a";
      };
    };
  };

  socketRoot = sockets.systemd.tmpfiles.settings."10-llmhop"."/run/sockets/llmhop";
  socketContainer = sockets.virtualisation.quadlet.containers.llama-cpp-b;
  quadletWorker = quadlet.virtualisation.quadlet.containers.vllm-test;
  quadletImage =
    quadlet.virtualisation.quadlet.images.${lib.removeSuffix ".image" quadletWorker.containerConfig.Image};
  quadletMarked = quadlet.virtualisation.quadlet.containers.vllm-marked;
  quadletDetector = quadlet.virtualisation.quadlet.containers.vllm-detector-watermark;
  nativeWorker = native.systemd.services.vllm-test;
  nativeFetcher = native.systemd.services.vllm-test-fetch;
  nativeMarked = native.systemd.services.vllm-marked;
  nativeDetector = native.systemd.services.vllm-detector-watermark;

  # A model of each engine kind on a port, which every gateway reaches.
  routable = {
    vllm = {
      enable = true;
      package = fakeVllm;
      models.qwen = {
        model = "example/qwen";
        port = 24001;
      };
    };
    sglang-quadlet = {
      enable = true;
      image = "docker.io/lmsysorg/sglang:latest";
      models.llama = {
        model = "example/llama";
        port = 24002;
      };
    };
  };
  mkRoutable = overrides: mkSystem (lib.recursiveUpdate routable overrides);

  smg = mkRoutable {
    gateway = {
      type = "smg";
      smg = {
        package = fakeVllm;
        credentials."smg.api-key" = apiKeys;
        settings.api-key-file = "\${cred:smg.api-key}";
      };
    };
  };
  bifrost = mkRoutable {
    gateway = {
      type = "bifrost-quadlet";
      bifrost-quadlet = {
        image = "docker.io/maximhq/bifrost:v2.3.2";
        environmentFile = "/run/secrets/bifrost.env";
        settings.governance.virtual_keys = [
          {
            id = "default";
            value = "env.BIFROST_VIRTUAL_KEY";
          }
        ];
      };
    };
  };

  # Without a gateway, every model is exposed on its own.
  direct = mkRoutable {
    socketClients = [ "caddy" ];
    vllm.models.qwen = {
      host = "0.0.0.0";
      openFirewall = true;
      credentials."config.yaml" = serverConfig;
      settings.config = "\${cred:config.yaml}";
    };
    sglang-quadlet.models.llama = {
      credentials."config.yaml" = serverConfig;
      settings.config = "\${cred:config.yaml}";
    };
    llama-cpp-quadlet = {
      enable = true;
      image = "ghcr.io/ggml-org/llama.cpp:server";
      models.gemma.model = "example/gemma";
    };
  };
  directWorker = direct.systemd.services.vllm-qwen.serviceConfig;

  tests = {
    testImages = {
      expr = {
        references = lib.sort lib.lessThan (
          map (image: image.imageConfig.Image) (lib.attrValues quadlet.virtualisation.quadlet.images)
        );
        shared =
          quadletWorker.containerConfig.Image
          == quadlet.virtualisation.quadlet.containers.vllm-test-fetch.containerConfig.Image;
        tagged = quadletWorker.containerConfig.AutoUpdate;
        pinned = quadletMarked.containerConfig ? AutoUpdate;
        fetcher = quadlet.virtualisation.quadlet.containers.vllm-test-fetch.containerConfig.AutoUpdate;
        policy = quadletImage.imageConfig ? Policy;
        autoStart = map (unit: unit.autoStart) [
          quadletWorker
          quadlet.virtualisation.quadlet.containers.vllm-test-fetch
          quadletImage
        ];
      };
      expected = {
        references = [
          "docker.io/vllm/vllm-openai:latest"
          pinnedImage
          "registry.example/detector:latest"
        ];
        shared = true;
        tagged = "registry";
        pinned = false;
        fetcher = "disabled";
        policy = false;
        autoStart = [
          true
          false
          false
        ];
      };
    };

    # The VM test covers native sockets with llama.cpp, vLLM binds via `--uds`.
    testSocketRoot = {
      expr = {
        root = {
          inherit (socketRoot.d) mode;
          inherit (socketRoot.a) argument;
        };
        # A custom user is the deployer's to declare.
        declared = sockets.users.users.hop.isSystemUser;
        uds = containsAll [
          "--uds"
          "/run/sockets/llmhop/vllm-test/http.sock"
        ] sockets.systemd.services.vllm-test.serviceConfig.ExecStart;
        routed = sockets.services.llmhop.gateway.builtin.settings.models.test.url;
      };
      expected = {
        root = {
          mode = "0711";
          argument = "default:user:hop:-wx";
        };
        declared = false;
        uds = true;
        routed = "unix:///run/sockets/llmhop/vllm-test/http.sock";
      };
    };

    # A custom worker user is used as given, and the deployer's to declare.
    testIdentity = {
      expr =
        let
          named = mkSystem {
            llama-cpp = {
              enable = true;
              user = "llama";
              models.a.model = "example/a:Q4_K_M";
            };
          };
        in
        {
          inherit (named.systemd.services.llama-cpp-a.serviceConfig) User;
          declared = named.users.users ? llama;
        };
      expected = {
        User = "llama";
        declared = false;
      };
    };

    testListeners = {
      expr = {
        socket = native.systemd.sockets.llmhop-caddy.listenStreams;
        inherit (native.systemd.sockets.llmhop-caddy.socketConfig) SocketGroup RemoveOnStop;
        inherit (native.systemd.services.llmhop.serviceConfig) Sockets;
        firewall = native.networking.firewall.allowedTCPPorts;
        ipv6 = native.systemd.sockets.llmhop-default.listenStreams;
      };
      expected = {
        socket = [ "/run/llmhop/caddy.sock" ];
        SocketGroup = "caddy";
        RemoveOnStop = true;
        Sockets = [
          "llmhop-caddy.socket"
          "llmhop-default.socket"
        ];
        firewall = [ 8080 ];
        ipv6 = [ "[::1]:8080" ];
      };
    };

    testQuadletSocket = {
      expr = {
        inherit (socketContainer.containerConfig)
          Volume
          PodmanArgs
          HealthCmd
          Network
          ;
        inherit (socketContainer.serviceConfig) RuntimeDirectory;
        published = socketContainer.containerConfig ? PublishPort;
        host = containsAll [ "--host /run/llmhop/socket/http.sock" ] socketContainer.containerConfig.Exec;
        after = socketContainer.unitConfig.After;
      };
      expected = {
        Volume = [
          "/var/cache/llama-cpp/b:/var/cache/llama-cpp/b"
          "/var/cache/llama-cpp/b/hub:/var/cache/llama-cpp/b/hub:ro"
          "/run/sockets/llmhop/llama-cpp-b:/run/llmhop/socket:U"
        ];
        PodmanArgs = [ "--umask=0007" ];
        HealthCmd = "curl --fail --silent --show-error --unix-socket /run/llmhop/socket/http.sock http://localhost/health";
        Network = "none";
        RuntimeDirectory = [ "sockets/llmhop/llama-cpp-b" ];
        published = false;
        host = true;
        after = [
          "llama-cpp-b-fetch.service"
          "llama-cpp-a.service"
        ];
      };
    };

    # Paths are loaded, `null` is imported, and references resolve to the
    # container credential directory. The VM test covers the native one.
    testCredentials = {
      expr = {
        quadlet = {
          inherit (quadletWorker.serviceConfig) LoadCredential ImportCredential;
          paths = containsAll [
            "--api-key-file /run/llmhop/credentials/api-keys"
            "--config /run/llmhop/credentials/server-config"
          ] quadletWorker.containerConfig.Exec;
          mount = lib.elem "%d:/run/llmhop/credentials:ro,idmap=uids=0-1000-1;gids=0-1000-1" quadletWorker.containerConfig.Volume;
        };
        invalidName = evaluates (credentialsOf {
          "tls/key" = apiKeys;
        });
        # Anyone on the host can read the Nix store.
        storePath = evaluates (credentialsOf {
          leak = pkgs.writeText "leak" "";
        });
        unknownReference = evaluates (
          llmhopLib.resolveCredentialRefs "/run/credentials/test" { } "\${cred:missing}"
        );
      };
      expected = {
        quadlet = {
          LoadCredential = [
            "api-keys:${apiKeys}"
            "server-config:${serverConfig}"
          ];
          ImportCredential = [ "llmhop.hf-token" ];
          paths = true;
          mount = true;
        };
        invalidName = false;
        storePath = false;
        unknownReference = false;
      };
    };

    # The key reaches vLLM through the script, never the command line.
    testWatermark = {
      expr = {
        quadlet = {
          arguments = containsAll [
            "/run/llmhop/watermark.py serve example/marked"
            (lib.escapeShellArg watermarkConfig)
            "--watermark-key-file /run/llmhop/credentials/vllm.watermark-key"
          ] quadletMarked.containerConfig.Exec;
          inherit (quadletMarked.containerConfig) Entrypoint;
          import = quadletMarked.serviceConfig.ImportCredential;
          # Models without a watermark keep the image's entrypoint.
          plain = quadletWorker.containerConfig.Entrypoint;
        };
        native = {
          command = containsAll [
            "/bin/python"
            "serve"
            "example/marked"
            "--watermark-key-file"
            "%d/vllm.watermark-key"
          ] nativeMarked.serviceConfig.ExecStart;
          load = nativeMarked.serviceConfig.LoadCredential;
        };
        # Each inline key fails its own assertion.
        inline = failing "watermark key inline" (mkQuadlet {
          models.test.watermark.key = 42;
          models.inline = {
            model = "example/inline";
            port = 18004;
            settings.watermark-config = {
              algorithm = "gumbel";
              key = 42;
            };
          };
        });
      };
      expected = {
        quadlet = {
          arguments = true;
          Entrypoint = lib.toJSON [ "python" ];
          import = [ "vllm.watermark-key" ];
          plain = lib.toJSON [
            "vllm"
            "serve"
          ];
        };
        native = {
          command = true;
          load = [ "vllm.watermark-key:${watermarkKey}" ];
        };
        inline = 2;
      };
    };

    testDetector = {
      expr = {
        quadlet = {
          arguments = containsAll [
            "/run/llmhop/watermark.py detect"
            "--watermark-key-file /run/llmhop/credentials/vllm.watermark-key"
            "--tokenizer example/test"
          ] quadletDetector.containerConfig.Exec;
          volumes = volumeTargets quadletDetector;
          port = quadletDetector.containerConfig.PublishPort;
          # Only the tokenizer files, not the weights.
          fetch = containsAll [ "hf download example/test --include '*.json'" ] (
            fetchScript quadlet.virtualisation.quadlet.containers.vllm-detector-watermark-fetch
          );
          # Only llmhop routes it, outside the OpenAI catalog.
          routed = {
            inherit (quadlet.services.llmhop.endpoints.watermark) url unlisted;
          };
        };
        native = {
          command = containsAll [
            "${detectorScript}"
            "detect"
            "--tokenizer"
          ] nativeDetector.serviceConfig.ExecStart;
          # An auxiliary service, so no GPU access and no state directory.
          state = nativeDetector.serviceConfig ? StateDirectory;
          devices = nativeDetector.serviceConfig.PrivateDevices;
        };
        # Both claim the same routing key.
        collision = failing "model `test` is claimed" (mkQuadlet {
          detectors.test = {
            tokenizer = "example/test";
            port = 23002;
          };
        });
      };
      expected = {
        quadlet = {
          arguments = true;
          volumes = [
            "/var/cache/vllm/watermark"
            "/var/cache/vllm/watermark/hub"
            "/run/llmhop/watermark.py"
            "/run/llmhop/credentials"
          ];
          port = [ "127.0.0.1:18002:8000" ];
          fetch = true;
          routed = {
            url = "http://127.0.0.1:18002";
            unlisted = true;
          };
        };
        native = {
          command = true;
          state = false;
          devices = true;
        };
        collision = 1;
      };
    };

    # The fetcher alone gets the fetch credentials and downloads, the server
    # runs offline. The VM test covers the rest with llama.cpp.
    testNativeFetch = {
      expr = {
        script = containsAll [
          "/bin/hf download example/test --revision v1"
        ] nativeFetcher.serviceConfig.ExecStart.text;
        guarded = containsAll [
          "llmhop-hub-cache load /var/lib/vllm/test-fetch"
        ] nativeWorker.serviceConfig.ExecStartPre;
        # Only the fetcher writes the hub cache, which no other workload shares.
        hooks = map (containsAll [
          "llmhop-hub-cache prune"
        ]) nativeFetcher.serviceConfig.ExecStartPost;
        restore = containsAll [
          "llmhop-hub-cache restore /var/lib/vllm/test-fetch/completed"
        ] nativeFetcher.serviceConfig.ExecStopPost;
        inherit (nativeFetcher.environment) HF_HOME HF_TOKEN_PATH;
        inherit (nativeFetcher.serviceConfig) ReadWritePaths;
        inherit (nativeWorker.environment) HF_HUB_OFFLINE;
        inherit (nativeWorker.serviceConfig)
          IPAddressDeny
          ReadOnlyPaths
          Restart
          StateDirectory
          ;
        fetchState = nativeFetcher.serviceConfig.StateDirectory;
        # A local path has nothing to fetch, and this server opted out of
        # the offline mode.
        local = {
          fetcher = native.systemd.services ? vllm-local-fetch;
          restricted = native.systemd.services.vllm-local.serviceConfig ? IPAddressDeny;
          probe = containsAll [ "http://[::1]:21004/health" ] native.systemd.services.vllm-local.postStart;
          inherit (native.systemd.services.vllm-local.environment) HF_HUB_OFFLINE;
        };
      };
      expected = {
        script = true;
        guarded = true;
        hooks = [
          true
          false
        ];
        restore = true;
        HF_HOME = "/var/cache/vllm/test";
        HF_TOKEN_PATH = "%d/llmhop.hf-token";
        ReadWritePaths = [ "/var/cache/vllm/test" ];
        HF_HUB_OFFLINE = "1";
        IPAddressDeny = "any";
        ReadOnlyPaths = [ "/var/cache/vllm/test/hub" ];
        Restart = "always";
        StateDirectory = "vllm/test";
        fetchState = "vllm/test-fetch";
        local = {
          fetcher = false;
          restricted = false;
          probe = true;
          HF_HUB_OFFLINE = "1";
        };
      };
    };

    # A container wants its fetcher, which restarts it after a change.
    testQuadletFetch = {
      expr = {
        inherit (quadletWorker.unitConfig) Wants;
        hook = containsAll [ "llmhop-hub-cache apply vllm-test /var/lib/vllm/test-fetch" ] (
          toString quadlet.virtualisation.quadlet.containers.vllm-test-fetch.serviceConfig.ExecStartPost
        );
        offline = lib.elem (lib.toJSON "HF_HUB_OFFLINE=1") quadletWorker.containerConfig.Environment;
      };
      expected = {
        Wants = [ "vllm-test-fetch.service" ];
        hook = true;
        offline = true;
      };
    };

    # External gateways use upstream secret interfaces and reject models
    # they cannot route or clients could bypass.
    testGateways = {
      expr = {
        smg = containsAll [
          ''"--api-key-file" "%d/smg.api-key"''
          ''"--discovery-provider" "file"''
          ''"--host" "127.0.0.1" "--port" "8080"''
        ] smg.systemd.services.smg.serviceConfig.ExecStart;
        bifrost = {
          inherit (bifrost.virtualisation.quadlet.containers.bifrost.finalConfig.Service)
            Restart
            RestartSec
            ;
          providers = lib.mapAttrs (
            _: provider: lib.concatMap (key: key.models) provider.keys
          ) bifrost.services.llmhop.gateway.bifrost-quadlet.settings.providers;
          inherit (bifrost.virtualisation.quadlet.containers.bifrost.containerConfig) EnvironmentFile;
          entrypoint = bifrost.virtualisation.quadlet.containers.bifrost.containerConfig ? Entrypoint;
        };
        rejected = failing "is routed by the gateway" (mkRoutable {
          gateway = {
            type = "smg";
            smg.package = fakeVllm;
          };
          vllm.models.qwen.openFirewall = true;
        });
        socket = failing "cannot reach" (mkRoutable {
          gateway = {
            type = "bifrost";
            bifrost.package = fakeVllm;
          };
          vllm.models.local.model = "example/local";
        });
      };
      expected = {
        smg = true;
        bifrost = {
          Restart = "on-failure";
          RestartSec = 5;
          providers = {
            vllm = [ "qwen" ];
            sgl = [ "llama" ];
          };
          EnvironmentFile = [ "/run/secrets/bifrost.env" ];
          entrypoint = false;
        };
        rejected = 1;
        socket = 1;
      };
    };

    # Without a gateway, each model binds its own `host`, opens its port and
    # checks its own API key, which never enters a command line.
    testDirect = {
      expr = {
        firewall = direct.networking.firewall.allowedTCPPorts;
        vllm = containsAll [
          ''"${fakeVllm}/bin/vllm" "serve" "example/qwen"''
          ''"--config" "%d/config.yaml"''
          "0.0.0.0"
        ] directWorker.ExecStart;
        filtered = directWorker ? IPAddressDeny;
        probe = containsAll [ "http://127.0.0.1:24001/health" ] direct.systemd.services.vllm-qwen.postStart;
        sglang = lib.fromJSON direct.virtualisation.quadlet.containers.sglang-llama.containerConfig.Entrypoint;
        acl = direct.systemd.tmpfiles.settings."10-llmhop"."/run/llmhop".a.argument;
      };
      expected = {
        firewall = [ 24001 ];
        vllm = true;
        filtered = false;
        probe = true;
        sglang = [
          "sglang"
          "serve"
        ];
        acl = "default:user:caddy:-wx";
      };
    };

    # A native backend and its Quadlet twin share the update unit, and here
    # also a port, while each workload has its own cache directory.
    testTwinBackends = {
      expr = failing "is claimed by" (mkSystem {
        vllm = {
          enable = true;
          package = fakeVllm;
          models.native = {
            model = "example/test";
            port = 22001;
          };
        };
        vllm-quadlet = {
          enable = true;
          image = "docker.io/vllm/vllm-openai:latest";
          models.container = {
            model = "example/test";
            port = 22001;
          };
        };
      });
      expected = 2;
    };

    # The listener and the derived flags win over `settings`, so gateways and
    # the health probe reach the server where it listens, by the name it
    # serves.
    testManagedSettings = {
      expr =
        let
          ExecStart =
            (mkSystem {
              vllm = {
                enable = true;
                package = fakeVllm;
                modelSettings.host = "0.0.0.0";
                models.test = {
                  model = "example/test";
                  port = 25001;
                  settings = {
                    port = 25002;
                    served-model-name = "other";
                  };
                };
              };
            }).systemd.services.vllm-test.serviceConfig.ExecStart;
        in
        {
          managed = containsAll [
            ''"--host" "127.0.0.1"''
            ''"--port" "25001"''
            ''"--served-model-name" "test"''
          ] ExecStart;
          overridden = lib.any (value: containsAll [ value ] ExecStart) [
            "0.0.0.0"
            "25002"
            "other"
          ];
        };
      expected = {
        managed = true;
        overridden = false;
      };
    };
  };

  units = pkgs.symlinkJoin {
    name = "llmhop-generated-units";
    paths =
      quadlet.virtualisation.quadlet.generatedUnits
      ++ sockets.virtualisation.quadlet.generatedUnits
      ++ bifrost.virtualisation.quadlet.generatedUnits;
  };

  result = pkgs.runCommand "llmhop-eval-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-detector-watermark.service
    test -e ${units}/lib/systemd/system/llama-cpp-b.service
    test -e ${units}/lib/systemd/system/bifrost.service
    grep -q '^Requires=${quadletImage.serviceName}.service$' ${units}/lib/systemd/system/vllm-test.service
    touch $out
  '';
in
mkEvalCheck {
  description = "Module evaluation tests";
  output = result;
  inherit tests;
}
