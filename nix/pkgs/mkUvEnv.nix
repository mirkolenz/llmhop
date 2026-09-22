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
  # Merged into the corresponding attribute of every wheel. Which libraries a
  # workspace needs follows from what it locks, so there are no defaults: see
  # the README.
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  # Directories appended to every wheel's runpath, for libraries reached by a
  # bare `dlopen("libfoo.so")` from Python, as cffi and ctypes do. Nothing names
  # those in the ELF, so `buildInputs` cannot resolve them.
  runtimePaths ? [ ],
  # Globs of `DT_NEEDED` entries the assembled environment may leave unresolved
  # because the host supplies them at runtime. The default covers the userspace
  # driver of each stack vLLM publishes wheels for, none of which any wheel or
  # nixpkgs package can satisfy at build time. Anything undeclared fails the
  # build, naming the soname and a file that needs it.
  venvIgnoreMissingLibs ? [
    # NVIDIA: the driver, plus the NVML and PTX JIT libraries beside it.
    "libcuda.so*"
    "libnvidia-*.so*"
    # AMD: the ROCm runtime and the thunk it reaches the amdgpu driver through.
    "libhsa-runtime64.so*"
    "libhsakmt.so*"
    "libamdhip64.so*"
    # Intel: the Level Zero and OpenCL loaders in front of the compute runtime.
    "libze_loader.so*"
    "libOpenCL.so*"
  ],
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
        # Deferred unconditionally; `checkMissingLibs` below judges the assembled
        # environment instead.
        autoPatchelfIgnoreMissingDeps = [ "*" ];
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

  # The script explains itself; `writePython3` lints it at build time, so a
  # mistake in it surfaces long before the environment finishes building.
  checkMissingLibs = pkgs.writers.writePython3 "check-missing-libs" { } (
    lib.readFile ./check-missing-libs.py
  );
in
(pythonSet.mkVirtualEnv name (if deps == { } then workspace.deps.default else deps)).overrideAttrs
  (old: {
    inherit venvIgnoreCollisions;
    postFixup = (old.postFixup or "") + ''
      ${checkMissingLibs} "$out" ${lib.escapeShellArgs venvIgnoreMissingLibs}
    '';
    passthru = (old.passthru or { }) // {
      inherit sdists;
      python = interpreter;
    };
  })
