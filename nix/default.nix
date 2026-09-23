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
    let
      mkEvalCheck = pkgs.callPackage ./checks/lib.nix { };
    in
    {
      treefmt = {
        projectRootFile = "flake.nix";
        programs = {
          gofmt.enable = true;
          nixfmt.enable = true;
          ruff-check.enable = true;
          ruff-format.enable = true;
        };
      };
      checks = {
        inherit (config.packages) llmhop;
        inherit (config.legacyPackages) check-elf;
        cli = pkgs.callPackage ./checks/cli.nix { inherit mkEvalCheck; };
      }
      // lib.optionalAttrs (lib.elem system lib.platforms.linux) {
        inherit (config.packages) docker;
        vm = pkgs.callPackage ./checks/vm.nix { inherit self; };
        eval = pkgs.callPackage ./checks/eval.nix {
          inherit self mkEvalCheck;
          inherit (inputs.nixpkgs.lib) nixosSystem;
        };
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
      # Auto-discovered from ./pkgs so new builders drop in as files. The
      # builders are functions rather than packages: downstream calls them with
      # their own args, e.g.
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
