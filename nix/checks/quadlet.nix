{
  lib,
  nixosSystem,
  pkgs,
  self,
  stdenv,
}:
let
  llmhopLib = import ../modules/lib.nix lib;
  apiKeys = pkgs.writeText "api-keys" "secret";
  detectorScript = pkgs.writeText "watermark_detection_server.py" "";
  serverConfig = pkgs.writeText "server.yaml" "api-key: secret";
  tlsKey = pkgs.writeText "tls-key" "encrypted-placeholder";
  # Not `lib.hasInfix`: it compiles the needle into a regex, and `lib.match`
  # rejects patterns carrying store-path context. Literal replacement has no
  # such restriction, so store paths can be matched directly.
  containsAll =
    values: string: lib.all (value: lib.replaceStrings [ value ] [ "" ] string != string) values;

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
    models.test = {
      credentials = {
        inherit apiKeys serverConfig;
        tlsKey = {
          source = tlsKey;
          encrypted = true;
        };
      };
      settings = {
        config = "\${cred:serverConfig}";
        api-key-file = "\${cred:apiKeys}";
        ssl-keyfile = "\${cred:tlsKey}";
      };
      quadlet.containerConfig.User = "1000";
      quadlet.credentialMountOptions = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
    };
    detectors.watermark = {
      tokenizer = "example/test";
      port = 18002;
      script = "/vllm-workspace/examples/basic/online_serving/watermark_detection_server.py";
      settings.key = 42;
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
        port = 19000;
        credentials.tlsKey = tlsKey;
        settings.tls-key-path = "\${cred:tlsKey}";
        quadlet.containerConfig.User = "1000";
        quadlet.credentialMountOptions = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
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
      models.test = {
        model = "example/test";
        port = 21001;
        credentials = {
          inherit apiKeys serverConfig;
          tlsKey = {
            source = tlsKey;
            encrypted = true;
          };
        };
        settings = {
          config = "\${cred:serverConfig}";
          api-key-file = "\${cred:apiKeys}";
          ssl-keyfile = "\${cred:tlsKey}";
        };
        serviceConfig.LoadCredential = [ "manual:/run/manual" ];
      };
      detectors.watermark = {
        tokenizer = "example/test";
        port = 21002;
        script = detectorScript;
        settings = {
          key = 42;
          # Must not reach the command line: it would expose the
          # unauthenticated detector beyond loopback.
          host = "0.0.0.0";
        };
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

  invalidCredential = mkConfig { models.test.credentials."tls/key" = tlsKey; };

  rootfulWorker = rootful.virtualisation.quadlet.containers.vllm-test;
  rootfulDetector = rootful.virtualisation.quadlet.containers.vllm-detector-watermark;
  rootlessWorker = rootless.virtualisation.quadlet.containers.vllm-test;
  sglangGateway = sglang.virtualisation.quadlet.containers.sglang-gateway;
  llamaCppWorker = llamaCpp.virtualisation.quadlet.containers.llama-cpp-test;
  nativeVllmWorker = nativeVllm.systemd.services.vllm-test;
  nativeVllmDetector = nativeVllm.systemd.services.vllm-detector-watermark;

  failures = lib.runTests {
    testUnknownCredentialReference = {
      expr =
        (lib.tryEval (llmhopLib.resolveCredentialRefs "/run/credentials/test" { } "\${cred:missing}"))
        .success;
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
          "apiKeys:${apiKeys}"
          "serverConfig:${serverConfig}"
        ];
        LoadCredentialEncrypted = [ "tlsKey:${tlsKey}" ];
        MemoryMax = "64G";
        StartLimitBurst = 7;
        DefaultDependencies = false;
      };
    };

    testCredentialReferences = {
      expr = containsAll [
        "--api-key-file=/run/llmhop/credentials/apiKeys"
        "--config=/run/llmhop/credentials/serverConfig"
        "--ssl-keyfile=/run/llmhop/credentials/tlsKey"
      ] rootfulWorker.containerConfig.Exec;
      expected = true;
    };

    testDetector = {
      expr = {
        arguments = containsAll [
          "/vllm-workspace/examples/basic/online_serving/watermark_detection_server.py"
          "--key=42"
          "--tokenizer=example/test"
        ] rootfulDetector.containerConfig.Exec;
        port = rootfulDetector.containerConfig.PublishPort;
        registered = rootful.services.llmhop.portsRegistry."vllm-quadlet.detectors.watermark";
      };
      expected = {
        arguments = true;
        port = [ "127.0.0.1:18002:8000" ];
        registered = 18002;
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
          ;
        arguments = containsAll [
          "--tls-key-path=/run/llmhop/credentials/tlsKey"
          "http://127.0.0.1:19001"
        ] sglangGateway.containerConfig.Exec;
        load = sglangGateway.serviceConfig.LoadCredential;
      };
      expected = {
        arguments = true;
        User = "1000";
        UserNS = "host";
        Volume = [ "%d:/run/llmhop/credentials:ro,idmap=uids=0-1000-1;gids=0-1000-1" ];
        load = [ "tlsKey:${tlsKey}" ];
      };
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
          "/run/credentials/vllm-test.service/apiKeys"
          "/run/credentials/vllm-test.service/serverConfig"
          "/run/credentials/vllm-test.service/tlsKey"
        ] nativeVllmWorker.serviceConfig.ExecStart;
        # The engine exits 0 after draining, so a crashed worker needs `always`.
        inherit (nativeVllmWorker.serviceConfig) Restart PrivateDevices;
      };
      expected = {
        Restart = "always";
        PrivateDevices = false;
        load = [
          "manual:/run/manual"
          "apiKeys:${apiKeys}"
          "serverConfig:${serverConfig}"
        ];
        encrypted = [ "tlsKey:${tlsKey}" ];
        paths = true;
      };
    };

    testTwinBackends = {
      expr = lib.any (assertion: !assertion.assertion) twins.assertions;
      expected = true;
    };

    testInvalidCredentialName = {
      expr =
        (lib.tryEval (
          lib.deepSeq invalidCredential.virtualisation.quadlet.containers.vllm-test.serviceConfig null
        )).success;
      expected = false;
    };

    testNativeDetector = {
      expr = {
        command = containsAll [
          "${detectorScript}"
          "-health-path"
          "/openapi.json"
          "--key"
          "42"
        ] nativeVllmDetector.serviceConfig.ExecStart;
        # `settings.host` must not displace the managed loopback address.
        exposed = containsAll [ "0.0.0.0" ] nativeVllmDetector.serviceConfig.ExecStart;
        registered = nativeVllm.services.llmhop.portsRegistry."vllm.detectors.watermark";
        # An auxiliary service, so no GPU access and no state directory, and a
        # plain `on-failure` rather than the worker's `always`.
        restart = nativeVllmDetector.serviceConfig.Restart;
        state = nativeVllmDetector.serviceConfig ? StateDirectory;
        devices = nativeVllmDetector.serviceConfig.PrivateDevices or null;
      };
      expected = {
        command = true;
        exposed = false;
        registered = 21002;
        restart = "on-failure";
        state = false;
        devices = null;
      };
    };
  };

  units = pkgs.symlinkJoin {
    name = "llmhop-quadlet-test-units";
    paths =
      rootful.virtualisation.quadlet.generatedUnits
      ++ rootless.virtualisation.quadlet.generatedUnits
      ++ llamaCpp.virtualisation.quadlet.generatedUnits;
  };

  result = pkgs.runCommand "llmhop-quadlet-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-detector-watermark.service
    test -e ${units}/lib/systemd/user/vllm-test.service
    test -e ${units}/lib/systemd/system/llama-cpp-test.service
    touch $out
  '';
in
lib.seq (lib.debug.throwTestFailures {
  inherit failures;
  description = "Quadlet module tests";
}) result
