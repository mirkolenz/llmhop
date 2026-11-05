{
  inputs,
  self,
  lib,
  config,
  ...
}:
let
  devFlake = config.partitions.dev.module.flake;
  version = self.shortRev or self.dirtyShortRev or "dev";
  # llmhop's modules on top of those of quadlet-nix for the same platform.
  mkModule = quadlet: {
    imports = [
      quadlet
      (lib.modules.importApply ./modules inputs.quadlet-nix.lib.sectionType)
      { services.llmhop.version = version; }
    ];
  };
in
{
  systems = lib.remove "x86_64-darwin" (import inputs.systems);
  imports = [
    inputs.flake-parts.flakeModules.partitions
    ./docs
  ];
  # The dev partition loads its inputs only when these attributes are evaluated.
  partitions.dev = {
    extraInputsFlake = ./dev;
    module = ./dev;
  };
  partitionedAttrs = {
    checks = "dev";
    devShells = "dev";
    formatter = "dev";
  };
  flake = {
    nixosModules.default = mkModule inputs.quadlet-nix.nixosModules.default;
    # The host's systemd runs the units, not the store one of system-manager.
    systemManagerModules.default = {
      imports = [ (mkModule inputs.quadlet-nix.systemManagerModules.default) ];
      services.llmhop.systemctl = "/usr/bin/systemctl";
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
      check-elf = pkgs.callPackage ./pkgs/check-elf/package.nix { };
      mkCudaHome = pkgs.callPackage ./pkgs/mkCudaHome.nix { };
      mkUvEnv = pkgs.callPackage ./pkgs/mkUvEnv.nix {
        inherit check-elf;
        inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;
      };
    in
    {
      checks = {
        inherit (config.packages) llmhop;
        inherit check-elf;
        cli = pkgs.callPackage ./checks/cli.nix { inherit mkEvalCheck; };
      }
      // lib.optionalAttrs isLinux {
        inherit (config.packages) docker;
        vm = pkgs.callPackage ./checks/vm.nix { inherit self; };
        bundle = pkgs.callPackage ./checks/bundle.nix {
          inherit (config.legacyPackages) mkQuadletBundle;
          inherit (config.packages) vllm-bundle;
        };
        eval = pkgs.callPackage ./checks/eval.nix {
          inherit mkEvalCheck self;
          mkBundleSystem = { modules }: inputs.quadlet-nix.lib.mkBundleSystem { inherit pkgs modules; };
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
        vllm-bundle = config.legacyPackages.mkQuadletBundle { modules = [ ./bundles/vllm.nix ]; };
      };
      # The builders are functions rather than packages: downstream calls them
      # with their own args, e.g.
      #   services.llmhop.vllm.package =
      #     inputs.llmhop.legacyPackages.${system}.mkUvEnv { workspaceRoot = ./vllm-env; };
      legacyPackages = {
        inherit mkUvEnv mkCudaHome;
        # Not a package, so `nix flake check` does not load the dev partition.
        inherit (devFlake.packages.${system}) docker-manifest;
        # The Quadlet units of a minimal system with llmhop's modules,
        # configured by `modules`, as files for a host without Nix,
        # see `virtualisation.quadlet.bundle` of quadlet-nix.
        mkQuadletBundle =
          { modules }:
          inputs.quadlet-nix.lib.mkBundle {
            inherit pkgs;
            modules = [
              self.nixosModules.default
              { services.llmhop.runtime = lib.mkDefault "quadlet"; }
            ]
            ++ modules;
          };
      };
    };
}
