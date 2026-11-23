# Each misconfiguration fails exactly its own assertions.
{
  lib,
  nativeVllm,
  nativeSglang,
  failing,
  mkSystem,
  mkContainer,
  mkExposed,
  mkRoutable,
  ...
}:
let
  # Failing assertions containing `needle` of `system`, expected `count` times.
  assertionCases = {
    inlineWatermarkKey = {
      needle = "watermark key inline";
      count = 1;
      system = mkContainer { vllm.models.test.watermark.settings.key_file = "/key"; };
    };
    # The flags of a watermark are reserved, even for a model without one,
    # and under a dotted field.
    watermarkFlag = {
      needle = "`watermark-config.key`";
      count = 1;
      system = mkContainer { vllm.models.test.settings."watermark-config.key" = 42; };
    };
    routedBeyondLoopback = {
      needle = "is routed by the gateway";
      count = 1;
      system = mkRoutable { vllm.models.qwen.host = "0.0.0.0"; };
    };
    firewallOnRoutedModel = {
      needle = "is loopback";
      count = 1;
      system = mkRoutable { vllm.models.qwen.openFirewall = true; };
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
        sglang = nativeSglang // {
          models.other = {
            model = "example/test";
            port = 22001;
          };
        };
      };
    };
    # Replicas of one name must agree on the model of the gateway.
    replicaMismatch = {
      needle = "of `test` differ";
      count = 1;
      system = mkSystem {
        gateway.enable = true;
        vllm = nativeVllm // {
          models.test = {
            model = "example/test";
            dataParallelSize = 2;
          };
        };
        llama-cpp = {
          enable = true;
          models.test.model = "example/test";
        };
      };
    };
    # Settings never silently lose to the flags llmhop derives.
    forcedSettings = {
      needle = "`served-model-name`";
      count = 1;
      system = mkSystem {
        vllm = nativeVllm // {
          modelSettings.host = "0.0.0.0";
          models.test = {
            model = "example/test";
            port = 25001;
            settings.served-model-name = "other";
          };
        };
      };
    };
    # Nor do they under another spelling or at their default.
    flagSpelling = {
      needle = "`data_parallel_size`";
      count = 1;
      system = mkSystem {
        sglang = nativeSglang // {
          models.test = {
            model = "example/test";
            port = 25001;
            settings.data_parallel_size = 2;
          };
        };
      };
    };
    # Nor as the negation of a derived boolean, on every negating parser.
    negatedVllmFlag = {
      needle = "`no-enable-lora`";
      count = 1;
      system = mkSystem {
        vllm = nativeVllm // {
          models.test = {
            model = "example/test";
            port = 25001;
            loras.sql = "example/sql-lora";
            settings.no-enable-lora = true;
          };
        };
      };
    };
    negatedLlamaCppFlag = {
      needle = "`no-alias`";
      count = 1;
      system = mkSystem {
        llama-cpp = {
          enable = true;
          models.test = {
            model = "example/test";
            settings.no-alias = true;
          };
        };
      };
    };
    loraSelf = {
      needle = "like the model itself";
      count = 1;
      system = mkSystem {
        sglang = nativeSglang // {
          models.test = {
            model = "example/test";
            port = 25001;
            loras.test = "example/lora";
          };
        };
      };
    };
    offlineInContainer = {
      needle = "sets `offline = true`";
      count = 1;
      system = mkContainer { vllm.models.test.offline = true; };
    };
    offlineOnSocket = {
      needle = "sets `offline = true`";
      count = 0;
      system = mkSystem {
        vllm = nativeVllm // {
          models.test = {
            model = "example/test";
            offline = true;
          };
        };
      };
    };
    offlineBeyondLoopback = {
      needle = "sets `offline = true`";
      count = 1;
      system = mkExposed { offline = true; };
    };
    offlineWithoutFetch = {
      needle = "downloads its repositories itself";
      count = 1;
      system = mkSystem {
        vllm = nativeVllm // {
          fetch.enable = false;
          models.test = {
            model = "example/test";
            offline = true;
          };
        };
      };
    };
    # The gateway has no implicit listener.
    gatewayWithoutListener = {
      needle = "has no listener";
      count = 1;
      system = mkRoutable { };
    };
    containerWithoutPort = {
      needle = "which a container publishes";
      count = 1;
      system = mkContainer { vllm.models.test.port = null; };
    };
  };
in
{
  testAssertions = {
    expr = lib.mapAttrs (_: case: failing case.needle case.system) assertionCases;
    expected = lib.mapAttrs (_: case: case.count) assertionCases;
  };
}
