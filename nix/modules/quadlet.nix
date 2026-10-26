{ lib, ... }:
let
  inherit (import ./lib lib)
    bifrost
    engines
    quadlet
    smg
    watermark
    ;
in
{
  imports = [
    ./core.nix
    watermark.quadlet
    smg.quadlet
    bifrost.quadlet
  ]
  ++ map quadlet.mkBackend (lib.attrNames engines);
}
