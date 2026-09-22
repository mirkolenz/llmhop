"""Report shared libraries of a built environment that nothing resolves.

A wheel cannot see the siblings it will share a virtual environment with, so
half of what it misses on its own is another wheel. Run over the assembled
environment instead, `ldd` resolves every entry the way the loader will,
`$ORIGIN` included, and what it still calls missing is what the unit would fail
on at import time.
"""

import sys
from collections.abc import Iterable, Iterator
from concurrent.futures import ThreadPoolExecutor
from fnmatch import fnmatch
from os import cpu_count, environ, walk
from pathlib import Path
from subprocess import run

__all__ = ["main"]


def shared_libraries(root: Path) -> Iterator[Path]:
    """Yield every shared library below `root`, descending into symlinks.

    A virtual environment is assembled from links, so its packages are reached
    through symlinked directories rather than copied into place.
    """
    for directory, _, names in walk(root, followlinks=True):
        for name in names:
            if ".so" in name:
                yield Path(directory) / name


def unresolved(library: Path) -> Iterator[str]:
    """Yield the sonames `ldd` cannot resolve for one library.

    `ldd` rejects everything that is not a dynamic ELF, of which an environment
    holds plenty; those report nothing rather than failing the run.
    """
    result = run(["ldd", library], capture_output=True, text=True, check=False)

    for line in result.stdout.splitlines():
        if line.endswith("=> not found"):
            yield line.split("=>")[0].strip()


def missing(root: Path, allowed: Iterable[str]) -> dict[str, Path]:
    """Map each unresolved soname below `root` to one library needing it.

    Sonames matching a glob in `allowed` are left out:
    the host supplies them at runtime and no build can resolve them.

    >>> missing(Path("/var/empty"), [])
    {}
    """
    workers = int(environ.get("NIX_BUILD_CORES", "0")) or cpu_count()

    with ThreadPoolExecutor(max_workers=workers) as pool:
        libraries = list(shared_libraries(root))
        results = pool.map(unresolved, libraries)
        found = {
            soname: library
            for library, sonames in zip(libraries, results)
            for soname in sonames
        }

    return {
        soname: library
        for soname, library in sorted(found.items())
        if not any(fnmatch(soname, pattern) for pattern in allowed)
    }


def main() -> int:
    """Print every unexpected soname with a library needing it."""
    root, allowed = Path(sys.argv[1]), sys.argv[2:]
    unexpected = missing(root, allowed)

    for soname, library in unexpected.items():
        print(
            f"mkUvEnv: unresolved library {soname}, needed by {library}",
            file=sys.stderr,
        )

    if unexpected:
        print(
            "mkUvEnv: supply these through `buildInputs`, or list them in "
            "`venvIgnoreMissingLibs` if the host provides them at runtime.",
            file=sys.stderr,
        )

    return 1 if unexpected else 0


if __name__ == "__main__":
    sys.exit(main())
