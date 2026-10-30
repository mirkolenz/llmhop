# Prunes, records and validates the hub cache of a worker. The minimal Python
# suffices, since it only uses the standard library, and treefmt lints it
# instead of flake8 at build time, which would pull a full Python into every
# deployment.
{
  lib,
  writers,
  replaceVars,
  python3Minimal,
  python3Packages,
  buildPackages,
  systemd,
}:
writers.makePythonWriter python3Minimal python3Packages buildPackages.python3Packages
  "llmhop-hub-cache"
  {
    doCheck = false;
  }
  (replaceVars ./script.py { systemctl = lib.getExe' systemd "systemctl"; })
