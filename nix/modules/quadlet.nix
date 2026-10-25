{ lib, ... }:
let
  inherit (import ./lib lib) engines quadlet watermark;
in
{
  imports = [
    ./core.nix
    watermark.quadlet
  ]
  ++ map quadlet.mkBackend (lib.attrNames engines);
}
