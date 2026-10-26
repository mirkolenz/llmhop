{
  lib,
  stdenvNoCC,
  mdbook,
  writeShellApplication,
  python3,
  pages,
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

    printf '\n# NixOS Options\n\n' >> src/SUMMARY.md
    mkdir -p src/nixos
    ${lib.concatMapStringsSep "\n" (page: ''
      echo "- [${page.title}](nixos/${page.name}.md)" >> src/SUMMARY.md
      ln -s ${page.value} src/nixos/${page.name}.md
    '') pages}

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
