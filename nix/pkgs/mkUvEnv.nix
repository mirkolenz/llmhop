# Builds a Python virtual environment from a uv workspace using prebuilt wheels.
# Wheels are patched for NixOS: the GPU driver runpath is baked in, distro
# libraries are resolved from nixpkgs, and unresolvable ones are deferred.
{
  lib,
  pkgs,
  uv2nix,
  pyproject-nix,
  pyproject-build-systems,
}:
{
  workspaceRoot,
  # Defaults to the lowest interpreter the lock's `requires-python` allows, the
  # same one uv resolves against, so the version is stated once.
  python ? null,
  sourcePreference ? "wheel",
  # Globs of unresolved `DT_NEEDED` entries that do not fail the build. Most of
  # them are unresolvable on purpose (the host driver, sibling wheels that only
  # meet each other once the venv merges them, alternative backends), so the
  # default accepts everything; narrow it to see the whole list.
  ignoreMissingLibs ? [ "*" ],
  # Merged into the corresponding attribute of every wheel. Which libraries a
  # workspace needs follows from what it locks, so there are no defaults: see
  # the README.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Directories appended to every wheel's runpath, for libraries reached by a
  # bare `dlopen("libfoo.so")` from Python, as cffi and ctypes do. Nothing names
  # those in the ELF, so `buildInputs` cannot resolve them.
  runtimePaths ? [ ],
  # Globs of paths, relative to the environment root, that more than one package
  # installs with differing contents; the first one encountered wins. Wheels
  # routinely leak their in-tree PEP 517 backend into the distribution, so a set
  # this size collides over files nothing ever imports, and upstream's default
  # is to fail. Narrow it to have a genuine conflict reported again.
  venvIgnoreCollisions ? [ "*" ],
  overlays ? [ ],
  deps ? { },
  name ? "uv-env",
}:
let
  uvLock = lib.importTOML (workspaceRoot + "/uv.lock");

  pep440 = pyproject-nix.lib.pep440;

  allowedByLock = pyproject-nix.lib.util.filterPythonInterpreters {
    requires-python = pep440.parseVersionConds uvLock.requires-python;
    inherit (pkgs) pythonInterpreters;
  };

  olderFirst =
    a: b:
    pep440.compareVersions (pep440.parseVersion a.pythonVersion) (pep440.parseVersion b.pythonVersion)
    < 0;

  # uv resolves against the lowest interpreter the lock admits, so building
  # against any other one would test something the lock never solved for.
  interpreter =
    if python != null then
      python
    else
      lib.throwIf (allowedByLock == [ ])
        "mkUvEnv: nixpkgs has no CPython satisfying `requires-python = \"${uvLock.requires-python}\"`; pass `python` explicitly."
        (lib.head (lib.sort olderFirst allowedByLock));

  workspace = uv2nix.lib.workspace.loadWorkspace { inherit workspaceRoot uvLock; };

  projectOverlay = workspace.mkPyprojectOverlay { inherit sourcePreference; };

  # Every package the lock resolves, rather than a hand-curated list of the ones
  # known to ship GPU extensions: a wheel growing one, or a new dependency
  # appearing on an upstream bump, would otherwise silently fail to build.
  # The fixups are no-ops for the pure-Python majority, which ships no ELF files.
  lockedNames = map (package: package.name) uvLock.package;

  wheelOverlay =
    _final: prev:
    lib.genAttrs (lib.filter (name: prev ? ${name}) lockedNames) (
      name:
      prev.${name}.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [ ]) ++ [ pkgs.autoAddDriverRunpath ] ++ nativeBuildInputs;
        buildInputs = (old.buildInputs or [ ]) ++ buildInputs;
        appendRunpaths = (old.appendRunpaths or [ ]) ++ runtimePaths;
        # Wheels reach their sibling libraries through `$ORIGIN`, and dispatch
        # shims such as `libcudnn.so.9` `dlopen` their backends that way, which
        # names them nowhere in the ELF. auto-patchelf rewrites the runpath to
        # absolute store paths and drops those entries unless asked to keep them.
        autoPatchelfFlags = (old.autoPatchelfFlags or [ ]) ++ [ "--preserve-origin" ];
        autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ ignoreMissingLibs;
      })
    );

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages { python = interpreter; }).overrideScope
      (
        lib.composeManyExtensions (
          [
            pyproject-build-systems.overlays.wheel
            projectOverlay
          ]
          ++ lib.optional pkgs.stdenv.hostPlatform.isElf wheelOverlay
          ++ overlays
        )
      );

  # Pinned by version rather than by name alone, so a lock that forks a package
  # across versions yields the entry the environment actually installs.
  lockedSdist =
    name: version:
    (lib.findFirst (package: package.name == name && package.version == version)
      (throw "mkUvEnv: the lock pins no sdist for ${name} ${version}.")
      (lib.filter (package: package.sdist.url or null != null) uvLock.package)
    ).sdist;

  # Source archive of every package the environment installs, keyed by name.
  # Wheels carry only the importable packages, so auxiliary files such as vLLM's
  # `examples/` are reachable nowhere else. URL and hash both come from the lock,
  # so these stay in step with the environment without a second pin. Each is
  # fetched only if something asks for it, and left packed, so a consumer after
  # one file does not materialise the whole tree.
  sdists = lib.genAttrs (lib.filter (name: pythonSet ? ${name}) lockedNames) (
    name: pkgs.fetchurl { inherit (lockedSdist name pythonSet.${name}.version) url hash; }
  );
in
(pythonSet.mkVirtualEnv name (if deps == { } then workspace.deps.default else deps)).overrideAttrs
  (old: {
    inherit venvIgnoreCollisions;
    passthru = (old.passthru or { }) // {
      inherit sdists;
      python = interpreter;
    };
  })
