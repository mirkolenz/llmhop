# The script explains itself; `writePython3` lints it at build time, so a
# mistake in it surfaces long before an environment finishes building.
{
  lib,
  writers,
}:
writers.writePython3 "check-missing-libs" { } (lib.readFile ./script.py)
