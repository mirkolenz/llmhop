"""Prune, record and validate the hub cache of one worker.

The specification is a JSON object with the `hub` and its `repositories`,
each with its cache `name` and the `revision` it caches, or null for every
ref. The last complete download is recorded in the `completed` file in the
state directory of the fetcher.
"""

import hashlib
import json
import subprocess
import sys
from argparse import ArgumentParser, Namespace
from pathlib import Path
from shutil import rmtree
from typing import TypedDict

__all__ = ["main"]

SYSTEMCTL = "@systemctl@"


class Repository(TypedDict):
    """A repository of the specification."""

    name: str
    revision: str | None


class Specification(TypedDict):
    """The hub cache of a worker and the repositories it caches."""

    hub: str
    repositories: list[Repository]


class Download(TypedDict):
    """The record of a complete download."""

    specification: Specification
    fingerprint: str
    refs: dict[str, str]


def refs_of(repo: Path, revision: str | None) -> list[Path]:
    """Return the refs naming `revision` in `repo`, or every ref without one."""
    refs = repo / "refs"

    if revision is None:
        return sorted(ref for ref in refs.rglob("*") if ref.is_file())

    ref = refs / revision
    return [ref] if ref.is_file() else []


def resolve(repo: Path, revision: str | None) -> dict[Path, str]:
    """Return the refs of `revision` in `repo` with their commits."""
    return {ref: ref.read_text().strip() for ref in refs_of(repo, revision)}


def commits_of(revision: str | None, refs: dict[Path, str]) -> set[str]:
    """Return the commits of `revision`, which names a commit if no ref does."""
    if revision is not None and not refs:
        return {revision}

    return set(refs.values())


def prune(specification: Specification) -> None:
    """Delete everything in the hub cache that the specification does not reference."""
    hub = Path(specification["hub"])
    revisions: dict[str, set[str | None]] = {}

    for repository in specification["repositories"]:
        revisions.setdefault(repository["name"], set()).add(repository["revision"])

    for repo in hub.glob("models--*"):
        if repo.name not in revisions:
            rmtree(repo)
            rmtree(hub / ".locks" / repo.name, ignore_errors=True)
            continue

        kept: dict[Path, str] = {}
        commits: set[str] = set()

        for revision in revisions[repo.name]:
            refs = resolve(repo, revision)
            kept |= refs
            commits |= commits_of(revision, refs)

        for ref in refs_of(repo, None):
            if ref not in kept:
                ref.unlink()

        for snapshot in repo.glob("snapshots/*"):
            if snapshot.name not in commits:
                rmtree(snapshot)

    used = {
        link.resolve()
        for link in hub.glob("models--*/snapshots/**/*")
        if link.is_symlink()
    }

    # Recent `huggingface_hub` releases also keep a shared blob store.
    for blob in [*hub.glob("models--*/blobs/*"), *hub.glob("blobs/**/*")]:
        if (blob.is_file() or blob.is_symlink()) and blob.resolve() not in used:
            blob.unlink()


def record(specification: Specification) -> Download:
    """Record the refs of the specification and fingerprint the files they name."""
    hub = Path(specification["hub"])
    refs: dict[str, str] = {}
    files: list[tuple[str, str, int]] = []

    for repository in specification["repositories"]:
        repo = hub / repository["name"]
        resolved = resolve(repo, repository["revision"])

        if repository["revision"] is None and not resolved:
            raise FileNotFoundError(f"no cached refs in {repo}")

        refs |= {str(ref): commit for ref, commit in resolved.items()}

        for commit in sorted(commits_of(repository["revision"], resolved)):
            snapshot = repo / "snapshots" / commit
            paths = sorted(path for path in snapshot.rglob("*") if not path.is_dir())

            if not paths:
                raise FileNotFoundError(f"no cached files in {snapshot}")

            files.extend(
                (
                    str(path),
                    str(path.readlink()) if path.is_symlink() else "",
                    path.stat().st_size,
                )
                for path in paths
            )

    content = json.dumps((specification, refs, files), sort_keys=True)
    return {
        "specification": specification,
        "fingerprint": hashlib.sha256(content.encode()).hexdigest(),
        "refs": refs,
    }


def read(completed: Path) -> Download | None:
    """Return the recorded download, if any."""
    return json.loads(completed.read_text()) if completed.exists() else None


def systemctl(*args: str) -> int:
    """Run `systemctl` and return its exit code."""
    return subprocess.run([SYSTEMCTL, *args], check=False).returncode


def prune_command(args: Namespace) -> None:
    """Delete everything in the hub cache that the specification does not reference."""
    prune(args.specification)


def restore_command(args: Namespace) -> None:
    """Point the refs back to the last complete download of the specification."""
    recorded = read(args.completed)

    if recorded is None or recorded["specification"] != args.specification:
        return

    hub = Path(args.specification["hub"])

    for repository in args.specification["repositories"]:
        for ref in refs_of(hub / repository["name"], repository["revision"]):
            if str(ref) not in recorded["refs"]:
                ref.unlink()

    for ref, commit in recorded["refs"].items():
        Path(ref).write_text(commit)


def load_command(args: Namespace) -> None:
    """Fail unless the cache matches the last complete download."""
    recorded = read(args.completed)

    try:
        current = record(args.specification)
    except FileNotFoundError as error:
        sys.exit(f"cache does not match a completed download: {error}")

    if recorded is None or recorded["fingerprint"] != current["fingerprint"]:
        sys.exit("cache does not match a completed download")


def apply_command(args: Namespace) -> None:
    """Record a complete download and restart or start the server."""
    completed: Path = args.completed
    previous = read(completed)
    current = record(args.specification)
    temporary = completed.with_suffix(".tmp")
    temporary.write_text(json.dumps(current))
    # Readable by the fetcher's own `restore`, but writable by root only.
    temporary.chmod(0o644)
    temporary.replace(completed)

    if systemctl("is-failed", "--quiet", args.server) == 0:
        action = "start"
    elif previous is None or previous["fingerprint"] != current["fingerprint"]:
        # Leaves a stopped server alone.
        action = "try-restart"
    else:
        return

    # A planned restart does not count towards the start limit.
    systemctl("reset-failed", args.server)

    if systemctl(action, "--no-block", args.server) != 0:
        sys.exit(f"could not {action} {args.server}")


def main() -> None:
    """Run the command given on the command line."""
    parser = ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(required=True)

    for name, command, arguments in [
        ("prune", prune_command, []),
        ("restore", restore_command, [("completed", Path)]),
        ("load", load_command, [("completed", Path)]),
        ("apply", apply_command, [("server", str), ("completed", Path)]),
    ]:
        subparser = commands.add_parser(name, help=command.__doc__)
        subparser.set_defaults(command=command)

        for argument, kind in arguments:
            subparser.add_argument(argument, type=kind)

        subparser.add_argument("specification", type=json.loads)

    args = parser.parse_args()
    args.command(args)


if __name__ == "__main__":
    main()
