{
  lib,
  mkEvalCheck,
  nixosSystem,
  pkgs,
  self,
  stdenv,
}:
let
  llmhopLib = import ../modules/lib.nix lib;
  # Credentials live outside the Nix store, so only their paths are needed.
  apiKeys = "/run/secrets/api-keys";
  # The fake `package` has no interpreter to check the default against.
  detectorScript = pkgs.writeText "watermark.py" "";
  watermarkKey = "/run/secrets/watermark-key";
  # Shared by generating workers and detectors, as a deployment would, with
  # the key imported from the system credential store.
  watermark.algorithm = "dual_key_gumbel";
  watermarkConfig = lib.toJSON watermark;
  serverConfig = "/run/secrets/server.yaml";
  tlsKey = "/run/secrets/tls-key.cred";
  # Not `lib.hasInfix`: it compiles the needle into a regex, and `lib.match`
  # rejects patterns carrying store-path context. Literal replacement has no
  # such restriction, so store paths can be matched directly.
  containsAll =
    values: string: lib.all (value: lib.replaceStrings [ value ] [ "" ] string != string) values;

  # Evaluation is what rejects a misconfiguration, so these two say what the
  # tests are really asking: whether it got through.
  evaluates = expr: (lib.tryEval (lib.deepSeq expr null)).success;

  volumeTargets =
    container: map (volume: lib.elemAt (lib.splitString ":" volume) 1) container.containerConfig.Volume;

  accepts = system: lib.all (assertion: assertion.assertion) system.assertions;

  # Both backends render the same credentials through the same helpers, so they
  # are stated once and asserted on twice.
  credentialed = {
    credentials = {
      api-keys = apiKeys;
      server-config = serverConfig;
      tls-key = {
        source = tlsKey;
        encrypted = true;
      };
    };
    settings = {
      config = "\${cred:server-config}";
      api-key-file = "\${cred:api-keys}";
      ssl-keyfile = "\${cred:tls-key}";
    };
  };

  mkSystem =
    llmhopConfig:
    (nixosSystem {
      system = stdenv.hostPlatform.system;
      modules = [
        self.nixosModules.quadlet
        {
          system.stateVersion = lib.trivial.release;
          virtualisation.quadlet.enable = true;
          services.llmhop = llmhopConfig;
        }
      ];
    }).config;

  mkConfig =
    backendConfig:
    mkSystem {
      vllm-quadlet = lib.recursiveUpdate {
        enable = true;
        tag = "latest";
        models.test = {
          model = "example/test";
          port = 18001;
        };
      } backendConfig;
    };

  rootful = mkConfig {
    cache = {
      containerDirectory = "/cache";
      mountOptions = [
        "idmap"
        "Z"
      ];
    };
    quadlet = {
      containerConfig = {
        User = "2000";
        UserNS = "auto:size=65536";
      };
      serviceConfig.MemoryMax = "64G";
      unitConfig.StartLimitBurst = 7;
      quadletConfig.DefaultDependencies = false;
    };
    models.test = credentialed // {
      quadlet.containerConfig.User = "1000";
      quadlet.mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
    };
    models.marked = {
      model = "example/marked";
      port = 18003;
      inherit watermark;
    };
    detectors.watermark = {
      tokenizer = "example/test";
      port = 18002;
      inherit watermark;
    };
  };

  rootless = mkConfig {
    quadlet.user.uid = 503;
  };

  sglang = mkSystem {
    sglang-quadlet = {
      enable = true;
      tag = "latest";
      quadlet.containerConfig.UserNS = "host";
      models.test = {
        model = "example/test";
        port = 19001;
      };
      gateway = {
        enable = true;
        bindAddress = "192.0.2.1";
        port = 19000;
        credentials.tls-key = tlsKey;
        settings.tls-cert-path = "/etc/sglang/tls/server.crt";
        settings.tls-key-path = "\${cred:tls-key}";
        quadlet.containerConfig.User = "1000";
        quadlet.mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
      };
    };
  };

  sglangNoTLS = mkSystem {
    sglang-quadlet = {
      enable = true;
      tag = "latest";
      gateway = {
        enable = true;
        bindAddress = "::";
        port = 19010;
        settings.tls-cert-path = null;
      };
    };
  };

  llamaCpp = mkSystem {
    llama-cpp-quadlet = {
      enable = true;
      tag = "server";
      models.test = {
        port = 20001;
        settings.hf-repo = "example/test";
      };
    };
  };

  nativeVllm = mkSystem {
    vllm = {
      enable = true;
      uid = 504;
      package = pkgs.writeShellScriptBin "vllm" "exit 0";
      models.test = credentialed // {
        model = "example/test";
        port = 21001;
        serviceConfig.LoadCredential = [ "manual:/run/manual" ];
      };
      models.marked = {
        model = "example/marked";
        port = 21003;
        inherit watermark;
        # Loaded from a file instead of the credential store.
        credentials."vllm.watermark-key" = watermarkKey;
      };
      detectors.watermark = {
        tokenizer = "example/test";
        port = 21002;
        script = detectorScript;
        inherit watermark;
        # Must not reach the command line: it would expose the
        # unauthenticated detector beyond loopback.
        settings.host = "0.0.0.0";
      };
    };
  };

  # A native backend and its quadlet twin, with distinct model names so no unit
  # name collides and only the backend-level rule can reject them.
  twins = mkSystem {
    vllm = {
      enable = true;
      uid = 504;
      package = pkgs.writeShellScriptBin "vllm" "exit 0";
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
        port = 22002;
      };
    };
  };

  # Both would land on the same `settings.models` entry and misroute silently.
  collidingRoutingKey = mkSystem {
    vllm-quadlet = {
      enable = true;
      tag = "latest";
      models.shared = {
        model = "example/test";
        port = 23001;
      };
      detectors.shared = {
        tokenizer = "example/test";
        port = 23002;
        inherit watermark;
      };
    };
  };

  # vLLM's default watermark, with the key from the system credential store.
  defaultDetector = mkConfig {
    detectors.watermark = {
      tokenizer = "example/test";
      port = 23003;
    };
  };

  # Either would put the key into the Nix store.
  inlineWatermark = mkConfig {
    models.test.settings.watermark-config = {
      algorithm = "gumbel";
      key = 42;
    };
  };
  inlineWatermarkKey = mkConfig {
    detectors.watermark = {
      tokenizer = "example/test";
      port = 23004;
      watermark = watermark // {
        key = 42;
      };
    };
  };

  invalidCredential = mkConfig { models.test.credentials."tls/key" = tlsKey; };

  # Anyone on the host can read the Nix store. The file parses as a module, so
  # a submodule importing paths would accept it.
  storeCredential = mkConfig { models.test.credentials.leak = pkgs.writeText "leak" "{ }"; };

  # Imported by name from the system credential store.
  importedCredential = mkConfig {
    models.test = {
      credentials."llmhop.hf-token" = { };
      settings.hf-token-file = "\${cred:llmhop.hf-token}";
    };
  };

  # Without a `port`, workers bind a unix socket below a custom root. `b`
  # sorts after `a` despite being declared first, so it is the one chained on
  # its predecessor. `b` also runs in its own user namespace.
  sockets = mkSystem {
    enable = true;
    socketDirectory = "/run/sockets/llmhop";
    user = "hop";
    vllm = {
      enable = true;
      uid = 504;
      package = pkgs.writeShellScriptBin "vllm" "exit 0";
      models.test = {
        model = "example/test";
        # The escape hatch still wins over the socket directory's mode.
        serviceConfig.RuntimeDirectoryMode = "0750";
      };
      detectors.watermark = {
        tokenizer = "example/test";
        script = detectorScript;
        inherit watermark;
      };
    };
    llama-cpp-quadlet = {
      enable = true;
      tag = "server";
      models = {
        b = {
          settings.hf-repo = "example/b";
          quadlet = {
            containerConfig.UserNS = "auto";
            mountOptions.socket = [
              "U"
              "z"
            ];
          };
        };
        a.settings.hf-repo = "example/a";
      };
    };
  };

  # llmhop's own listeners, each a socket unit handed to the one service.
  listeners = mkSystem {
    enable = true;
    openFirewall = true;
    listen.caddy.socketGroup = "caddy";
  };
  listenerIPv6 = mkSystem {
    enable = true;
    host = "::1";
  };

  # llama.cpp runs as a `DynamicUser` unless a user is named.
  mkLlamaCpp =
    llamaCppConfig:
    mkSystem {
      llama-cpp = {
        enable = true;
        models.a.settings.hf-repo = "example/a";
      }
      // llamaCppConfig;
    };
  dynamicIdentity = mkLlamaCpp { };
  namedIdentity = mkLlamaCpp { user = "llama"; };

  rootlessSockets = mkConfig {
    quadlet.user.uid = 503;
    models.test.port = null;
    detectors.watermark = {
      tokenizer = "example/test";
      inherit watermark;
    };
  };

  socketRoot = sockets.systemd.tmpfiles.settings."10-llmhop"."/run/sockets/llmhop";
  socketWorker = sockets.systemd.services.vllm-test;
  socketDetector = sockets.systemd.services.vllm-detector-watermark;
  socketContainer = sockets.virtualisation.quadlet.containers.llama-cpp-b;
  rootlessSocketContainer = rootlessSockets.virtualisation.quadlet.containers.vllm-test;

  rootfulWorker = rootful.virtualisation.quadlet.containers.vllm-test;
  rootfulDetector = rootful.virtualisation.quadlet.containers.vllm-detector-watermark;
  rootfulMarked = rootful.virtualisation.quadlet.containers.vllm-marked;
  rootlessWorker = rootless.virtualisation.quadlet.containers.vllm-test;
  sglangGateway = sglang.virtualisation.quadlet.containers.sglang-gateway;
  llamaCppWorker = llamaCpp.virtualisation.quadlet.containers.llama-cpp-test;
  nativeVllmWorker = nativeVllm.systemd.services.vllm-test;
  nativeVllmDetector = nativeVllm.systemd.services.vllm-detector-watermark;
  nativeVllmMarked = nativeVllm.systemd.services.vllm-marked;

  tests = {
    testSocketRoot = {
      expr = {
        root = {
          d = { inherit (socketRoot.d) mode user group; };
          a = { inherit (socketRoot.a) argument; };
        };
        user = sockets.systemd.services.llmhop.serviceConfig.User;
        # A custom user is the deployer's to declare.
        declared = sockets.users.users ? hop;
        invalid =
          evaluates
            (mkSystem { socketDirectory = "/var/lib/llmhop"; }).services.llmhop.socketDirectory;
        traversal =
          evaluates
            (mkSystem { socketDirectory = "/run/../etc"; }).services.llmhop.socketDirectory;
      };
      expected = {
        root = {
          d = {
            mode = "0711";
            user = "root";
            group = "root";
          };
          a.argument = "default:user:hop:-wx";
        };
        user = "hop";
        declared = false;
        invalid = false;
        traversal = false;
      };
    };

    testIdentity = {
      expr = {
        dynamic = {
          inherit (dynamicIdentity.systemd.services.llama-cpp-a.serviceConfig) DynamicUser Group;
          declared = dynamicIdentity.users.groups ? llama-cpp;
        };
        named = {
          inherit (namedIdentity.systemd.services.llama-cpp-a.serviceConfig) User Group;
          dynamic = namedIdentity.systemd.services.llama-cpp-a.serviceConfig ? DynamicUser;
          declared = namedIdentity.users.users ? llama;
        };
      };
      expected = {
        dynamic = {
          DynamicUser = true;
          Group = "llama-cpp";
          declared = true;
        };
        named = {
          User = "llama";
          Group = "llama-cpp";
          dynamic = false;
          declared = false;
        };
      };
    };

    testListeners = {
      expr = {
        socket = listeners.systemd.sockets.llmhop-caddy.listenStreams;
        inherit (listeners.systemd.sockets.llmhop-caddy.socketConfig)
          Service
          SocketGroup
          SocketMode
          RemoveOnStop
          ;
        inherit (listeners.systemd.services.llmhop.serviceConfig) Sockets;
        registered = listeners.services.llmhop.portsRegistry;
        firewall = listeners.networking.firewall.allowedTCPPorts;
        tcp = sockets.systemd.sockets.llmhop-default.listenStreams;
        ipv6 = listenerIPv6.systemd.sockets.llmhop-default.listenStreams;
      };
      expected = {
        socket = [ "/run/llmhop/caddy.sock" ];
        Service = "llmhop.service";
        SocketGroup = "caddy";
        SocketMode = "0660";
        RemoveOnStop = true;
        Sockets = [
          "llmhop-caddy.socket"
          "llmhop-default.socket"
        ];
        registered."llmhop.listen.default" = 8080;
        firewall = [ 8080 ];
        tcp = [ "8080" ];
        ipv6 = [ "[::1]:8080" ];
      };
    };

    testNativeSocket = {
      expr = {
        command = containsAll [
          "-url"
          "unix:///run/sockets/llmhop/vllm-test/http.sock"
          "--uds"
        ] socketWorker.serviceConfig.ExecStart;
        tcp = containsAll [ "--port" ] socketWorker.serviceConfig.ExecStart;
        inherit (socketWorker.serviceConfig)
          UMask
          RuntimeDirectory
          RuntimeDirectoryMode
          SupplementaryGroups
          ;
        bind =
          socketWorker.serviceConfig ? SocketBindAllow && socketWorker.serviceConfig.SocketBindAllow != "tcp";
        routed = sockets.services.llmhop.settings.models.test.url;
        registered = sockets.services.llmhop.portsRegistry ? "vllm.models.test";
        joined = sockets.systemd.services.llmhop.serviceConfig.SupplementaryGroups;
      };
      expected = {
        command = true;
        tcp = false;
        UMask = "0007";
        RuntimeDirectory = [ "sockets/llmhop/vllm-test" ];
        RuntimeDirectoryMode = "0750";
        # The socket belongs to the worker's own group, which llmhop joins.
        SupplementaryGroups = [
          "render"
          "video"
        ];
        bind = false;
        routed = "unix:///run/sockets/llmhop/vllm-test/http.sock";
        registered = false;
        # The Quadlet backend relies on the ACL, so only vLLM's group.
        joined = [ "vllm" ];
      };
    };

    testNativeDetectorSocket = {
      expr = {
        command = containsAll [
          "--uds"
          "/run/sockets/llmhop/vllm-detector-watermark/http.sock"
        ] socketDetector.serviceConfig.ExecStart;
        inherit (socketDetector.serviceConfig) RuntimeDirectory;
        routed = sockets.services.llmhop.settings.models.watermark;
      };
      expected = {
        command = true;
        RuntimeDirectory = [ "sockets/llmhop/vllm-detector-watermark" ];
        routed = {
          url = "unix:///run/sockets/llmhop/vllm-detector-watermark/http.sock";
          unlisted = true;
        };
      };
    };

    testQuadletSocket = {
      expr = {
        inherit (socketContainer.containerConfig)
          Volume
          Umask
          UserNS
          HealthCmd
          ;
        inherit (socketContainer.serviceConfig) RuntimeDirectory RuntimeDirectoryMode;
        published = socketContainer.containerConfig ? PublishPort;
        host = containsAll [ "--host=/run/llmhop/socket/http.sock" ] socketContainer.containerConfig.Exec;
        after = socketContainer.unitConfig.After;
      };
      expected = {
        Volume = [
          "/var/cache/llama-cpp:/root/.cache/llama.cpp"
          "/run/sockets/llmhop/llama-cpp-b:/run/llmhop/socket:U,z"
        ];
        Umask = "0007";
        UserNS = "auto";
        HealthCmd = "curl --fail --silent --show-error --unix-socket /run/llmhop/socket/http.sock http://localhost/health";
        RuntimeDirectory = [ "sockets/llmhop/llama-cpp-b" ];
        RuntimeDirectoryMode = "0710";
        published = false;
        host = true;
        after = [ "llama-cpp-a.service" ];
      };
    };

    testRootlessSocket = {
      expr = {
        clear = containsAll [
          "unshare rm -f /run/llmhop/vllm-test/http.sock"
        ] (toString rootlessSocketContainer.serviceConfig.ExecStartPre);
        # Detectors share the model path, `podman` included.
        detectorClear =
          containsAll
            [
              "unshare rm -f /run/llmhop/vllm-detector-watermark/http.sock"
            ]
            (
              toString rootlessSockets.virtualisation.quadlet.containers.vllm-detector-watermark.serviceConfig.ExecStartPre
            );
        runtime = rootlessSocketContainer.serviceConfig ? RuntimeDirectory;
        directory = {
          inherit (rootlessSockets.systemd.tmpfiles.settings."10-vllm"."/run/llmhop/vllm-test".d)
            user
            group
            mode
            ;
        };
      };
      expected = {
        clear = true;
        detectorClear = true;
        runtime = false;
        directory = {
          user = "vllm";
          group = "vllm";
          mode = "0710";
        };
      };
    };

    testUnknownCredentialReference = {
      expr = evaluates (llmhopLib.resolveCredentialRefs "/run/credentials/test" { } "\${cred:missing}");
      expected = false;
    };

    testRootfulScope = {
      expr = rootfulWorker.uid;
      expected = null;
    };

    testNativeConfigLayers = {
      expr = {
        inherit (rootfulWorker.containerConfig) User UserNS;
        volumes = lib.all (volume: lib.elem volume rootfulWorker.containerConfig.Volume) [
          "/var/cache/vllm:/cache:idmap,Z"
          "%d:/run/llmhop/credentials:ro,idmap=uids=0-1000-1;gids=0-1000-1"
        ];
        inherit (rootfulWorker.serviceConfig)
          LoadCredential
          LoadCredentialEncrypted
          MemoryMax
          ;
        inherit (rootfulWorker.unitConfig) StartLimitBurst;
        inherit (rootfulWorker.quadletConfig) DefaultDependencies;
      };
      expected = {
        User = "1000";
        UserNS = "auto:size=65536";
        volumes = true;
        LoadCredential = [
          "api-keys:${apiKeys}"
          "server-config:${serverConfig}"
        ];
        LoadCredentialEncrypted = [ "tls-key:${tlsKey}" ];
        MemoryMax = "64G";
        StartLimitBurst = 7;
        DefaultDependencies = false;
      };
    };

    testCredentialReferences = {
      expr = containsAll [
        "--api-key-file=/run/llmhop/credentials/api-keys"
        "--config=/run/llmhop/credentials/server-config"
        "--ssl-keyfile=/run/llmhop/credentials/tls-key"
      ] rootfulWorker.containerConfig.Exec;
      expected = true;
    };

    testDetector = {
      expr = {
        arguments = containsAll [
          "/run/llmhop/watermark.py detect"
          (lib.escapeShellArg "--watermark-config=${watermarkConfig}")
          "--watermark-key-file=/run/llmhop/credentials/vllm.watermark-key"
          "--tokenizer=example/test"
        ] rootfulDetector.containerConfig.Exec;
        import = rootfulDetector.serviceConfig.ImportCredential;
        # Appended to the cache mount rather than replacing it.
        volumes = volumeTargets rootfulDetector;
        port = rootfulDetector.containerConfig.PublishPort;
        registered = rootful.services.llmhop.portsRegistry."vllm-quadlet.detectors.watermark";
        # Reachable through llmhop, so it shares the proxy's auth tokens, but
        # kept out of the OpenAI catalog: it serves `/detect`, not completions.
        routed = rootful.services.llmhop.settings.models.watermark;
        routingKey = rootful.services.llmhop.modelsRegistry."vllm-quadlet.detectors.watermark";
      };
      expected = {
        arguments = true;
        import = [ "vllm.watermark-key" ];
        volumes = [
          "/cache"
          "/run/llmhop/watermark.py"
          "/run/llmhop/credentials"
        ];
        port = [ "127.0.0.1:18002:8000" ];
        registered = 18002;
        routed = {
          url = "http://127.0.0.1:18002";
          unlisted = true;
        };
        routingKey = "watermark";
      };
    };

    # The key reaches vLLM through the script, never the command line.
    testQuadletWatermark = {
      expr = {
        arguments = containsAll [
          "/run/llmhop/watermark.py serve example/marked"
          (lib.escapeShellArg "--watermark-config=${watermarkConfig}")
          "--watermark-key-file=/run/llmhop/credentials/vllm.watermark-key"
        ] rootfulMarked.containerConfig.Exec;
        inherit (rootfulMarked.containerConfig) Entrypoint;
        volumes = volumeTargets rootfulMarked;
        import = rootfulMarked.serviceConfig.ImportCredential;
        # Models without a watermark keep the image's entrypoint.
        plain = rootfulWorker.containerConfig ? Entrypoint;
      };
      expected = {
        arguments = true;
        Entrypoint = lib.toJSON [ "python" ];
        volumes = [
          "/cache"
          "/run/llmhop/watermark.py"
          "/run/llmhop/credentials"
        ];
        import = [ "vllm.watermark-key" ];
        plain = false;
      };
    };

    testRootlessScope = {
      expr = rootlessWorker.uid;
      expected = 503;
    };

    testManagedUser = {
      expr = {
        inherit (rootless.users.users.vllm)
          uid
          group
          home
          autoSubUidGidRange
          ;
        gid = rootless.users.groups.vllm.gid;
        cacheOwner = rootless.systemd.tmpfiles.settings."10-vllm"."/var/cache/vllm".d.user;
      };
      expected = {
        uid = 503;
        group = "vllm";
        home = "/var/lib/vllm";
        autoSubUidGidRange = true;
        gid = 503;
        cacheOwner = "vllm";
      };
    };

    testGatewayOverrides = {
      expr = {
        inherit (sglangGateway.containerConfig)
          User
          UserNS
          Volume
          HealthCmd
          ;
        arguments = containsAll [
          "--tls-cert-path=/etc/sglang/tls/server.crt"
          "--tls-key-path=/run/llmhop/credentials/tls-key"
          "http://127.0.0.1:19001"
        ] sglangGateway.containerConfig.Exec;
        load = sglangGateway.serviceConfig.LoadCredential;
      };
      expected = {
        arguments = true;
        User = "1000";
        UserNS = "host";
        Volume = [ "%d:/run/llmhop/credentials:ro,idmap=uids=0-1000-1;gids=0-1000-1" ];
        HealthCmd = "curl --fail --silent --show-error --insecure https://192.0.2.1:19000/health";
        load = [ "tls-key:${tlsKey}" ];
      };
    };

    testGatewayWithoutTLS = {
      expr = sglangNoTLS.virtualisation.quadlet.containers.sglang-gateway.containerConfig.HealthCmd;
      expected = "curl --fail --silent --show-error http://[::1]:19010/health";
    };

    testLlamaCpp = {
      expr = {
        inherit (llamaCppWorker.containerConfig) Image PublishPort Volume;
        arguments = containsAll [
          "--alias=test"
          "--hf-repo=example/test"
        ] llamaCppWorker.containerConfig.Exec;
      };
      expected = {
        arguments = true;
        Image = "ghcr.io/ggml-org/llama.cpp:server";
        PublishPort = [ "127.0.0.1:20001:8080" ];
        Volume = [ "/var/cache/llama-cpp:/root/.cache/llama.cpp" ];
      };
    };

    testNativeCredentials = {
      expr = {
        load = nativeVllmWorker.serviceConfig.LoadCredential;
        encrypted = nativeVllmWorker.serviceConfig.LoadCredentialEncrypted;
        paths = containsAll [
          "%d/api-keys"
          "%d/server-config"
          "%d/tls-key"
        ] nativeVllmWorker.serviceConfig.ExecStart;
        # A doubled `%` would pass the specifier on as a literal.
        escaped = containsAll [ "%%d" ] nativeVllmWorker.serviceConfig.ExecStart;
        # The engine exits 0 after draining, so a crashed worker needs `always`.
        inherit (nativeVllmWorker.serviceConfig) Restart PrivateDevices;
      };
      expected = {
        Restart = "always";
        PrivateDevices = false;
        load = [
          "manual:/run/manual"
          "api-keys:${apiKeys}"
          "server-config:${serverConfig}"
        ];
        encrypted = [ "tls-key:${tlsKey}" ];
        paths = true;
        escaped = false;
      };
    };

    testTwinBackends = {
      expr = accepts twins;
      expected = false;
    };

    testDefaultDetector = {
      expr =
        let
          detector = defaultDetector.virtualisation.quadlet.containers.vllm-detector-watermark;
        in
        {
          arguments = containsAll [
            "--watermark-config={}"
            "--watermark-key-file=/run/llmhop/credentials/vllm.watermark-key"
          ] detector.containerConfig.Exec;
          import = detector.serviceConfig.ImportCredential;
        };
      expected = {
        arguments = true;
        import = [ "vllm.watermark-key" ];
      };
    };

    testInlineWatermark = {
      expr = map accepts [
        inlineWatermark
        inlineWatermarkKey
      ];
      expected = [
        false
        false
      ];
    };

    testNativeWatermark = {
      expr = {
        command = containsAll [
          "serve"
          "example/marked"
          "--watermark-config"
          (lib.toJSON watermarkConfig)
          "--watermark-key-file"
          "%d/vllm.watermark-key"
        ] nativeVllmMarked.serviceConfig.ExecStart;
        python = containsAll [ "/bin/python" ] nativeVllmMarked.serviceConfig.ExecStart;
        load = nativeVllmMarked.serviceConfig.LoadCredential;
        import = nativeVllmMarked.serviceConfig.ImportCredential;
      };
      expected = {
        command = true;
        python = true;
        load = [ "vllm.watermark-key:${watermarkKey}" ];
        import = [ ];
      };
    };

    testRoutingKeyCollision = {
      expr = accepts collidingRoutingKey;
      expected = false;
    };

    testStoreCredential = {
      expr = evaluates storeCredential.virtualisation.quadlet.containers.vllm-test.serviceConfig;
      expected = false;
    };

    testImportedCredential = {
      expr =
        let
          worker = importedCredential.virtualisation.quadlet.containers.vllm-test;
        in
        {
          inherit (worker.serviceConfig) ImportCredential;
          path = containsAll [
            "--hf-token-file=/run/llmhop/credentials/llmhop.hf-token"
          ] worker.containerConfig.Exec;
        };
      expected = {
        ImportCredential = [ "llmhop.hf-token" ];
        path = true;
      };
    };

    testInvalidCredentialName = {
      expr = evaluates invalidCredential.virtualisation.quadlet.containers.vllm-test.serviceConfig;
      expected = false;
    };

    testNativeDetector = {
      expr = {
        command = containsAll [
          "${detectorScript}"
          "detect"
          "-health-path"
          "/health"
          "--watermark-config"
          # Quoted by systemd's escaping, itself JSON.
          (lib.toJSON watermarkConfig)
          "--watermark-key-file"
          "%d/vllm.watermark-key"
        ] nativeVllmDetector.serviceConfig.ExecStart;
        import = nativeVllmDetector.serviceConfig.ImportCredential;
        # `settings.host` must not displace the managed loopback address.
        exposed = containsAll [ "0.0.0.0" ] nativeVllmDetector.serviceConfig.ExecStart;
        registered = nativeVllm.services.llmhop.portsRegistry."vllm.detectors.watermark";
        routed = nativeVllm.services.llmhop.settings.models.watermark;
        # An auxiliary service, so no GPU access and no state directory, and a
        # plain `on-failure` rather than the worker's `always`.
        restart = nativeVllmDetector.serviceConfig.Restart;
        state = nativeVllmDetector.serviceConfig ? StateDirectory;
        devices = nativeVllmDetector.serviceConfig.PrivateDevices or null;
      };
      expected = {
        command = true;
        import = [ "vllm.watermark-key" ];
        exposed = false;
        registered = 21002;
        routed = {
          url = "http://127.0.0.1:21002";
          unlisted = true;
        };
        restart = "on-failure";
        state = false;
        devices = null;
      };
    };
  };

  units = pkgs.symlinkJoin {
    name = "llmhop-generated-units";
    paths =
      rootful.virtualisation.quadlet.generatedUnits
      ++ rootless.virtualisation.quadlet.generatedUnits
      ++ llamaCpp.virtualisation.quadlet.generatedUnits;
  };

  result = pkgs.runCommand "llmhop-eval-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-detector-watermark.service
    test -e ${units}/lib/systemd/user/vllm-test.service
    test -e ${units}/lib/systemd/system/llama-cpp-test.service
    touch $out
  '';
in
mkEvalCheck {
  description = "Module evaluation tests";
  output = result;
  inherit tests;
}
