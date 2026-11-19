# The script explains itself. `writePython3` lints it at build time.
{
  lib,
  writers,
}:
writers.writePython3Bin "llmhopctl" { } (lib.readFile ./script.py)
