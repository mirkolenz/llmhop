# The systems the evaluation tests inspect, and the helpers to inspect them.
{
  lib,
  mkBundleSystem,
  pkgs,
  self,
}:
rec {
  inherit lib pkgs;
  util = import ../../modules/lib lib;
  # Credentials live outside the Nix store, so only their paths are needed.
  apiKeys = "/run/secrets/api-keys";
  serverConfig = "/run/secrets/server.yaml";
  watermarkKey = "/run/secrets/watermark-key";
  watermark.settings.algorithm = "dual_key_gumbel";
  fakeVllm = pkgs.writeShellScriptBin "vllm" "exit 0";
  fakeSglang = pkgs.writeShellScriptBin "sglang" "exit 0";
  nativeVllm = {
    enable = true;
    package = fakeVllm;
  };
  nativeSglang = {
    enable = true;
    package = fakeSglang;
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

  # A minimal system with Quadlet, llmhop's modules and `module`.
  mkSystemWith =
    module:
    (mkBundleSystem {
      modules = [
        self.nixosModules.default
        module
      ];
    }).config;
  mkSystem = llmhopConfig: mkSystemWith { services.llmhop = llmhopConfig; };

  mkContainer =
    overrides:
    mkSystem (
      lib.recursiveUpdate {
        runtime = "container";
        vllm = {
          enable = true;
          container.image = "docker.io/vllm/vllm-openai:latest";
          models.test = {
            model = "example/test";
            port = 18001;
          };
        };
      } overrides
    );

  container = mkContainer {
    gateway = {
      enable = true;
      credentials."llmhop.client-token" = null;
      settings.authTokens.client = "\${cred:llmhop.client-token}";
    };
    vllm = {
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
  };
  containers = container.virtualisation.quadlet.containers;
  containerWorker = containers.vllm-test;
  containerMarked = containers.vllm-marked;
  containerDetector = containers.vllm-watermark;
  # Containers as host root, mapped by hand through `container.config`.
  unmapped = mkContainer {
    container = {
      userNS = null;
      config.UIDMap = [ "0:100000:65536" ];
    };
    vllm.models.test.credentials.api-keys = apiKeys;
  };
  unmappedWorker = unmapped.virtualisation.quadlet.containers.vllm-test.containerConfig;

  # Client tokens imported by glob, with further gateway options.
  tokenGateway =
    extra:
    mkSystem {
      gateway = {
        enable = true;
        settings.authTokenCredentials = "llmhop.token.*";
      }
      // extra;
      vllm = nativeVllm // {
        models.test = {
          model = "example/test";
          port = 21101;
        };
      };
    };

  # The VM test covers the native llama.cpp path end to end.
  native = mkSystem {
    gateway.enable = true;
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
          native.devices = [ "char-nvidia" ];
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
          revision = "v1";
          inherit watermark;
        };
      };
    };
  };
  nativeWorker = native.systemd.services.vllm-test;
  nativeFetcher = native.systemd.services.vllm-test-fetch;
  nativeDetector = native.systemd.services.vllm-watermark;

  # With the NVIDIA driver, models default to its device groups.
  nvidia = mkSystemWith {
    services.xserver.videoDrivers = [ "nvidia" ];
    services.llmhop.vllm = nativeVllm // {
      models.test = {
        model = "example/test";
        port = 21001;
      };
    };
  };

  # Without a `port`, workers bind a unix socket below a custom root. `b`
  # sorts after `a` despite being declared first, so it is the one chained on
  # its predecessor.
  sockets = mkSystem {
    gateway = {
      enable = true;
      user = "hop";
    };
    socketDirectory = "/run/sockets/llmhop";
    vllm = nativeVllm // {
      models.test.model = "example/test";
    };
    llama-cpp = {
      enable = true;
      models = {
        b.model = "example/b:Q4_K_M";
        a.model = "example/a";
      };
    };
  };
  socketRules = sockets.systemd.tmpfiles.settings."10-llmhop"."/run/sockets/llmhop";

  # A native model accepting clients beyond loopback.
  mkExposed =
    overrides:
    mkSystem {
      vllm = nativeVllm // {
        models.test = {
          model = "example/test";
          host = "0.0.0.0";
          port = 26001;
        }
        // overrides;
      };
    };
  exposed = mkExposed { };
  exposedWorker = exposed.systemd.services.vllm-test;

  managed =
    (mkSystem {
      vllm = nativeVllm // {
        modelSettings.max-model-len = 4096;
        models.test = {
          model = "example/test";
          port = 25001;
          settings.max-num-seqs = 8;
        };
      };
    }).systemd.services.vllm-test.serviceConfig.ExecStart;

  # A model of each Python engine on a port, with LoRA adapters and
  # data-parallel ranks, behind the gateway.
  mkRoutable =
    overrides:
    mkSystem (
      lib.recursiveUpdate {
        gateway.enable = true;
        vllm = nativeVllm // {
          models.qwen = {
            model = "example/qwen";
            port = 24001;
            loras.qwen-sql = "example/sql-lora";
            dataParallelSize = 2;
          };
        };
        sglang = nativeSglang // {
          models.llama = {
            model = "example/llama";
            port = 24002;
            loras.llama-sql = "example/llama-lora";
            dataParallelSize = 4;
            watermark = {
              settings.context_window = 4;
              secondaryCredential = "sglang.watermark-key-b";
            };
          };
        };
      } overrides
    );
  routable = mkRoutable { };
  routedModels = routable.services.llmhop.gateway.settings.models;
}
