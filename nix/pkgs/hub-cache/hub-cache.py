"""Prune the hub cache of one worker, or restart its server.

Usage: hub-cache.py prune <specification> | restart <server>

The specification is a JSON object with the `hub` and its `repositories`,
each with its cache `name` and the `revision` it caches, or null for every
ref. Neither command keeps any state. `prune` runs as the owner of the hub
cache, never with more privileges, since the fetcher controls everything in
it, while `restart` reads no file.
"""

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


def refs(repo: Path) -> dict[Path, str]:
    """Return every ref of `repo` with its commit."""
    return {
        ref: ref.read_text().strip()
        for ref in (repo / "refs").rglob("*")
        if ref.is_file()
    }


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

        wanted = revisions[repo.name]
        # A revision without a ref names a commit.
        commits = {revision for revision in wanted if revision is not None}

        for ref, commit in refs(repo).items():
            name = str(ref.relative_to(repo / "refs"))

            if None in wanted or name in wanted:
                commits.add(commit)
            else:
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


def restart(server: str) -> None:
    """Restart the server after its download changed, or start it if it failed."""

    def systemctl(*args: str) -> int:
        return subprocess.run(["systemctl", *args, server], check=False).returncode

    # Leaves a stopped server alone.
    action = "start" if systemctl("is-failed", "--quiet") == 0 else "try-restart"
    # A planned restart does not count towards the start limit.
    systemctl("reset-failed")

    if systemctl(action, "--no-block") != 0:
        sys.exit(f"could not {action} {server}")


def main() -> None:
    """Run the command given on the command line."""
    match sys.argv[1:]:
        case ["prune", specification]:
            prune(json.loads(specification))
        case ["restart", server]:
            restart(server)
        case _:
            sys.exit(__doc__)


if __name__ == "__main__":
    main()
