# The modules of NixOS and system-manager, typing `[Container]` keys with
# quadlet-nix's `sectionType`.
sectionType:
{ lib, ... }:
{
  imports =
    map (import ./backends/engine.nix sectionType) (lib.attrValues (import ./engines.nix lib))
    ++ [
      ./core.nix
      ./bundle.nix
      ./backends/watermark.nix
      (import ./gateways/llmhop.nix sectionType)
      (import ./gateways/smg.nix sectionType)
      (import ./gateways/bifrost.nix sectionType)
    ];
}
