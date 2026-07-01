{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      moduleOptions =
        (lib.evalModules {
          modules = [
            ../modules/quadlet.nix
            {
              _module.args = {
                inherit pkgs;
                utils = { };
              };
              _module.check = false;
            }
          ];
        }).options;
      mkOptions =
        options:
        (pkgs.nixosOptionsDoc {
          inherit options;
          # hide /nix/store/* prefix
          transformOptions = opt: opt // { declarations = [ ]; };
        }).optionsCommonMark;
      # Every backend is a nested attrset under `services.llmhop`; the top-level
      # options next to them form the core page. Splitting on `isOption` keeps
      # new backends documented without touching this file.
      backends = lib.filterAttrs (_: v: !lib.isOption v) moduleOptions.services.llmhop;
      sections = [
        {
          title = "NixOS Options";
          prefix = "nixos";
          pages = [
            {
              name = "core";
              title = "Core";
              value = mkOptions (lib.filterAttrs (_: lib.isOption) moduleOptions.services.llmhop);
            }
          ]
          ++ lib.mapAttrsToList (name: options: {
            inherit name;
            title = name;
            value = mkOptions options;
          }) backends;
        }
      ];
    in
    {
      packages.docs = pkgs.callPackage ./book.nix { inherit sections; };
    };
}
