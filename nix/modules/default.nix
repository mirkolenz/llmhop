# The modules of NixOS and system-manager, typing `[Container]` keys with
# quadlet-nix's `sectionType`.
sectionType:
{ lib, ... }:
{
  imports = [
    (import ./core.nix sectionType)
    ./gateway
  ]
  ++ map (import ./backends/engine.nix) (lib.attrValues (import ./engines.nix lib));
}
