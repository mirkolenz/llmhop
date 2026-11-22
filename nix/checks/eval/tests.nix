# What the modules render for each runtime, beyond the assertions.
{
  util,
  apiKeys,
  serverConfig,
  watermarkKey,
  containsAll,
  evaluates,
  credentialsOf,
  containers,
  containerWorker,
  containerMarked,
  containerDetector,
  unmappedWorker,
  native,
  nativeWorker,
  nativeFetcher,
  nativeDetector,
  nvidia,
  sockets,
  socketRules,
  exposedWorker,
  managed,
  routable,
  routedModels,
  lib,
  pkgs,
  ...
}:
{
  # Every container runs in its own user namespace, whose writable and
  # root-owned mounts are idmapped, unless left to `container.config`. The
  # bundle and VM tests check the default further.
  testUserNamespace = {
    expr = {
      worker = containerWorker.containerConfig.UserNS;
      unmapped = {
        inherit (unmappedWorker) UIDMap;
        userNS = unmappedWorker ? UserNS;
        volumes = unmappedWorker.Volume;
      };
    };
    expected = {
      worker = "auto:size=65536";
      unmapped = {
        UIDMap = [ "0:100000:65536" ];
        userNS = false;
        volumes = [
          "vllm-test:/var/cache/llmhop"
          "%d:/run/llmhop/credentials:ro"
        ];
      };
    };
  };

  # Paths are loaded, `null` is imported, and references resolve to the
  # credential directory, never a value on the command line.
  testCredentials = {
    expr = {
      inherit (containerWorker.serviceConfig) LoadCredential ImportCredential;
      paths = containsAll [
        "--api-key-file /run/llmhop/credentials/api-keys"
        "--config /run/llmhop/credentials/server-config"
      ] containerWorker.containerConfig.Exec;
      mount = lib.elem "%d:/run/llmhop/credentials:ro,idmap" containerWorker.containerConfig.Volume;
      invalidName = evaluates (credentialsOf {
        "tls/key" = apiKeys;
      });
      # Anyone on the host can read the Nix store.
      storePath = evaluates (credentialsOf {
        leak = pkgs.writeText "leak" "";
      });
      unknownReference = evaluates (
        util.resolveCredentialRefs "/run/credentials/test" { } "\${cred:missing}"
      );
      environment = {
        containerApiKeyFile = lib.elem ''"API_KEY_FILE=/run/llmhop/credentials/api-keys"'' containerWorker.containerConfig.Environment;
        containerCredentialsDirectory = lib.elem ''"CREDENTIALS_DIRECTORY=/run/llmhop/credentials"'' containerWorker.containerConfig.Environment;
        native = nativeWorker.environment.API_KEY_FILE;
      };
    };
    expected = {
      LoadCredential = [
        "api-keys:${apiKeys}"
        "server-config:${serverConfig}"
      ];
      ImportCredential = [ "llmhop.hf-token" ];
      paths = true;
      mount = true;
      invalidName = false;
      storePath = false;
      unknownReference = false;
      environment = {
        containerApiKeyFile = true;
        containerCredentialsDirectory = true;
        native = "%d/api-keys";
      };
    };
  };

  testWatermark = {
    expr = {
      vllm = {
        entrypoint = containerMarked.containerConfig.Entrypoint;
        config = containsAll [
          "--watermark-config '{\"algorithm\":\"dual_key_gumbel\",\"key_file\":\"/run/llmhop/credentials/vllm.watermark-key\"}'"
        ] containerMarked.containerConfig.Exec;
        inherit (containerMarked.serviceConfig) ImportCredential;
        native = native.systemd.services.vllm-marked.serviceConfig.LoadCredential;
      };
      sglang =
        let
          service = routable.systemd.services.sglang-llama;
          start = service.serviceConfig.ExecStart;
        in
        {
          serve = containsAll [
            "/bin/python\" \"/nix/store/"
            "-sglang-watermark.py\" \"serve\" \"example/llama\""
            ''"--enable-watermark"''
            ''"--watermark-key-file" "%d/sglang.watermark-key"''
            ''"--watermark-key-b-file" "%d/sglang.watermark-key-b"''
            ''"--watermark-settings" "{\"context_window\":4}"''
          ] start;
          inherit (service.serviceConfig) ImportCredential;
        };
    };
    expected = {
      vllm = {
        entrypoint = ''["vllm","serve","example/marked"]'';
        config = true;
        ImportCredential = [ "vllm.watermark-key" ];
        native = [ "vllm.watermark-key:${watermarkKey}" ];
      };
      sglang = {
        serve = true;
        ImportCredential = [
          "sglang.watermark-key"
          "sglang.watermark-key-b"
        ];
      };
    };
  };

  testDetector = {
    expr = {
      entrypoint = containerDetector.containerConfig.Entrypoint;
      profiles = containsAll [
        "--engine vllm"
        ''"key_file":"/run/llmhop/credentials/vllm.watermark-key"''
        ''"key_file":"/run/llmhop/credentials/vllm.watermark-key.retired"''
      ] containerDetector.containerConfig.Exec;
      import = containerDetector.serviceConfig.ImportCredential;
      # Only the tokenizer files, not the weights.
      fetch = containsAll [
        "hf download example/test --revision v1 --include '*.json'"
      ] native.systemd.services.vllm-watermark-fetch.serviceConfig.ExecStart.text;
      # Routed outside the OpenAI catalog.
      routed = native.services.llmhop.gateway.settings.models.watermark.unlisted;
      # An auxiliary service, so no GPU access and no state directory.
      state = nativeDetector.serviceConfig ? StateDirectory;
      devices = nativeDetector.serviceConfig.PrivateDevices;
      modelDeviceAllow = nativeWorker.serviceConfig.DeviceAllow;
      containerModelDevices = containerWorker.containerConfig.AddDevice;
    };
    expected = {
      entrypoint = ''["python","/run/llmhop/watermark.py","detect"]'';
      profiles = true;
      import = [
        "vllm.watermark-key"
        "vllm.watermark-key.retired"
      ];
      fetch = true;
      routed = true;
      state = false;
      devices = true;
      modelDeviceAllow = [ "char-nvidia" ];
      containerModelDevices = [ "nvidia.com/gpu=0" ];
    };
  };

  testFetch = {
    expr = {
      script = containsAll [
        "/bin/hf download example/test --revision v1"
      ] nativeFetcher.serviceConfig.ExecStart.text;
      token = containsAll [
        ''HF_TOKEN=$(cat "$token")''
      ] nativeFetcher.serviceConfig.ExecStart.text;
      inherit (nativeFetcher.serviceConfig) ImportCredential;
      inherit (nativeWorker.environment) HF_HUB_OFFLINE;
      # Each engine gets only its own switch.
      llamaOffline = sockets.systemd.services.llama-cpp-a.environment.LLAMA_ARG_OFFLINE;
      vllmOffline = nativeWorker.environment ? LLAMA_ARG_OFFLINE;
      inherit (nativeWorker.serviceConfig) ReadOnlyPaths;
      container = {
        inherit (containerWorker.unitConfig) Wants;
        offline = lib.any (lib.hasInfix "HF_HUB_OFFLINE") containerWorker.containerConfig.Environment;
        fetcher = containers ? vllm-test-fetch;
      };
    };
    expected = {
      script = true;
      token = true;
      ImportCredential = [ "llmhop.hf-token" ];
      HF_HUB_OFFLINE = "1";
      llamaOffline = "1";
      vllmOffline = false;
      ReadOnlyPaths = [ "/var/cache/vllm/test/hub" ];
      container = {
        Wants = [ "vllm-marked.service" ];
        offline = false;
        fetcher = false;
      };
    };
  };

  testSockets = {
    expr = {
      inherit (socketRules.d) mode;
      uds = containsAll [
        ''"--uds" "/run/sockets/llmhop/vllm-test/http.sock"''
      ] sockets.systemd.services.vllm-test.serviceConfig.ExecStart;
      routed = sockets.services.llmhop.gateway.settings.models.test.urls;
      groups = sockets.users.users.hop.extraGroups;
      after = sockets.systemd.services.llama-cpp-b.after;
    };
    expected = {
      mode = "0711";
      uds = true;
      routed = [ "unix:///run/sockets/llmhop/vllm-test/http.sock" ];
      groups = [
        "llama-cpp"
        "vllm"
      ];
      after = [
        "llama-cpp-b-fetch.service"
        "llama-cpp-b-refresh.service"
        "llama-cpp-a.service"
      ];
    };
  };

  testLora = {
    expr = {
      vllm = containsAll [
        ''"--data-parallel-size" "2"''
        ''"--enable-lora"''
        ''"--lora-modules" "{\"name\":\"qwen-sql\",\"path\":\"example/sql-lora\"}"''
      ] routable.systemd.services.vllm-qwen.serviceConfig.ExecStart;
      sglang = containsAll [
        ''"--data-parallel-size" "4"''
        ''"--lora-paths" "{\"lora_name\":\"llama-sql\",\"lora_path\":\"example/llama-lora\"}"''
        ''"--model-type" "llm"''
      ] routable.systemd.services.sglang-llama.serviceConfig.ExecStart;
      fetched = containsAll [
        "hf download example/llama"
        "hf download example/llama-lora"
      ] routable.systemd.services.sglang-llama-fetch.serviceConfig.ExecStart.text;
      routed = lib.mapAttrs (_: model: {
        inherit (model) aliases dataParallelSize;
      }) routedModels;
      kernels = routable.systemd.services.sglang-llama.environment.SGLANG_USE_SGL_FA3_KERNEL;
    };
    expected = {
      vllm = true;
      sglang = true;
      fetched = true;
      routed = {
        qwen = {
          aliases.qwen-sql = { };
          dataParallelSize = 2;
        };
        llama = {
          aliases.llama-sql.model = "llama:llama-sql";
          dataParallelSize = 4;
        };
      };
      kernels = "1";
    };
  };

  # An offline native server is isolated and starts without the network,
  # which an online one waits for.
  testOfflineNetwork = {
    expr =
      lib.mapAttrs
        (_: worker: {
          online = lib.elem "network-online.target" worker.wants;
          isolated = worker.serviceConfig ? PrivateNetwork || worker.serviceConfig ? IPAddressDeny;
        })
        {
          loopback = nativeWorker;
          socket = sockets.systemd.services.vllm-test;
          exposed = exposedWorker;
        };
    expected = {
      loopback = {
        online = false;
        isolated = true;
      };
      socket = {
        online = false;
        isolated = true;
      };
      exposed = {
        online = true;
        isolated = false;
      };
    };
  };

  testManagedSettings = {
    expr = containsAll [
      ''"--host" "127.0.0.1"''
      ''"--port" "25001"''
      ''"--served-model-name" "test"''
      ''"--max-model-len" "4096"''
      ''"--max-num-seqs" "8"''
      ''"--shutdown-timeout" "10"''
    ] managed;
    expected = true;
  };

  # A stopped server drains its requests before it is killed, natively
  # by SIGTERM, in a container by Podman, which systemd waits for.
  testShutdown = {
    expr = {
      native = {
        inherit (nativeWorker.serviceConfig) TimeoutStopSec;
        signal = nativeWorker.serviceConfig ? KillSignal;
      };
      container = {
        inherit (containerWorker.containerConfig) StopTimeout;
        inherit (containerWorker.serviceConfig) TimeoutStopSec;
      };
    };
    expected = {
      native = {
        TimeoutStopSec = 20;
        signal = false;
      };
      container = {
        StopTimeout = 20;
        TimeoutStopSec = 30;
      };
    };
  };

  # llama.cpp reads no config file beside its arguments, neither its server
  # nor its fetcher.
  testImplicitConfig = {
    expr = lib.mapAttrs (_: service: {
      inherit (service.environment) XDG_CONFIG_HOME;
      hidden = lib.elem "-/etc/llama.cpp" service.serviceConfig.InaccessiblePaths;
    }) { inherit (sockets.systemd.services) llama-cpp-a llama-cpp-a-fetch; };
    expected = lib.genAttrs [ "llama-cpp-a" "llama-cpp-a-fetch" ] (_: {
      XDG_CONFIG_HOME = "/var/empty";
      hidden = true;
    });
  };

  testNvidiaDevices = {
    expr = nvidia.systemd.services.vllm-test.serviceConfig.DeviceAllow;
    expected = [
      "char-nvidia"
      "char-nvidiactl"
      "char-nvidia-uvm"
    ];
  };

  # Every consumer reads the typed records, whose capabilities say what a
  # workload needs, and a quantization tag stays off the repository.
  testRecords = {
    expr =
      let
        llama = lib.findFirst (w: w.name == "b") null sockets.services.llmhop.llama-cpp.workloads;
        detector = lib.findFirst (w: w.name == "watermark") null native.services.llmhop.vllm.workloads;
      in
      {
        repositories = map (r: { inherit (r) repo tag; }) llama.repositories;
        fetch = containsAll [
          "download -hf example/b:Q4_K_M"
        ] sockets.systemd.services.llama-cpp-b-fetch.serviceConfig.ExecStart.text;
        capabilities = {
          inherit (llama) chained unlisted;
          gpu = llama.gpu != null;
          detector = {
            inherit (detector) chained unlisted;
            gpu = detector.gpu;
          };
        };
      };
    expected = {
      repositories = [
        {
          repo = "example/b";
          tag = "Q4_K_M";
        }
      ];
      fetch = true;
      capabilities = {
        chained = true;
        unlisted = false;
        gpu = true;
        detector = {
          chained = false;
          unlisted = true;
          gpu = null;
        };
      };
    };
  };
}
