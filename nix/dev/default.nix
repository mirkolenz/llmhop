{
  inputs,
  self,
  lib,
  ...
}:
{
  imports = [ inputs.treefmt-nix.flakeModule ];
  perSystem =
    {
      pkgs,
      config,
      system,
      ...
    }:
    let
      # The gateway and a backend on a host managed by system-manager.
      mkSystemManager =
        llmhop:
        inputs.system-manager.lib.makeSystemConfig {
          modules = lib.singleton {
            imports = [ self.systemManagerModules.default ];
            nixpkgs.hostPlatform = system;
            services.llmhop = {
              gateway = {
                enable = true;
                listen.default.port = 8080;
              };
            }
            // llmhop;
          };
        };
      units = llmhop: (mkSystemManager llmhop).config.environment.etc."systemd/system".source;
      native = units {
        llama-cpp = {
          enable = true;
          models.native.model = "example/native-GGUF:Q4_K_M";
        };
      };
      container = units {
        runtime = "container";
        vllm = {
          enable = true;
          container.image = "docker.io/vllm/vllm-openai:latest";
          models.container = {
            model = "example/container";
            port = 8001;
          };
        };
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        system-manager = pkgs.runCommand "llmhop-system-manager" { } ''
          set -euo pipefail
          cd ${native}
          for unit in llmhop.service llama-cpp-native.service; do
            test -e "system-manager.target.wants/$unit"
          done
          test -e sockets.target.wants/llmhop-default.socket
          grep -q '^ExecStart=.*/bin/llama-server' llama-cpp-native.service
          grep -qx 'Sockets=llmhop-default.socket' llmhop.service
          grep -qx 'ExecStart=+/usr/bin/systemctl try-restart --no-block llama-cpp-native.service' \
            llama-cpp-native-refresh.service
          cd ${container}
          for unit in llmhop.service vllm-container.service; do
            test -e "system-manager.target.wants/$unit"
          done
          grep -q '^ExecStart=.*/podman run .*--userns auto:size=65536' vllm-container.service
          touch $out
        '';
      };
      treefmt = {
        projectRootFile = "flake.nix";
        programs = {
          gofmt.enable = true;
          nixfmt.enable = true;
          ruff-check.enable = true;
          ruff-format.enable = true;
        };
      };
      # Reads `VERSION` and `GITHUB_TOKEN` when it runs.
      packages.docker-manifest = (inputs.flocken.overlays.default pkgs pkgs).mkDockerManifest {
        github.enable = true;
        images = with self.packages; [
          x86_64-linux.docker
          aarch64-linux.docker
        ];
      };
      devShells.default = pkgs.mkShell {
        # encoding/json/v2 is still behind an experiment.
        env.GOEXPERIMENT = "jsonv2";
        packages = with pkgs; [
          go
          goreleaser
          config.treefmt.build.wrapper
        ];
      };
    };
}
