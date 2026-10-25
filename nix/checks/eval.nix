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

  vllmQuadlet = overrides: {
    vllm-quadlet = lib.recursiveUpdate {
      enable = true;
      tag = "latest";
      models.test = {
        model = "example/test";
        port = 18001;
      };
    } overrides;
  };
  mkQuadlet = overrides: mkSystem (vllmQuadlet overrides);

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

  # Both Quadlet backends that bind ports.
  quadlet = mkSystem (
    vllmQuadlet {
      cache.mountOptions = [ "idmap" ];
      modelSettings.max-model-len = 4096;
      models.test = credentialed // {
        mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
      };
      models.marked = {
        model = "example/marked";
        port = 18003;
        inherit watermark;
        settings.served-model-name = "renamed";
      };
      detectors.watermark = {
        tokenizer = "example/test";
        port = 18002;
        inherit watermark;
      };
    }
    // {
      llama-cpp-quadlet = {
        enable = true;
        tag = "server";
        models.test = {
          port = 20001;
          model = "example/test:Q4_K_M";
        };
      };
    }
  );

  # The native backends beside llmhop's own native.
  native = mkSystem {
    enable = true;
    openFirewall = true;
    host = "::1";
    listen.caddy.socketGroup = "caddy";
    llama-cpp = {
      enable = true;
      models.a.model = "example/a:Q4_K_M";
    };
    vllm = {
      enable = true;
      package = fakeVllm;
      fetch.credentials."llmhop.hf-token" = null;
      fetch.environment.HF_TOKEN_PATH = "\${cred:llmhop.hf-token}";
      models.local = {
        model = "/srv/models/local";
        port = 21004;
        offline = false;
      };
      models.test = credentialed // {
        model = "example/test";
        revision = "v1";
        port = 21001;
      };
      models.marked = {
        model = "example/marked";
        port = 21003;
        inherit watermark;
        credentials."vllm.watermark-key" = watermarkKey;
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
    enable = true;
    socketDirectory = "/run/sockets/llmhop";
    user = "hop";
    vllm = {
      enable = true;
      package = fakeVllm;
      models.test.model = "example/test";
    };
    llama-cpp-quadlet = {
      enable = true;
      tag = "server";
      models = {
        b = {
          model = "example/b";
          mountOptions.socket = [
            "U"
            "z"
          ];
        };
        a.model = "example/a";
      };
    };
  };

  socketRoot = sockets.systemd.tmpfiles.settings."10-llmhop"."/run/sockets/llmhop";
  socketWorker = sockets.systemd.services.vllm-test;
  socketContainer = sockets.virtualisation.quadlet.containers.llama-cpp-b;
  quadletWorker = quadlet.virtualisation.quadlet.containers.vllm-test;
  quadletMarked = quadlet.virtualisation.quadlet.containers.vllm-marked;
  quadletDetector = quadlet.virtualisation.quadlet.containers.vllm-detector-watermark;
  quadletFetcher = quadlet.virtualisation.quadlet.containers.vllm-test-fetch;
  llamaCppWorker = quadlet.virtualisation.quadlet.containers.llama-cpp-test;
  nativeWorker = native.systemd.services.vllm-test;
  nativeFetcher = native.systemd.services.vllm-test-fetch;
  nativeMarked = native.systemd.services.vllm-marked;
  nativeDetector = native.systemd.services.vllm-detector-watermark;

  tests = {
    testSocketRoot = {
      expr = {
        root = {
          inherit (socketRoot.d) mode;
          inherit (socketRoot.a) argument;
        };
        # A custom user is the deployer's to declare.
        declared = sockets.users.users ? hop;
      };
      expected = {
        root = {
          mode = "0711";
          argument = "default:user:hop:-wx";
        };
        declared = false;
      };
    };

    testIdentity = {
      expr =
        let
          default = native;
          named = mkSystem {
            llama-cpp = {
              enable = true;
              user = "llama";
              models.a.model = "example/a:Q4_K_M";
            };
          };
        in
        {
          default = {
            inherit (default.systemd.services.llama-cpp-a.serviceConfig) User Group;
            # The fetcher shares the identity, and thereby the cache, of its server.
            fetcher = default.systemd.services.llama-cpp-a-fetch.serviceConfig.User;
            declared = default.users.users ? llama-cpp;
          };
          named = {
            inherit (named.systemd.services.llama-cpp-a.serviceConfig) User;
            declared = named.users.users ? llama;
          };
        };
      expected = {
        default = {
          User = "llama-cpp";
          Group = "llama-cpp";
          fetcher = "llama-cpp";
          declared = true;
        };
        named = {
          User = "llama";
          declared = false;
        };
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

    # A native server is supervised by its `postStart` health check, binds its
    # socket in a network namespace of its own, and llmhop joins its group.
    testNativeSocket = {
      expr = {
        command = containsAll [
          "--uds"
          "/run/sockets/llmhop/vllm-test/http.sock"
        ] socketWorker.serviceConfig.ExecStart;
        tcp = containsAll [ "--port" ] socketWorker.serviceConfig.ExecStart;
        health = containsAll [
          "--unix-socket /run/sockets/llmhop/vllm-test/http.sock http://localhost/health"
        ] socketWorker.postStart;
        inherit (socketWorker.serviceConfig)
          Type
          UMask
          RuntimeDirectory
          PrivateNetwork
          ;
        routed = sockets.services.llmhop.settings.models.test.url;
        joined = sockets.systemd.services.llmhop.serviceConfig.SupplementaryGroups;
      };
      expected = {
        command = true;
        tcp = false;
        health = true;
        Type = "exec";
        UMask = "0007";
        RuntimeDirectory = [ "sockets/llmhop/vllm-test" ];
        PrivateNetwork = true;
        routed = "unix:///run/sockets/llmhop/vllm-test/http.sock";
        joined = [ "vllm" ];
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
          "/var/cache/llama-cpp:/var/cache/llama-cpp:ro"
          "/var/cache/llama-cpp-b:/var/cache/llama-cpp-b"
          "/run/sockets/llmhop/llama-cpp-b:/run/llmhop/socket:U,z"
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
    # native or the container credential directory.
    testCredentials = {
      expr = {
        native = {
          inherit (nativeWorker.serviceConfig) LoadCredential ImportCredential;
          paths = containsAll [
            "%d/api-keys"
            "%d/server-config"
            "%d/llmhop.hf-token"
          ] nativeWorker.serviceConfig.ExecStart;
          # A doubled `%` would pass the specifier on as a literal.
          escaped = containsAll [ "%%d" ] nativeWorker.serviceConfig.ExecStart;
        };
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
        native = {
          LoadCredential = [
            "api-keys:${apiKeys}"
            "server-config:${serverConfig}"
          ];
          ImportCredential = [ "llmhop.hf-token" ];
          paths = true;
          escaped = false;
        };
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

    # The derived flags are defaults, under `modelSettings` and per-model
    # `settings`.
    testSettings = {
      expr = {
        derived = containsAll [
          "--served-model-name test"
          "--max-model-len 4096"
          "--host 0.0.0.0"
          "--port 8000"
        ] quadletWorker.containerConfig.Exec;
        overridden = containsAll [ "--served-model-name renamed" ] quadletMarked.containerConfig.Exec;
      };
      expected = {
        derived = true;
        overridden = true;
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
          plain = quadletWorker.containerConfig ? Entrypoint;
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
          plain = false;
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
          # Reachable through llmhop, but kept out of the OpenAI catalog.
          routed = quadlet.services.llmhop.settings.models.watermark;
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
            "/var/cache/vllm"
            "/var/cache/vllm-detector-watermark"
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

    testLlamaCpp = {
      expr = {
        inherit (llamaCppWorker.containerConfig) PublishPort Image;
        pulled = quadlet.virtualisation.quadlet.images.llama-cpp-server.imageConfig.Image;
        arguments = containsAll [
          "--alias test"
          "--hf-repo example/test:Q4_K_M"
          "--offline"
        ] llamaCppWorker.containerConfig.Exec;
        fetch = fetchScript quadlet.virtualisation.quadlet.containers.llama-cpp-test-fetch;
      };
      expected = {
        Image = "llama-cpp-server.image";
        pulled = "ghcr.io/ggml-org/llama.cpp:server";
        PublishPort = [ "127.0.0.1:20001:8080" ];
        arguments = true;
        fetch = ''
          set -e
          /app/llama download -hf example/test:Q4_K_M || test -d /var/cache/llama-cpp/hub/models--example--test/refs
        '';
      };
    };

    # The fetcher alone gets the fetch credentials and downloads, the server
    # runs offline. The VM test covers the rest with llama.cpp.
    testNativeFetch = {
      expr = {
        script = containsAll [
          "/bin/hf download example/test --revision v1 || test -e /var/cache/vllm/hub/models--example--test/refs/v1 || test -d /var/cache/vllm/hub/models--example--test/snapshots/v1"
        ] nativeFetcher.serviceConfig.ExecStart.text;
        inherit (nativeFetcher.environment) HF_TOKEN_PATH;
        inherit (nativeWorker.environment) HF_HUB_OFFLINE;
        inherit (nativeWorker.serviceConfig) IPAddressDeny Restart;
        # A local path has nothing to fetch, and this server opted out of
        # the offline mode.
        local = {
          fetcher = native.systemd.services ? vllm-local-fetch;
          restricted = native.systemd.services.vllm-local.serviceConfig ? IPAddressDeny;
          inherit (native.systemd.services.vllm-local.environment) HF_HUB_OFFLINE;
        };
      };
      expected = {
        script = true;
        HF_TOKEN_PATH = "%d/llmhop.hf-token";
        HF_HUB_OFFLINE = "1";
        IPAddressDeny = "any";
        Restart = "always";
        local = {
          fetcher = false;
          restricted = false;
          HF_HUB_OFFLINE = "1";
        };
      };
    };

    # The image unit pulls for both, the fetcher restarts its server.
    testQuadletFetch = {
      expr = {
        inherit (quadletWorker.containerConfig) Image Pull AutoUpdate;
        inherit (quadlet.virtualisation.quadlet.images.vllm-latest.imageConfig) Policy;
        inherit (quadletWorker.unitConfig) Wants;
        offline = lib.elem (lib.toJSON "HF_HUB_OFFLINE=1") quadletWorker.containerConfig.Environment;
        fetcher = {
          inherit (quadletFetcher.containerConfig) Image;
          inherit (quadletFetcher.serviceConfig) Type RemainAfterExit;
          volume = lib.elem "/var/cache/vllm:/var/cache/vllm:idmap" quadletFetcher.containerConfig.Volume;
          hooks = containsAll [
            "llmhop-fetch-hook apply vllm-test.service /var/cache/vllm/hub/models--example--test"
          ] (toString quadletFetcher.serviceConfig.ExecStartPost);
        };
      };
      expected = {
        Image = "vllm-latest.image";
        Pull = "never";
        AutoUpdate = "registry";
        Policy = "newer";
        Wants = [ "vllm-test-fetch.service" ];
        offline = true;
        fetcher = {
          Image = "vllm-latest.image";
          Type = "oneshot";
          RemainAfterExit = true;
          volume = true;
          hooks = true;
        };
      };
    };

    # A native backend and its Quadlet twin share the cache directory and the
    # update unit, and here also a port.
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
          tag = "latest";
          models.container = {
            model = "example/test";
            port = 22001;
          };
        };
      });
      expected = 3;
    };
  };

  units = pkgs.symlinkJoin {
    name = "llmhop-generated-units";
    paths =
      quadlet.virtualisation.quadlet.generatedUnits ++ sockets.virtualisation.quadlet.generatedUnits;
  };

  result = pkgs.runCommand "llmhop-eval-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-detector-watermark.service
    test -e ${units}/lib/systemd/system/llama-cpp-b.service
    grep -q '^Requires=vllm-latest-image.service$' ${units}/lib/systemd/system/vllm-test.service
    touch $out
  '';
in
mkEvalCheck {
  description = "Module evaluation tests";
  output = result;
  inherit tests;
}
