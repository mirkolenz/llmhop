{
  inputs,
  self,
  lib,
  ...
}:
{
  systems = lib.remove "x86_64-darwin" (import inputs.systems);
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
      inherit (pkgs.stdenv.hostPlatform) isLinux;
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
        inherit (config.legacyPackages) check-elf hub-prune;
        cli = pkgs.callPackage ./checks/cli.nix { inherit mkEvalCheck; };
      }
      // lib.optionalAttrs isLinux {
        inherit (config.packages) docker;
        vm = pkgs.callPackage ./checks/vm.nix { inherit self; };
        bundle = pkgs.callPackage ./checks/bundle.nix { inherit (config.legacyPackages) mkQuadletBundle; };
        eval = pkgs.callPackage ./checks/eval.nix {
          inherit mkEvalCheck;
          inherit (config.legacyPackages) mkQuadletSystem;
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
      // lib.optionalAttrs isLinux {
        docker = pkgs.callPackage ./docker.nix {
          inherit (config.packages) llmhop;
        };
      };
      # Auto-discovered from ./pkgs so new builders drop in as files. The
      # builders are functions rather than packages: downstream calls them with
      # their own args, e.g.
      #   services.llmhop.vllm.package =
      #     inputs.llmhop.legacyPackages.${system}.mkUvEnv { workspaceRoot = ./vllm-env; };
      # A scope, so every builder may take the others as arguments.
      legacyPackages =
        lib.makeScope pkgs.newScope (
          self:
          {
            inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
          }
          // lib.packagesFromDirectoryRecursive {
            inherit (self) callPackage;
            directory = ./pkgs;
          }
        )
        // {
          # A minimal system with Quadlet and llmhop's modules, configured by
          # `modules`, and its Quadlet units as files for a host without Nix,
          # see `services.llmhop.bundle`.
          mkQuadletSystem =
            { modules }:
            inputs.nixpkgs.lib.nixosSystem {
              modules = [
                self.nixosModules.quadlet
                {
                  nixpkgs.pkgs = pkgs;
                  system.stateVersion = lib.trivial.release;
                  boot.isContainer = true;
                  virtualisation.quadlet.enable = true;
                }
              ]
              ++ modules;
            };
          mkQuadletBundle =
            args: (config.legacyPackages.mkQuadletSystem args).config.services.llmhop.bundle.package;
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
