# Prunes the hub cache of a backend. The minimal Python suffices, since it only
# uses the standard library, and treefmt lints it instead of flake8 at build
# time, which would pull a full Python into every deployment.
{
  lib,
  writers,
  python3Minimal,
  python3Packages,
  buildPackages,
}:
writers.makePythonWriter python3Minimal python3Packages buildPackages.python3Packages "prune-hub" {
  doCheck = false;
} (lib.readFile ./script.py)
