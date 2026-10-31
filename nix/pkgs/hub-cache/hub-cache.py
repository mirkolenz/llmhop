"""Prune, record, restore and validate the hub cache of one worker.

Usage: hub-cache.py prune | restore <completed> | load <completed>
| apply <server> <completed>, followed by the specification.

The specification is a JSON object with the `hub` and its `repositories`,
each with its cache `name` and the `revision` it caches, or null for every
ref. The last complete download is recorded in the `completed` file in the
state directory of the fetcher.
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from shutil import rmtree
from typing import TypedDict

__all__ = ["main"]


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


def resolve(repo: Path, revision: str | None) -> tuple[dict[Path, str], set[str]]:
    """Return the refs naming `revision` in `repo`, or every ref without one,
    with their commits, and the commits of `revision`, which names a commit
    if no ref does."""
    if revision is None:
        paths = sorted(ref for ref in (repo / "refs").rglob("*") if ref.is_file())
    else:
        ref = repo / "refs" / revision
        paths = [ref] if ref.is_file() else []

    refs = {ref: ref.read_text().strip() for ref in paths}

    if revision is not None and not refs:
        return refs, {revision}

    return refs, set(refs.values())


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

        kept: set[Path] = set()
        commits: set[str] = set()

        for revision in revisions[repo.name]:
            refs, revision_commits = resolve(repo, revision)
            kept |= refs.keys()
            commits |= revision_commits

        for ref in resolve(repo, None)[0]:
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
        resolved, commits = resolve(repo, repository["revision"])

        if repository["revision"] is None and not resolved:
            raise FileNotFoundError(f"no cached refs in {repo}")

        refs |= {str(ref): commit for ref, commit in resolved.items()}

        for commit in sorted(commits):
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


def restore(specification: Specification, completed: Path) -> None:
    """Point the refs back to the last complete download of the specification."""
    recorded = read(completed)

    if recorded is None or recorded["specification"] != specification:
        return

    hub = Path(specification["hub"])

    for repository in specification["repositories"]:
        for ref in resolve(hub / repository["name"], repository["revision"])[0]:
            if str(ref) not in recorded["refs"]:
                ref.unlink()

    for ref, commit in recorded["refs"].items():
        Path(ref).write_text(commit)


def load(specification: Specification, completed: Path) -> None:
    """Fail unless the cache matches the last complete download."""
    recorded = read(completed)

    try:
        current = record(specification)
    except FileNotFoundError as error:
        sys.exit(f"cache does not match a completed download: {error}")

    if recorded is None or recorded["fingerprint"] != current["fingerprint"]:
        sys.exit("cache does not match a completed download")


def apply(specification: Specification, server: str, completed: Path) -> None:
    """Record a complete download and restart or start the server."""
    previous = read(completed)
    current = record(specification)
    temporary = completed.with_suffix(".tmp")
    temporary.write_text(json.dumps(current))
    # Readable by the fetcher's own `restore`, but writable by root only.
    temporary.chmod(0o644)
    temporary.replace(completed)

    def systemctl(*args: str) -> int:
        return subprocess.run(["systemctl", *args, server], check=False).returncode

    if systemctl("is-failed", "--quiet") == 0:
        action = "start"
    elif previous is None or previous["fingerprint"] != current["fingerprint"]:
        # Leaves a stopped server alone.
        action = "try-restart"
    else:
        return

    # A planned restart does not count towards the start limit.
    systemctl("reset-failed")

    if systemctl(action, "--no-block") != 0:
        sys.exit(f"could not {action} {server}")


def main() -> None:
    """Run the command given on the command line."""
    match sys.argv[1:]:
        case ["prune", specification]:
            prune(json.loads(specification))
        case ["restore", completed, specification]:
            restore(json.loads(specification), Path(completed))
        case ["load", completed, specification]:
            load(json.loads(specification), Path(completed))
        case ["apply", server, completed, specification]:
            apply(json.loads(specification), server, Path(completed))
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
