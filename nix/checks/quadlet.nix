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
  serverConfig = pkgs.writeText "server.yaml" "api-key: secret";
  tlsKey = pkgs.writeText "tls-key" "encrypted-placeholder";
  # Not `lib.hasInfix`: it compiles the needle into a regex, and `builtins.match`
  # rejects patterns carrying store-path context. Literal replacement has no
  # such restriction, so store paths can be matched directly.
  containsAll =
    values: string: lib.all (value: builtins.replaceStrings [ value ] [ "" ] string != string) values;

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
        credentials = { inherit serverConfig tlsKey; };
        settings = {
          config = "\${cred:serverConfig}";
          ssl-keyfile = "\${cred:tlsKey}";
        };
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
    };
  };

  rootfulWorker = rootful.virtualisation.quadlet.containers.vllm-test;
  rootlessWorker = rootless.virtualisation.quadlet.containers.vllm-test;
  sglangGateway = sglang.virtualisation.quadlet.containers.sglang-gateway;
  sglangWorker = sglang.virtualisation.quadlet.containers.sglang-test;
  nativeVllmWorker = nativeVllm.systemd.services.vllm-test;

  failures = lib.runTests {
    testUnknownCredentialReference = {
      expr =
        (builtins.tryEval (llmhopLib.resolveCredentialRefs "/run/credentials/test" { } "\${cred:missing}"))
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

    testSglangCredentials = {
      expr = {
        arguments = containsAll [
          "--config=/run/llmhop/credentials/serverConfig"
          "--ssl-keyfile=/run/llmhop/credentials/tlsKey"
        ] sglangWorker.containerConfig.Exec;
        load = sglangWorker.serviceConfig.LoadCredential;
      };
      expected = {
        arguments = true;
        load = [
          "serverConfig:${serverConfig}"
          "tlsKey:${tlsKey}"
        ];
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
      };
      expected = {
        load = [
          "manual:/run/manual"
          "apiKeys:${apiKeys}"
          "serverConfig:${serverConfig}"
        ];
        encrypted = [ "tlsKey:${tlsKey}" ];
        paths = true;
      };
    };

  };

  units = pkgs.symlinkJoin {
    name = "llmhop-quadlet-test-units";
    paths =
      rootful.virtualisation.quadlet.generatedUnits ++ rootless.virtualisation.quadlet.generatedUnits;
  };

  result = pkgs.runCommand "llmhop-quadlet-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/user/vllm-test.service
    touch $out
  '';
in
builtins.seq (lib.debug.throwTestFailures {
  inherit failures;
  description = "Quadlet module tests";
}) result
