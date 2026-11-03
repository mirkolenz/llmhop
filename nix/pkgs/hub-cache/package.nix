# Prunes the hub cache of a worker and restarts its server. The
# output is the script itself, which the units run with a Python of their
# choice, so a bundle can use the host's. It finds `systemctl` on `PATH`.
{ runCommandLocal }:
runCommandLocal "hub-cache.py" { } ''
  cp ${./hub-cache.py} $out
''
