{
  inputs,
  self,
  lib,
  ...
}:
let
  version = self.shortRev or self.dirtyShortRev or "dev";
  # Keyed, so importing both modules sets the version once.
  versionModule = {
    key = "llmhop-version";
    services.llmhop.version = version;
  };
in
{
  systems = lib.remove "x86_64-darwin" (import inputs.systems);
  imports = [
    inputs.treefmt-nix.flakeModule
    ./docs
  ];
  flake = {
    nixosModules = {
      default.imports = [
        ./modules/core.nix
        versionModule
      ];
      quadlet.imports = [
        inputs.quadlet-nix.nixosModules.default
        (import ./modules/quadlet.nix inputs.quadlet-nix.lib.sectionType)
        versionModule
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
      # Every file of ./pkgs, a builder or a package, which may take the others
      # as arguments. Only the builders meant for downstream are published.
      scope = lib.makeScope pkgs.newScope (
        self:
        {
          inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
        }
        // lib.packagesFromDirectoryRecursive {
          inherit (self) callPackage;
          directory = ./pkgs;
        }
      );
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
        inherit (scope) check-elf;
        cli = pkgs.callPackage ./checks/cli.nix { inherit mkEvalCheck; };
      }
      // lib.optionalAttrs isLinux {
        inherit (config.packages) docker;
        vm = pkgs.callPackage ./checks/vm.nix { inherit self; };
        bundle = pkgs.callPackage ./checks/bundle.nix { inherit (config.legacyPackages) mkQuadletBundle; };
        eval = pkgs.callPackage ./checks/eval.nix {
          inherit mkEvalCheck self;
          inherit (inputs.quadlet-nix.legacyPackages.${system}) mkBundleSystem;
        };
      };
      packages = {
        default = config.packages.llmhop;
        llmhop = pkgs.callPackage ./package.nix { inherit version; };
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
        # Reads `VERSION` and `GITHUB_TOKEN` when it runs.
        docker-manifest = inputs.flocken.legacyPackages.${system}.mkDockerManifest {
          github.enable = true;
          images = with self.packages; [
            x86_64-linux.docker
            aarch64-linux.docker
          ];
        };
      };
      # The builders are functions rather than packages: downstream calls them
      # with their own args, e.g.
      #   services.llmhop.vllm.package =
      #     inputs.llmhop.legacyPackages.${system}.mkUvEnv { workspaceRoot = ./vllm-env; };
      legacyPackages = {
        inherit (scope) mkUvEnv mkCudaHome;
        # The Quadlet units of a minimal system with llmhop's modules,
        # configured by `modules`, as files for a host without Nix,
        # see `virtualisation.quadlet.bundle` of quadlet-nix.
        mkQuadletBundle =
          { modules }:
          inputs.quadlet-nix.legacyPackages.${system}.mkBundle {
            modules = [ self.nixosModules.quadlet ] ++ modules;
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
