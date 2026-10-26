# The helpers shared by llmhop's modules, each file instantiated once.
lib:
let
  common = import ./common.nix lib;
  native = import ./native.nix lib common;
  quadlet = import ./quadlet.nix lib common;
  gateway = import ./gateway.nix lib { inherit common native quadlet; };
in
common
// {
  inherit native quadlet;
  watermark = import ./watermark.nix lib { inherit common native quadlet; };
  builtin = import ./builtin.nix lib { inherit common gateway native; };
  smg = import ./smg.nix lib { inherit common gateway quadlet; };
  bifrost = import ./bifrost.nix lib { inherit common gateway quadlet; };
}
