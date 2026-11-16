{
  description = "Development inputs of llmhop, which stay out of consumers' lock files.";
  inputs = {
    # Replaces the nixpkgs of the parent flake in the partition, since `follows`
    # cannot reach the parent's inputs. Keep it at the revision of ../../flake.lock.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "";
    };
    # Its fork of userborn follows its nixpkgs, and with it ours.
    system-manager = {
      url = "github:numtide/system-manager";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "";
      };
    };
    flocken = {
      url = "github:mirkolenz/flocken/v2";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
      };
    };
  };
  outputs = _: { };
}
