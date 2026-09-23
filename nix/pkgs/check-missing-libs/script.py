"""Report shared libraries of a built environment that nothing resolves.

A wheel cannot see the siblings it will share an environment with, so half of
what it misses on its own is another wheel. Run over the assembled environment
instead, `ldd` resolves every entry the way the loader will, `$ORIGIN`
included.
Python packages rarely link their siblings through the runpath though:
`torch` preloads the CUDA wheels and `torchcodec` expects `torch` imported,
so the loader finds them by soname among what the process already holds.
`ldd` sees none of that, and `$ORIGIN/..` leaves a symlinked package for its
own store path, so a soname that names some file in the environment counts as
resolved.
"""

import sys
from argparse import ArgumentParser
from collections.abc import Iterable, Iterator
from concurrent.futures import ThreadPoolExecutor
from fnmatch import fnmatch
from os import environ, stat, walk
from pathlib import Path
from subprocess import run

__all__ = ["main"]


def matches(name: str, patterns: Iterable[str]) -> bool:
    """Tell whether `name` matches any of the globs in `patterns`.

    >>> matches("libcuda.so.1", ["libcuda.so*"])
    True
    """
    return any(fnmatch(name, pattern) for pattern in patterns)


def shared_libraries(root: Path) -> Iterator[Path]:
    """Yield every shared library below `root` once, relative to it.

    A virtual environment is assembled from links, so its packages are reached
    through symlinked directories rather than copied into place. Directories
    reached twice, such as through `lib64 -> lib`, are visited once.
    """
    seen: set[tuple[int, int]] = set()

    for directory, dirs, names in walk(root, followlinks=True):
        info = stat(directory)

        if (key := (info.st_dev, info.st_ino)) in seen:
            dirs.clear()
            continue

        seen.add(key)
        # Deterministic, and `lib` before its `lib64` alias.
        dirs.sort()

        for name in names:
            if name.endswith(".so") or ".so." in name:
                yield Path(directory, name).relative_to(root)


def unresolved(library: Path) -> Iterator[str]:
    """Yield the sonames `ldd` cannot resolve for one library.

    `ldd` rejects everything that is not a dynamic ELF, of which an environment
    holds plenty. Those report nothing rather than failing the run.
    """
    result = run(["ldd", library], capture_output=True, text=True, check=False)

    for line in result.stdout.splitlines():
        if line.endswith("=> not found"):
            yield line.split("=>")[0].strip()


def missing(
    root: Path, drivers: Iterable[str], optional: Iterable[str]
) -> dict[str, Path]:
    """Map each unresolved soname below `root` to one library needing it.

    Left out are the sonames the environment ships itself or `drivers` match,
    and whatever the libraries `optional` matches need.

    >>> missing(Path("/var/empty"), [], [])
    {}
    """
    workers = int(environ.get("NIX_BUILD_CORES", "0")) or None
    libraries = list(shared_libraries(root))
    checked = [lib for lib in libraries if not matches(str(lib), optional)]

    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = pool.map(unresolved, (root / lib for lib in checked))
        found = {
            soname: library
            for library, sonames in zip(checked, results)
            for soname in sonames
        }

    provided = {library.name for library in libraries}

    return {
        soname: library
        for soname, library in sorted(found.items())
        if soname not in provided and not matches(soname, drivers)
    }


def main() -> int:
    """Print every unexpected soname with a library needing it."""
    parser = ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--drivers", nargs="*", default=[])
    parser.add_argument("--optional", nargs="*", default=[])
    args = parser.parse_args()
    errors: list[str] = []

    if unexpected := missing(args.root, args.drivers, args.optional):
        errors += [
            f"mkUvEnv: unresolved library {soname}, needed by {library}"
            for soname, library in unexpected.items()
        ]
        errors.append(
            "mkUvEnv: supply these through `buildInputs`, list them in "
            "`venvDriverLibs` if the host provides them, or list the "
            "libraries needing them in `venvOptionalLibs` if those load on "
            "demand only."
        )

    for error in errors:
        print(error, file=sys.stderr)

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
