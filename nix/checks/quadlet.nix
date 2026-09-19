{
  lib,
  nixosSystem,
  pkgs,
  self,
  stdenv,
}:
let
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
    models.test.quadlet.containerConfig.User = "1000";
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
        quadlet.containerConfig.User = "1000";
      };
    };
  };

  rootfulWorker = rootful.virtualisation.quadlet.containers.vllm-test;
  rootlessWorker = rootless.virtualisation.quadlet.containers.vllm-test;

  failures = lib.runTests {
    testRootfulScope = {
      expr = rootfulWorker.uid;
      expected = null;
    };

    testNativeConfigLayers = {
      expr = {
        inherit (rootfulWorker.containerConfig) User UserNS Volume;
        inherit (rootfulWorker.serviceConfig) MemoryMax;
        inherit (rootfulWorker.unitConfig) StartLimitBurst;
        inherit (rootfulWorker.quadletConfig) DefaultDependencies;
      };
      expected = {
        User = "1000";
        UserNS = "auto:size=65536";
        Volume = [ "/var/cache/vllm:/cache:idmap,Z" ];
        MemoryMax = "64G";
        StartLimitBurst = 7;
        DefaultDependencies = false;
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
        inherit (sglang.virtualisation.quadlet.containers.sglang-gateway.containerConfig)
          User
          UserNS
          ;
      };
      expected = {
        User = "1000";
        UserNS = "host";
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
