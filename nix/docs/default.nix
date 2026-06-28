{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      moduleOptions =
        (lib.evalModules {
          modules = [
            ../module/quadlet.nix
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
      subpages = [
        "llama-cpp"
        "sglang"
        "vllm"
      ];
      sections = [
        {
          title = "NixOS Options";
          prefix = "nixos";
          pages = [
            {
              name = "core";
              title = "Core";
              value = mkOptions (lib.removeAttrs moduleOptions.services.llmhop subpages);
            }
          ]
          ++ map (subpage: {
            name = subpage;
            title = subpage;
            value = mkOptions moduleOptions.services.llmhop.${subpage};
          }) subpages;
        }
      ];
    in
    {
      packages.docs = pkgs.callPackage ./book.nix { inherit sections; };
    };
}
