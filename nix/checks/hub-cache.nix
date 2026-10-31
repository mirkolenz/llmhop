# Drives the hub-cache tool through a fetcher's lifecycle on a fake hub cache,
# with a `systemctl` that only logs the server actions.
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
  apply() { : > "$SYSTEMCTL_LOG"; run apply server $PWD/completed "$spec"; }

  # Downloads `commit` of `repository`, as `hf download` would.
  download() {
    mkdir -p "$1/refs" "$1/snapshots/$2" "$1/blobs"
    echo -n "$2" > "$1/blobs/$2"
    ln -sfn "../../blobs/$2" "$1/snapshots/$2/model"
    echo "$2" > "$1/refs/''${3:-main}"
  }

  download $repo a1
  # llama.cpp pins no revision, so every ref stays.
  download $hub/models--c--d x1
  download $hub/models--c--d y1 trunk
  mkdir -p $hub/models--stale/snapshots/s1

  # A first complete download restarts the server.
  run prune "$spec"
  apply
  grep -qx "try-restart --no-block server" "$SYSTEMCTL_LOG"
  test ! -e $hub/models--stale
  test -e $hub/models--c--d/snapshots/x1 -a -e $hub/models--c--d/snapshots/y1

  # An unchanged download leaves it running.
  apply
  grep -q restart "$SYSTEMCTL_LOG" && exit 1

  # A changed one prunes the previous snapshot and restarts it.
  download $repo b2
  run prune "$spec"
  apply
  grep -q try-restart "$SYSTEMCTL_LOG"
  test ! -e $repo/snapshots/a1 -a ! -e $repo/blobs/a1

  # An interrupted download moves the ref to an incomplete snapshot, which
  # the server refuses until the fetcher restores the ref.
  mkdir -p $repo/snapshots/c3
  echo c3 > $repo/refs/main
  run load $PWD/completed "$spec" && exit 1
  run restore $PWD/completed "$spec"
  test "$(cat $repo/refs/main)" = b2
  run load $PWD/completed "$spec"

  touch $out
''
