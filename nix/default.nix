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
  ];
  flake = {
    nixosModules.default = ./module.nix;
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
        module = pkgs.callPackage ./test.nix { };
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
      legacyPackages.docker-manifest = inputs.flocken.legacyPackages.${system}.mkDockerManifest {
        github = {
          enable = true;
          token = "$GH_TOKEN";
        };
        version = builtins.getEnv "VERSION";
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
