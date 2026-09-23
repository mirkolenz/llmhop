# The script explains itself. `writePython3` lints it at build time, so a
# mistake in it surfaces long before a wheel or environment finishes building.
{
  lib,
  writers,
}:
writers.writePython3 "check-elf" { } (lib.readFile ./script.py)
