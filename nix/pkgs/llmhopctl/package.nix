# The script explains itself. `writePython3` lints it at build time, and
# `tests.doctest` runs its doctests, which cover what `top` parses.
{
  lib,
  writers,
  python3Packages,
  runCommandLocal,
}:
let
  libraries = with python3Packages; [
    httpx2
    rich
    typer
  ];
  python = python3Packages.python.withPackages (_: libraries);
  llmhopctl = writers.writePython3Bin "llmhopctl" { inherit libraries; } (lib.readFile ./script.py);
in
llmhopctl.overrideAttrs {
  passthru.tests.doctest = runCommandLocal "llmhopctl-doctest" { } ''
    ${lib.getExe python} -m doctest ${./script.py}
    ln -s ${llmhopctl} $out
  '';
}
