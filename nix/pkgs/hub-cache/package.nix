# Prunes, records, restores and validates the hub cache of a worker. The
# output is the script itself, which the units run with a Python of their
# choice, so a bundle can use the host's. It finds `systemctl` on `PATH`.
{ runCommandLocal }:
runCommandLocal "hub-cache.py" { } ''
  cp ${./hub-cache.py} $out
''
