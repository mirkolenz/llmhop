"""Check the ELF files of an environment that `mkUvEnv` assembled.

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

Wheels tagged for any platform skip every ELF fixup, so each one is checked
for host code that would need them. Device code such as cubins is ELF too,
but for another machine, and passes.
"""

import sys
from argparse import ArgumentParser
from collections.abc import Iterable, Iterator
from concurrent.futures import ThreadPoolExecutor
from csv import reader
from fnmatch import fnmatch
from os import environ, stat, walk
from pathlib import Path
from re import sub
from subprocess import run

__all__ = ["main"]

# `e_type` values of code the loader maps: executables and shared objects.
LOADABLE = {2, 3}


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


def machine(path: Path) -> int | None:
    """Return the `e_machine` of a loadable ELF file, or `None` otherwise.

    >>> machine(Path(__file__)) is None
    True
    """
    with path.open("rb") as file:
        header = file.read(20)

    if header[:4] != b"\x7fELF":
        return None

    if int.from_bytes(header[16:18], "little") not in LOADABLE:
        return None

    return int.from_bytes(header[18:20], "little")


def pure_wheels(root: Path) -> Iterator[tuple[str, list[Path]]]:
    """Yield the name and files of each wheel tagged for any platform.

    Every installed wheel records its tags in `WHEEL` and its files in
    `RECORD`, relative to the directory holding its metadata.
    """
    for info in sorted(root.glob("lib/python*/site-packages/*.dist-info")):
        wheel, record = info / "WHEEL", info / "RECORD"

        if not wheel.is_file() or not record.is_file():
            continue

        lines = wheel.read_text().splitlines()
        tags = [line[5:] for line in lines if line.startswith("Tag: ")]

        if not tags or not all(tag.endswith("-any") for tag in tags):
            continue

        with record.open(newline="") as file:
            paths = [info.parent / row[0] for row in reader(file) if row]

        # PEP 503 normalization, as the lock spells the name.
        name = sub(r"[-_.]+", "-", info.name.split("-")[0]).lower()

        yield name, [path for path in paths if path.is_file()]


def host_code(root: Path, exempt: Iterable[str]) -> dict[str, list[Path]]:
    """Map each pure wheel not in `exempt` to the host code it ships.

    >>> host_code(Path("/var/empty"), [])
    {}
    """
    if (host := machine(Path(sys.executable).resolve())) is None:
        return {}

    found = {
        name: [path for path in paths if machine(path) == host]
        for name, paths in pure_wheels(root)
        if name not in exempt
    }

    return {name: paths for name, paths in found.items() if paths}


def main() -> int:
    """Print everything the environment would fail on at runtime."""
    parser = ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--drivers", nargs="*", default=[])
    parser.add_argument("--optional", nargs="*", default=[])
    parser.add_argument("--host-wheels", nargs="*", default=[])
    args = parser.parse_args()
    errors: list[str] = []

    if hosted := host_code(args.root, args.host_wheels):
        errors += [
            f"mkUvEnv: {name} is tagged for any platform but ships {path}"
            for name, paths in hosted.items()
            for path in paths
        ]
        errors.append(
            "mkUvEnv: list those wheels in `hostWheels` "
            "to have them patched like the others."
        )

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
