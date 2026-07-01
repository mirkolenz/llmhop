{
  inputs,
  self,
  lib,
  ...
}:
{
  systems = import inputs.systems;
  imports = [
    inputs.treefmt-nix.flakeModule
    ./docs
  ];
  flake = {
    nixosModules = {
      default = ./modules/core.nix;
      quadlet.imports = [
        inputs.quadlet-nix.nixosModules.default
        ./modules/quadlet.nix
      ];
    };
    lib = import ./modules/lib.nix lib;
  };
  perSystem =
    {
      pkgs,
      system,
      config,
      ...
    }:
    {
      treefmt = {
        projectRootFile = "flake.nix";
        programs = {
          gofmt.enable = true;
          nixfmt.enable = true;
        };
      };
      checks = {
        inherit (config.packages) llmhop;
      }
      // lib.optionalAttrs (lib.elem system lib.platforms.linux) {
        inherit (config.packages) docker;
        module = pkgs.callPackage ./test.nix { inherit self; };
      };
      packages = {
        default = config.packages.llmhop;
        llmhop = pkgs.callPackage ./package.nix { };
        release-env = pkgs.buildEnv {
          name = "release-env";
          paths = with pkgs; [
            go
            goreleaser
          ];
        };
      }
      // lib.optionalAttrs (lib.elem system lib.platforms.linux) {
        docker = pkgs.callPackage ./docker.nix {
          inherit (config.packages) llmhop;
        };
      };
      # Auto-discovered from ./pkgs so new builders drop in as files. Each is a
      # function, not a package: downstream calls it with its own args, e.g.
      #   services.llmhop.vllm.package =
      #     inputs.llmhop.legacyPackages.${system}.mkUvEnv { workspaceRoot = ./vllm-env; };
      legacyPackages =
        lib.packagesFromDirectoryRecursive {
          callPackage = pkgs.newScope {
            inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
          };
          directory = ./pkgs;
        }
        // {
          docker-manifest = inputs.flocken.legacyPackages.${system}.mkDockerManifest {
            github = {
              enable = true;
              token = "$GH_TOKEN";
            };
            version = builtins.getEnv "VERSION";
            imageStreams = with self.packages; [
              x86_64-linux.docker
              aarch64-linux.docker
            ];
          };
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
