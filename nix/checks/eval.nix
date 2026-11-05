{
  lib,
  mkEvalCheck,
  mkBundleSystem,
  pkgs,
  self,
}:
let
  util = import ../modules/lib.nix lib;
  # Credentials live outside the Nix store, so only their paths are needed.
  apiKeys = "/run/secrets/api-keys";
  serverConfig = "/run/secrets/server.yaml";
  watermarkKey = "/run/secrets/watermark-key";
  watermark.settings.algorithm = "dual_key_gumbel";
  fakeVllm = pkgs.writeShellScriptBin "vllm" "exit 0";
  nativeVllm = {
    enable = true;
    package = fakeVllm;
  };

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

  # Evaluates `credentials` alone, as the option type and `apply` see them.
  credentialsOf =
    credentials:
    (lib.evalModules {
      modules = [
        {
          options.credentials = util.credentialsOption;
          config = { inherit credentials; };
        }
      ];
    }).config.credentials;

  # A minimal system with Quadlet and llmhop's modules.
  mkSystem =
    llmhopConfig:
    (mkBundleSystem {
      modules = [
        self.nixosModules.default
        { services.llmhop = llmhopConfig; }
      ];
    }).config;

  mkQuadlet =
    overrides:
    mkSystem {
      vllm = lib.recursiveUpdate {
        enable = true;
        runtime = "quadlet";
        container.image = "docker.io/vllm/vllm-openai:latest";
        models.test = {
          model = "example/test";
          port = 18001;
        };
      } overrides;
    };

  quadlet = mkQuadlet {
    container = {
      config.UserNS = "auto";
      mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
    };
    models.test = {
      container.devices = [ "nvidia.com/gpu=0" ];
      credentials = {
        api-keys = apiKeys;
        server-config = serverConfig;
        "llmhop.hf-token" = null;
      };
      environment.API_KEY_FILE = "\${cred:api-keys}";
      settings = {
        config = "\${cred:server-config}";
        api-key-file = "\${cred:api-keys}";
      };
    };
    models.marked = {
      model = "example/marked";
      port = 18003;
      inherit watermark;
    };
    detectors.watermark = {
      port = 18002;
      # Two keys of the same tokenizer, the retired one rotated out.
      profiles = rec {
        current = {
          tokenizer = "example/test";
          revision = "v1";
          inherit watermark;
        };
        retired = current // {
          watermark = watermark // {
            credential = "vllm.watermark-key.retired";
          };
        };
      };
    };
  };
  quadletWorker = quadlet.virtualisation.quadlet.containers.vllm-test;
  quadletMarked = quadlet.virtualisation.quadlet.containers.vllm-marked;
  quadletDetector = quadlet.virtualisation.quadlet.containers.vllm-watermark;
  quadletFetcher = quadlet.virtualisation.quadlet.containers.vllm-test-fetch;

  # The VM test covers the native llama.cpp path end to end.
  native = mkSystem {
    gateway.type = "llmhop";
    vllm = nativeVllm // {
      fetch.hfTokenCredential = "llmhop.hf-token";
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
          credentials.api-keys = apiKeys;
          environment.API_KEY_FILE = "\${cred:api-keys}";
        };
        marked = {
          model = "example/marked";
          port = 21003;
          inherit watermark;
          credentials."vllm.watermark-key" = watermarkKey;
        };
      };
      detectors.watermark = {
        port = 21002;
        # The fake `package` has no interpreter to check the default against.
        script = pkgs.writeText "watermark.py" "";
        profiles.test = {
          tokenizer = "example/test";
          inherit watermark;
        };
      };
    };
  };
  nativeWorker = native.systemd.services.vllm-test;
  nativeFetcher = native.systemd.services.vllm-test-fetch;
  nativeRefresh = native.systemd.services.vllm-test-refresh;
  systemctl = lib.getExe' native.systemd.package "systemctl";
  nativeDetector = native.systemd.services.vllm-watermark;

  # Without a `port`, workers bind a unix socket below a custom root. `b`
  # sorts after `a` despite being declared first, so it is the one chained on
  # its predecessor.
  sockets = mkSystem {
    gateway = {
      type = "llmhop";
      llmhop.user = "hop";
    };
    socketDirectory = "/run/sockets/llmhop";
    vllm = nativeVllm // {
      models.test.model = "example/test";
    };
    llama-cpp = {
      enable = true;
      runtime = "quadlet";
      container.image = "ghcr.io/ggml-org/llama.cpp:server";
      models = {
        b.model = "example/b";
        a.model = "example/a";
      };
    };
  };
  socketContainer = sockets.virtualisation.quadlet.containers.llama-cpp-b;
  socketRules = sockets.systemd.tmpfiles.settings."10-llmhop"."/run/sockets/llmhop";

  managed =
    (mkSystem {
      vllm = nativeVllm // {
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
    }).services.llmhop.vllm.models.test;

  # A model of each engine kind on a port, which every gateway reaches.
  mkRoutable =
    overrides:
    mkSystem (
      lib.recursiveUpdate {
        vllm = nativeVllm // {
          models.qwen = {
            model = "example/qwen";
            port = 24001;
          };
        };
        sglang = {
          enable = true;
          runtime = "quadlet";
          container.image = "docker.io/lmsysorg/sglang:latest";
          models.llama = {
            model = "example/llama";
            port = 24002;
          };
        };
      } overrides
    );
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
  # A gateway in a user namespace, reading its credentials through an idmapped mount.
  smgQuadlet =
    (mkRoutable {
      gateway = {
        type = "smg";
        smg = {
          runtime = "quadlet";
          container = {
            image = "ghcr.io/smg-project/smg:nightly";
            config.UserNS = "auto";
            mountOptions.credentials = [ "idmap" ];
          };
          credentials."smg.api-key" = apiKeys;
          settings.api-key-file = "\${cred:smg.api-key}";
        };
      };
    }).virtualisation.quadlet.containers.smg;
  bifrost = mkRoutable {
    gateway = {
      type = "bifrost";
      bifrost.runtime = "quadlet";
      bifrost.container.image = "docker.io/maximhq/bifrost:v2.3.2";
    };
  };

  # Failing assertions containing `needle` of `system`, expected `count` times.
  assertionCases = {
    inlineWatermarkKey = {
      needle = "watermark key inline";
      count = 2;
      system = mkQuadlet {
        models.test.watermark.settings.key = 42;
        models.inline = {
          model = "example/inline";
          port = 18004;
          settings.watermark-config = {
            algorithm = "gumbel";
            key = 42;
          };
        };
      };
    };
    routedBeyondLoopback = {
      needle = "is routed by the gateway";
      count = 1;
      system = mkRoutable {
        gateway = {
          type = "smg";
          smg.package = fakeVllm;
        };
        vllm.models.qwen.host = "0.0.0.0";
      };
    };
    firewallOnRoutedModel = {
      needle = "is loopback";
      count = 1;
      system = mkRoutable { vllm.models.qwen.openFirewall = true; };
    };
    socketBehindTcpGateway = {
      needle = "cannot reach";
      count = 1;
      system = mkRoutable {
        gateway = {
          type = "bifrost";
          bifrost.package = fakeVllm;
        };
        vllm.models.local.model = "example/local";
      };
    };
    llmhopListenSetting = {
      needle = "sets `listen`";
      count = 1;
      system = mkRoutable {
        gateway = {
          type = "llmhop";
          llmhop = {
            runtime = "quadlet";
            settings.listen = [ ":8080" ];
          };
        };
      };
    };
    portClash = {
      needle = "is claimed by";
      count = 1;
      system = mkSystem {
        vllm = nativeVllm // {
          models.native = {
            model = "example/test";
            port = 22001;
          };
        };
        sglang = {
          enable = true;
          runtime = "quadlet";
          container.image = "docker.io/lmsysorg/sglang:latest";
          models.container = {
            model = "example/test";
            port = 22001;
          };
        };
      };
    };
    nameClash = {
      needle = "model `test` is claimed";
      count = 1;
      system = mkSystem {
        gateway.type = "llmhop";
        vllm = nativeVllm // {
          models.test.model = "example/test";
        };
        llama-cpp = {
          enable = true;
          runtime = "quadlet";
          container.image = "ghcr.io/ggml-org/llama.cpp:server";
          models.test = {
            model = "example/test";
            port = 22002;
          };
        };
      };
    };
    offlineOnPort = {
      needle = "with `offline = true`";
      count = 1;
      system = mkQuadlet { models.test.offline = true; };
    };
    offlineOnSocket = {
      needle = "with `offline = true`";
      count = 0;
      system = mkQuadlet { models.test.port = null; };
    };
  };

  tests = {
    testImageDependencies = {
      expr = with quadlet.virtualisation.quadlet.containers; {
        worker = vllm-test.unitConfig.PartOf;
        fetcher = vllm-test-fetch.unitConfig.PartOf;
        detector = vllm-watermark.unitConfig.PartOf;
        detectorFetcher = vllm-watermark-fetch.unitConfig.PartOf;
        smg = smgQuadlet.unitConfig.PartOf;
        bifrost = bifrost.virtualisation.quadlet.containers.bifrost.unitConfig.PartOf;
      };
      expected = {
        worker = [ "vllm-image.service" ];
        fetcher = [ "vllm-image.service" ];
        detector = [ "vllm-image.service" ];
        detectorFetcher = [ "vllm-image.service" ];
        smg = [ "smg-image.service" ];
        bifrost = [ "bifrost-image.service" ];
      };
    };

    # Every container of a backend or gateway runs in the configured user
    # namespace, the gateway still as its root.
    testUserNamespace = {
      expr = {
        worker = quadletWorker.containerConfig.UserNS;
        fetcher = quadletFetcher.containerConfig.UserNS;
        detector = quadletDetector.containerConfig.UserNS;
        inherit (smgQuadlet.containerConfig) UserNS User;
        mount = lib.elem "%d:/run/llmhop/credentials:ro,idmap" smgQuadlet.containerConfig.Volume;
      };
      expected = {
        worker = "auto";
        fetcher = "auto";
        detector = "auto";
        UserNS = "auto";
        User = "0:0";
        mount = true;
      };
    };

    # Paths are loaded, `null` is imported, and references resolve to the
    # credential directory, never a value on the command line.
    testCredentials = {
      expr = {
        inherit (quadletWorker.serviceConfig) LoadCredential ImportCredential;
        paths = containsAll [
          "--api-key-file /run/llmhop/credentials/api-keys"
          "--config /run/llmhop/credentials/server-config"
        ] quadletWorker.containerConfig.Exec;
        mount = lib.elem "%d:/run/llmhop/credentials:ro,idmap=uids=0-1000-1;gids=0-1000-1" quadletWorker.containerConfig.Volume;
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
          quadletApiKeyFile = lib.elem ''"API_KEY_FILE=/run/llmhop/credentials/api-keys"'' quadletWorker.containerConfig.Environment;
          quadletCredentialsDirectory = lib.elem ''"CREDENTIALS_DIRECTORY=/run/llmhop/credentials"'' quadletWorker.containerConfig.Environment;
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
          quadletApiKeyFile = true;
          quadletCredentialsDirectory = true;
          native = "%d/api-keys";
        };
      };
    };

    # The key reaches vLLM through the script, never the command line.
    testWatermark = {
      expr = {
        quadlet = {
          inherit (quadlet.services.llmhop.vllm.models.marked) command mounts;
          key = quadlet.services.llmhop.vllm.models.marked.settings.watermark-key-file;
          # The reference resolves to the credential mount.
          exec = lib.hasInfix "--watermark-key-file /run/llmhop/credentials/vllm.watermark-key" quadletMarked.containerConfig.Exec;
        };
        native =
          let
            inherit (native.services.llmhop.vllm.models.marked) command;
          in
          {
            python = lib.hasSuffix "/bin/python" (lib.head command);
            arguments = lib.drop 2 command;
          };
      };
      expected = {
        quadlet = {
          command = [
            "python"
            "/run/llmhop/watermark.py"
            "serve"
            "example/marked"
          ];
          mounts = [ "${../pkgs/mkVllmWatermark/watermark.py}:/run/llmhop/watermark.py:ro" ];
          key = "\${cred:vllm.watermark-key}";
          exec = true;
        };
        native = {
          python = true;
          arguments = [
            "serve"
            "example/marked"
          ];
        };
      };
    };

    testDetector = {
      expr = {
        command = quadlet.services.llmhop.vllm.detectors.watermark.command;
        keys = lib.mapAttrs (
          _: profile: profile.key_file
        ) quadlet.services.llmhop.vllm.detectors.watermark.settings.profiles;
        import = quadletDetector.serviceConfig.ImportCredential;
        # Only the tokenizer files, not the weights, once for both profiles.
        fetch =
          lib.pipe quadlet.virtualisation.quadlet.containers.vllm-watermark-fetch.containerConfig.Volume
            [
              (lib.findFirst (lib.hasSuffix ":/run/llmhop/fetch.sh:ro") null)
              (lib.splitString ":")
              lib.head
              lib.readFile
              (containsAll [ "hf download example/test --revision v1 --include '*.json'" ])
            ];
        # Only llmhop routes it, outside the OpenAI catalog.
        routed = native.services.llmhop.gateway.llmhop.settings.models.watermark.unlisted;
        # An auxiliary service, so no GPU access and no state directory.
        state = nativeDetector.serviceConfig ? StateDirectory;
        devices = nativeDetector.serviceConfig.PrivateDevices;
        modelDevices = nativeWorker.serviceConfig.PrivateDevices;
        containerModelDevices = quadletWorker.containerConfig.AddDevice;
        containerDetectorDevices = quadletDetector.containerConfig ? AddDevice;
        detectorAfterModel = lib.elem "vllm-marked.service" nativeDetector.after;
      };
      expected = {
        command = [
          "python"
          "/run/llmhop/watermark.py"
          "detect"
        ];
        keys = {
          current = "\${cred:vllm.watermark-key}";
          retired = "\${cred:vllm.watermark-key.retired}";
        };
        import = [
          "vllm.watermark-key"
          "vllm.watermark-key.retired"
        ];
        fetch = true;
        routed = true;
        state = false;
        devices = true;
        modelDevices = false;
        containerModelDevices = [ "nvidia.com/gpu=0" ];
        containerDetectorDevices = false;
        detectorAfterModel = false;
      };
    };

    # The fetcher alone gets the fetch credentials and writes the hub cache,
    # the server runs offline from it.
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
        inherit (nativeWorker.serviceConfig) IPAddressDeny ReadOnlyPaths;
        # A local path has nothing to fetch.
        local = native.systemd.services ? vllm-local-fetch;
        inherit (quadletWorker.unitConfig) Wants;
      };
      expected = {
        script = true;
        token = true;
        ImportCredential = [ "llmhop.hf-token" ];
        HF_HUB_OFFLINE = "1";
        IPAddressDeny = "any";
        ReadOnlyPaths = [ "/var/cache/vllm/test/hub" ];
        local = false;
        Wants = [ "vllm-test-fetch.service" ];
      };
    };

    # Only the refresh unit touches a hub cache once fetched, as its owner,
    # and runs nothing but `systemctl` as root.
    testRefresh = {
      expr = {
        trigger = {
          native = nativeFetcher.unitConfig.Wants;
          quadlet = quadletFetcher.unitConfig.Wants;
        };
        native = {
          inherit (nativeRefresh.serviceConfig) User ReadWritePaths SystemCallFilter;
          inherit (nativeRefresh) requires;
          prune = containsAll [
            "/bin/llmhop\" \"internal\" \"hub-prune\" "
          ] nativeRefresh.serviceConfig.ExecStartPre;
          restart = nativeRefresh.serviceConfig.ExecStart;
        };
        quadlet = quadlet.systemd.services.vllm-test-refresh.serviceConfig.User;
        fetcherLimit = quadletFetcher.unitConfig ? StartLimitIntervalSec;
      };
      expected = {
        trigger = {
          native = [
            "network-online.target"
            "vllm-test-refresh.service"
          ];
          quadlet = [ "vllm-test-refresh.service" ];
        };
        native = {
          User = "vllm";
          ReadWritePaths = [ "/var/cache/vllm/test/hub" ];
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
            "~@network-io"
          ];
          requires = [ "vllm-test-fetch.service" ];
          prune = true;
          restart = [
            "+-${systemctl} reset-failed vllm-test.service"
            "+${systemctl} try-restart --no-block vllm-test.service"
          ];
        };
        quadlet = "root";
        fetcherLimit = false;
      };
    };

    testSockets = {
      expr = {
        root = {
          inherit (socketRules.d) mode;
          inherit (socketRules.a) argument;
        };
        uds = sockets.services.llmhop.vllm.models.test.settings.uds;
        routed = sockets.services.llmhop.gateway.llmhop.settings.models.test.url;
        inherit (socketContainer.containerConfig) PodmanArgs Network;
        mount = lib.elem "/run/sockets/llmhop/llama-cpp-b:/run/llmhop/socket:U" socketContainer.containerConfig.Volume;
        after = socketContainer.unitConfig.After;
      };
      expected = {
        root = {
          mode = "0711";
          argument = "default:user:hop:-wx";
        };
        uds = "/run/sockets/llmhop/vllm-test/http.sock";
        routed = "unix:///run/sockets/llmhop/vllm-test/http.sock";
        PodmanArgs = [ "--umask=0007" ];
        Network = "none";
        mount = true;
        after = [
          "llama-cpp-b-fetch.service"
          "llama-cpp-b-refresh.service"
          "llama-cpp-a.service"
        ];
      };
    };

    # External gateways use upstream secret interfaces and reject models
    # they cannot route or clients could bypass.
    testGateways = {
      expr = {
        smg = containsAll [
          ''"--api-key-file" "%d/smg.api-key"''
          ''"--discovery-provider" "file"''
        ] smg.systemd.services.smg.serviceConfig.ExecStart;
        bifrost = lib.mapAttrs (
          _: provider: lib.concatMap (key: key.models) provider.keys
        ) bifrost.services.llmhop.gateway.bifrost.settings.providers;
      };
      expected = {
        smg = true;
        bifrost = {
          vllm = [ "qwen" ];
          sgl = [ "llama" ];
        };
      };
    };

    # Both llmhop gateways receive their listeners as sockets, which is why
    # `settings` cannot bind any.
    testLlmhopSockets = {
      expr =
        let
          llmhopQuadlet = mkRoutable {
            gateway = {
              type = "llmhop";
              llmhop = {
                runtime = "quadlet";
                listen.proxy.socketGroup = "caddy";
              };
            };
          };
        in
        {
          native = {
            inherit (native.systemd.sockets.llmhop-default) listenStreams;
            sockets = native.systemd.services.llmhop.serviceConfig.Sockets;
          };
          quadlet = {
            inherit (llmhopQuadlet.systemd.sockets.llmhop-default) listenStreams;
            sockets = llmhopQuadlet.virtualisation.quadlet.containers.llmhop.serviceConfig.Sockets;
            group = llmhopQuadlet.systemd.sockets.llmhop-proxy.socketConfig.SocketGroup;
          };
        };
      expected = {
        native = {
          listenStreams = [ "127.0.0.1:8080" ];
          sockets = [ "llmhop-default.socket" ];
        };
        quadlet = {
          listenStreams = [ "127.0.0.1:8080" ];
          sockets = [
            "llmhop-default.socket"
            "llmhop-proxy.socket"
          ];
          group = "caddy";
        };
      };
    };

    # Each misconfiguration fails exactly its own assertions, even when a
    # gateway reads the clashing endpoints.
    testAssertions = {
      expr = lib.mapAttrs (_: case: failing case.needle case.system) assertionCases;
      expected = lib.mapAttrs (_: case: case.count) assertionCases;
    };

    # A container needs the network for its published port, while a socket
    # or a native server runs offline by default.
    testOfflineDefault = {
      expr = {
        container = quadlet.services.llmhop.vllm.models.test.offline;
        containerSocket = sockets.services.llmhop.llama-cpp.models.b.offline;
        native = native.services.llmhop.vllm.models.test.offline;
      };
      expected = {
        container = false;
        containerSocket = true;
        native = true;
      };
    };

    testManagedSettings = {
      expr = lib.getAttrs [ "host" "port" "served-model-name" ] managed.settings;
      expected = {
        host = "127.0.0.1";
        port = 25001;
        served-model-name = "test";
      };
    };
  };

  # Quadlet's generator accepts every generated unit.
  units = pkgs.symlinkJoin {
    name = "llmhop-generated-units";
    paths =
      quadlet.virtualisation.quadlet.generatedUnits
      ++ sockets.virtualisation.quadlet.generatedUnits
      ++ bifrost.virtualisation.quadlet.generatedUnits;
  };

in
mkEvalCheck {
  description = "Module evaluation tests";
  output = pkgs.runCommand "llmhop-eval-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-watermark.service
    test -e ${units}/lib/systemd/system/llama-cpp-b.service
    test -e ${units}/lib/systemd/system/bifrost.service
    grep -q '^Requires=${quadlet.virtualisation.quadlet.images.vllm.serviceName}.service$' ${units}/lib/systemd/system/vllm-test.service
    touch $out
  '';
  inherit tests;
}
