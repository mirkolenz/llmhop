{ lib, ... }:
{
  imports = map (import ./backends/quadlet.nix lib) (lib.attrNames (import ./engines.nix lib)) ++ [
    ./core.nix
    (import ./backends/watermark.nix lib).quadlet
    (import ./gateways/llmhop.nix lib).quadlet
    (import ./gateways/smg.nix lib).quadlet
    (import ./gateways/bifrost.nix lib).quadlet
  ];
}
