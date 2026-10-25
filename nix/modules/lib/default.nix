# The helpers shared by llmhop's modules, each file instantiated once.
lib:
let
  common = import ./common.nix lib;
  native = import ./native.nix lib common;
  quadlet = import ./quadlet.nix lib common;
in
common
// {
  inherit native quadlet;
  watermark = import ./watermark.nix lib { inherit common native quadlet; };
}
