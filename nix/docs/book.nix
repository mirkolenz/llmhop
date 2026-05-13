{
  lib,
  stdenvNoCC,
  mdbook,
  writeShellApplication,
  python3,
  options,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "book";
  nativeBuildInputs = [ mdbook ];
  src = lib.fileset.toSource {
    root = ../../docs;
    fileset = lib.fileset.unions [
      ../../docs/book.toml
      ../../docs/src
    ];
  };
  buildPhase = ''
    runHook preBuild

    ln -s ${../../README.md} src/README.md
    ln -s ${options} src/nixos-options.md

    mdbook build

    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall

    mv book $out

    runHook postInstall
  '';
  passthru.serve = writeShellApplication {
    name = "serve";
    runtimeInputs = [ python3 ];
    text = ''
      python -m http.server \
        --bind 127.0.0.1 \
        --directory ${finalAttrs.finalPackage}
    '';
  };
})
