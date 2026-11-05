{
  description = "Development inputs of llmhop, which stay out of consumers' lock files.";
  inputs = {
    # Inputs named like those of the parent flake would replace them in the partition.
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "";
    };
    # With its own nixpkgs, which its fork of userborn needs.
    system-manager = {
      url = "github:numtide/system-manager";
      inputs.flake-compat.follows = "";
    };
    # The overlay of flocken builds from our nixpkgs, so its own only needs `lib`.
    flocken = {
      url = "github:mirkolenz/flocken/v2";
      inputs = {
        nixpkgs.follows = "nixpkgs-lib";
        flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs-lib";
      };
    };
  };
  outputs = _: { };
}
