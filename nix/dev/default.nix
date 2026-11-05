{ inputs, self, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];
  perSystem =
    { pkgs, config, ... }:
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
