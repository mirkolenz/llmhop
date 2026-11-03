# Drives the hub-cache tool on a fake hub cache, with a `systemctl` that only
# logs the server actions.
{
  hub-cache,
  python3Minimal,
  runCommand,
  writeShellScriptBin,
}:
let
  systemctl = writeShellScriptBin "systemctl" ''
    [[ $1 == is-failed ]] && exit 1
    echo "$*" >> "$SYSTEMCTL_LOG"
  '';
in
runCommand "llmhop-hub-cache-tests" { nativeBuildInputs = [ systemctl ]; } ''
  set -euo pipefail
  export SYSTEMCTL_LOG=$PWD/systemctl.log
  hub=$PWD/hub
  repo=$hub/models--a--b
  spec='{"hub":"'$hub'","repositories":[{"name":"models--a--b","revision":"main"},{"name":"models--c--d","revision":null}]}'
  run() { ${python3Minimal.interpreter} ${hub-cache} "$@"; }

  # Downloads `commit` of `repository`, as `hf download` would.
  download() {
    mkdir -p "$1/refs" "$1/snapshots/$2" "$1/blobs"
    echo -n "$2" > "$1/blobs/$2"
    ln -sfn "../../blobs/$2" "$1/snapshots/$2/model"
    echo "$2" > "$1/refs/''${3:-main}"
  }

  download $repo a1
  download $repo p1 pr
  # llama.cpp pins no revision, so every ref stays.
  download $hub/models--c--d x1
  download $hub/models--c--d y1 trunk
  mkdir -p $hub/models--stale/snapshots/s1

  run prune "$spec"
  test ! -e $hub/models--stale
  test ! -e $repo/refs/pr -a ! -e $repo/snapshots/p1 -a ! -e $repo/blobs/p1
  test -e $repo/snapshots/a1
  test -e $hub/models--c--d/snapshots/x1 -a -e $hub/models--c--d/snapshots/y1

  # Pruning drops the previous snapshot of a moved ref and its blobs.
  download $repo b2
  run prune "$spec"
  test ! -e $repo/snapshots/a1 -a ! -e $repo/blobs/a1
  test -e $repo/snapshots/b2

  # A running server restarts.
  run restart server
  grep -qx "try-restart --no-block server" "$SYSTEMCTL_LOG"

  touch $out
''
