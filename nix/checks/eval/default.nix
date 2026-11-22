# Evaluates llmhop's modules in minimal systems and checks what they render.
{
  lib,
  mkEvalCheck,
  mkBundleSystem,
  pkgs,
  self,
}:
let
  systems = import ./systems.nix {
    inherit
      lib
      mkBundleSystem
      pkgs
      self
      ;
  };
  tests = lib.mergeAttrsList (
    map (file: import file systems) [
      ./assertions.nix
      ./tests.nix
    ]
  );
  inherit (systems) container;

  units = pkgs.symlinkJoin {
    name = "llmhop-generated-units";
    paths = container.virtualisation.quadlet.generatedUnits;
  };

in
mkEvalCheck {
  description = "Module evaluation tests";
  output = pkgs.runCommand "llmhop-eval-tests" { } ''
    test -e ${units}/lib/systemd/system/vllm-test.service
    test -e ${units}/lib/systemd/system/vllm-watermark.service
    test -e ${units}/lib/systemd/system/llmhop.service
    touch $out
  '';
  inherit tests;
}
