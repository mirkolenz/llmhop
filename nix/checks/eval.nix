{
  lib,
  mkEvalCheck,
  mkQuadletSystem,
  pkgs,
}:
let
  util = import ../modules/lib.nix lib;
  # Credentials live outside the Nix store, so only their paths are needed.
  apiKeys = "/run/secrets/api-keys";
  serverConfig = "/run/secrets/server.yaml";
  watermarkKey = "/run/secrets/watermark-key";
  # The fake `package` has no interpreter to check the default against.
  detectorScript = pkgs.writeText "watermark.py" "";
  watermark.algorithm = "dual_key_gumbel";
  fakeVllm = pkgs.writeShellScriptBin "vllm" "exit 0";

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

  mkSystem =
    llmhopConfig: (mkQuadletSystem { modules = [ { services.llmhop = llmhopConfig; } ]; }).config;

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

  quadlet = mkQuadlet {
    containerConfig.UserNS = "auto";
    mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
    models.test = {
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
    vllm = {
      enable = true;
      package = fakeVllm;
      fetch.tokenCredential = "llmhop.hf-token";
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
        script = detectorScript;
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
  socketContainer = sockets.virtualisation.quadlet.containers.llama-cpp-b;

  # A model of each engine kind on a port, which every gateway reaches.
  mkRoutable =
    overrides:
    mkSystem (
      lib.recursiveUpdate {
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
        type = "smg-quadlet";
        smg-quadlet = {
          image = "ghcr.io/smg-project/smg:nightly";
          credentials."smg.api-key" = apiKeys;
          settings.api-key-file = "\${cred:smg.api-key}";
          containerConfig.UserNS = "auto";
          mountOptions.credentials = [ "idmap" ];
        };
      };
    }).virtualisation.quadlet.containers.smg;
  bifrost = mkRoutable {
    gateway = {
      type = "bifrost-quadlet";
      bifrost-quadlet.image = "docker.io/maximhq/bifrost:v2.3.2";
    };
  };

  tests = {
    # Every container of a backend or gateway runs in the configured user
    # namespace, the gateway still as its root.
    testUserNamespace = {
      expr = {
        backend = map (unit: quadlet.virtualisation.quadlet.containers.${unit}.containerConfig.UserNS) [
          "vllm-test"
          "vllm-test-fetch"
          "vllm-watermark"
        ];
        inherit (smgQuadlet.containerConfig) UserNS User;
        mount = lib.elem "%d:/run/llmhop/credentials:ro,idmap" smgQuadlet.containerConfig.Volume;
      };
      expected = {
        backend = [
          "auto"
          "auto"
          "auto"
        ];
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
          quadlet = lib.all (entry: lib.elem entry quadletWorker.containerConfig.Environment) [
            ''"API_KEY_FILE=/run/llmhop/credentials/api-keys"''
            ''"CREDENTIALS_DIRECTORY=/run/llmhop/credentials"''
          ];
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
          quadlet = true;
          native = "%d/api-keys";
        };
      };
    };

    # The key reaches vLLM through the script, never the command line.
    testWatermark = {
      expr = {
        quadlet = containsAll [
          "/run/llmhop/watermark.py serve example/marked"
          "--watermark-key-file /run/llmhop/credentials/vllm.watermark-key"
        ] quadletMarked.containerConfig.Exec;
        native = containsAll [
          "/bin/python"
          "serve"
          "example/marked"
          "--watermark-key-file"
          "%d/vllm.watermark-key"
        ] native.systemd.services.vllm-marked.serviceConfig.ExecStart;
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
        quadlet = true;
        native = true;
        inline = 2;
      };
    };

    testDetector = {
      expr = {
        arguments = containsAll [
          "/run/llmhop/watermark.py detect"
          "/run/llmhop/credentials/vllm.watermark-key\""
          "/run/llmhop/credentials/vllm.watermark-key.retired"
        ] quadletDetector.containerConfig.Exec;
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
      };
      expected = {
        arguments = true;
        import = [
          "vllm.watermark-key"
          "vllm.watermark-key.retired"
        ];
        fetch = true;
        routed = true;
        state = false;
        devices = true;
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
        hooks =
          lib.any (unit: unit.serviceConfig ? ExecStartPost || unit.serviceConfig ? ExecStopPost) [
            nativeFetcher
            quadletFetcher
          ]
          || lib.any (unit: unit.serviceConfig ? ExecStartPre) [
            nativeWorker
            quadletWorker
          ];
        native = {
          inherit (nativeRefresh.serviceConfig) User ReadWritePaths SystemCallFilter;
          inherit (nativeRefresh) requires;
          prune = containsAll [ "\"prune\"" ] nativeRefresh.serviceConfig.ExecStartPre;
          restart = containsAll [ "+\"" "\"restart\" \"vllm-test\"" ] nativeRefresh.serviceConfig.ExecStart;
        };
        quadlet = quadlet.systemd.services.vllm-test-refresh.serviceConfig.User;
        watched = native.systemd.paths.vllm-test-refresh.pathConfig.PathChanged;
      };
      expected = {
        hooks = false;
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
          restart = true;
        };
        quadlet = "root";
        watched = [ "/var/cache/vllm/test/hub/models--example--test/snapshots" ];
      };
    };

    testSockets = {
      expr = {
        root =
          let
            rules = sockets.systemd.tmpfiles.settings."10-llmhop"."/run/sockets/llmhop";
          in
          {
            inherit (rules.d) mode;
            inherit (rules.a) argument;
          };
        uds = containsAll [
          "--uds"
          "/run/sockets/llmhop/vllm-test/http.sock"
        ] sockets.systemd.services.vllm-test.serviceConfig.ExecStart;
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
        uds = true;
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
        ) bifrost.services.llmhop.gateway.bifrost-quadlet.settings.providers;
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
          vllm = [ "qwen" ];
          sgl = [ "llama" ];
        };
        rejected = 1;
        socket = 1;
      };
    };

    # Clashing ports, units and names fail one assertion each, even when the
    # gateway reads the clashing endpoints.
    testClaims = {
      expr = {
        twins = failing "is claimed by" (mkSystem {
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
        names = failing "model `test` is claimed" (mkSystem {
          gateway.type = "llmhop";
          vllm = {
            enable = true;
            package = fakeVllm;
            models.test.model = "example/test";
          };
          llama-cpp-quadlet = {
            enable = true;
            image = "ghcr.io/ggml-org/llama.cpp:server";
            models.test = {
              model = "example/test";
              port = 22002;
            };
          };
        });
      };
      expected = {
        # The update unit and the port.
        twins = 2;
        names = 1;
      };
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
        containsAll [
          ''"--host" "127.0.0.1"''
          ''"--port" "25001"''
          ''"--served-model-name" "test"''
        ] ExecStart;
      expected = true;
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

  result = pkgs.runCommand "llmhop-eval-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-watermark.service
    test -e ${units}/lib/systemd/system/llama-cpp-b.service
    test -e ${units}/lib/systemd/system/bifrost.service
    grep -q '^Requires=${quadlet.virtualisation.quadlet.images.vllm.serviceName}.service$' ${units}/lib/systemd/system/vllm-test.service
    touch $out
  '';
in
mkEvalCheck {
  description = "Module evaluation tests";
  output = result;
  inherit tests;
}
