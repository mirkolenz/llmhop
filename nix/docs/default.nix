{ ... }:
{
  perSystem =
    { pkgs, config, ... }:
    let
      options = pkgs.callPackage ./options.nix { } ../module;
    in
    {
      packages = {
        book = pkgs.callPackage ./book.nix { inherit options; };
        docs = config.packages.book;
        nixos-options = options;
      };
    };
}
