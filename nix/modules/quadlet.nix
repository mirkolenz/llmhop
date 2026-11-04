# The Quadlet modules, typing `[Container]` keys with quadlet-nix's
# `sectionType`.
sectionType:
{ lib, ... }:
{
  imports =
    map (import ./backends/quadlet.nix lib sectionType) (lib.attrNames (import ./engines.nix lib))
    ++ [
      ./core.nix
      ./bundle.nix
      (import ./backends/watermark.nix lib).quadlet
      ((import ./gateways/llmhop.nix lib).quadlet sectionType)
      ((import ./gateways/smg.nix lib).quadlet sectionType)
      ((import ./gateways/bifrost.nix lib).quadlet sectionType)
    ];
}
