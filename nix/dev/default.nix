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
      # A gateway and backends of both kinds on a host managed by system-manager.
      systemManager = inputs.system-manager.lib.makeSystemConfig {
        modules = lib.singleton {
          imports = [ self.systemManagerModules.default ];
          nixpkgs.hostPlatform = system;
          services.llmhop = {
            gateway.type = "llmhop";
            llama-cpp = {
              enable = true;
              models.native.model = "example/native-GGUF:Q4_K_M";
            };
            vllm = {
              runtime = "quadlet";
              enable = true;
              container.image = "docker.io/vllm/vllm-openai:latest";
              models.container.model = "example/container";
            };
          };
        };
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        system-manager = pkgs.runCommand "llmhop-system-manager" { } ''
          set -euo pipefail
          cd ${systemManager.config.environment.etc."systemd/system".source}
          for unit in llmhop.service llama-cpp-native.service vllm-container.service; do
            test -e "system-manager.target.wants/$unit"
          done
          test -e sockets.target.wants/llmhop-default.socket
          test -e vllm-image.service -a -e vllm-container-fetch.service
          grep -q '^ExecStart=.*/podman run ' vllm-container.service
          grep -q '^ExecStart=.*/bin/llama-server' llama-cpp-native.service
          grep -qx 'Sockets=llmhop-default.socket' llmhop.service
          grep -qx 'ExecStart=+/usr/bin/systemctl try-restart --no-block vllm-container.service' \
            vllm-container-refresh.service
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
        packages = with pkgs; [
          go
          goreleaser
          config.treefmt.build.wrapper
        ];
      };
    };
}
