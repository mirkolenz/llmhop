{
  lib,
  stdenvNoCC,
  python3Minimal,
  writeShellScriptBin,
}:
let
  # Only logs the server actions.
  systemctl = writeShellScriptBin "systemctl" ''
    [[ $1 == is-failed ]] && exit 1
    echo "$*" >> "$SYSTEMCTL_LOG"
  '';
in
stdenvNoCC.mkDerivation {
  pname = "hub-cache";
  version = "dev";
  src = ./hub-cache.py;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/hub-cache
    runHook postInstall
  '';

  # Runs with the `python3` on `PATH`, so a bundle uses the host's.
  dontPatchShebangs = true;

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    python3Minimal
    systemctl
  ];
  # Drives both commands on a fake hub cache.
  installCheckPhase = ''
    runHook preInstallCheck

    export SYSTEMCTL_LOG=$PWD/systemctl.log
    hub=$PWD/hub
    repo=$hub/models--a--b
    spec='{"hub":"'$hub'","repositories":[{"name":"models--a--b","revision":"main"},{"name":"models--c--d","revision":null}]}'
    run() { python3 $out/bin/hub-cache "$@"; }

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

    runHook postInstallCheck
  '';

  meta = {
    description = "Prune the hub cache of an llmhop worker and restart its server";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ mirkolenz ];
    homepage = "https://github.com/mirkolenz/llmhop";
    mainProgram = "hub-cache";
  };
}
