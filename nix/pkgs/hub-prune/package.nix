{
  lib,
  stdenvNoCC,
  python3Minimal,
}:
stdenvNoCC.mkDerivation {
  pname = "hub-prune";
  version = "dev";
  src = ./hub-prune.py;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/hub-prune
    runHook postInstall
  '';

  # Runs with the `python3` on `PATH`, so a bundle uses the host's.
  dontPatchShebangs = true;

  doInstallCheck = true;
  nativeInstallCheckInputs = [ python3Minimal ];
  # Prunes a fake hub cache.
  installCheckPhase = ''
    runHook preInstallCheck

    hub=$PWD/hub
    repo=$hub/models--a--b
    spec='{"hub":"'$hub'","repositories":[{"name":"models--a--b","revision":"main"},{"name":"models--c--d","revision":null}]}'
    prune() { python3 $out/bin/hub-prune "$spec"; }

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

    prune
    test ! -e $hub/models--stale
    test ! -e $repo/refs/pr -a ! -e $repo/snapshots/p1 -a ! -e $repo/blobs/p1
    test -e $repo/snapshots/a1
    test -e $hub/models--c--d/snapshots/x1 -a -e $hub/models--c--d/snapshots/y1

    # Pruning drops the previous snapshot of a moved ref and its blobs.
    download $repo b2
    prune
    test ! -e $repo/snapshots/a1 -a ! -e $repo/blobs/a1
    test -e $repo/snapshots/b2

    runHook postInstallCheck
  '';

  meta = {
    description = "Prune the hub cache of an llmhop worker";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ mirkolenz ];
    homepage = "https://github.com/mirkolenz/llmhop";
    mainProgram = "hub-prune";
  };
}
