"""Prune a Hugging Face hub cache to the repositories and revisions it keeps.

Deletes every `models--*` repository that no `keep` argument names,
every ref of a kept one that no kept `<repository>/<revision>` names,
unless none names any of its revisions,
and every snapshot that neither a remaining ref nor a kept revision names.
Then deletes every blob that no remaining snapshot resolves to,
in the repositories and in the shared blob store of `huggingface_hub`.
Only extensionless blobs go, so a concurrent download keeps its partial files.
"""

from argparse import ArgumentParser
from pathlib import Path
from shutil import rmtree

__all__ = ["main"]


def prune_revisions(repo: Path, keep: set[str]) -> None:
    """Delete the refs and snapshots of `repo` that no kept revision names."""
    refs = repo / "refs"
    pinned = any(revision.startswith(f"{repo.name}/") for revision in keep)
    commits: set[str] = set()

    for ref in refs.glob("**/*"):
        if not ref.is_file():
            continue

        if not pinned or f"{repo.name}/{ref.relative_to(refs)}" in keep:
            commits.add(ref.read_text().strip())
        else:
            ref.unlink()

    for snapshot in repo.glob("snapshots/*"):
        if snapshot.name not in commits and f"{repo.name}/{snapshot.name}" not in keep:
            rmtree(snapshot)


def main() -> None:
    """Prune the hub cache given on the command line."""
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("hub", type=Path)
    parser.add_argument("keep", nargs="*")
    args = parser.parse_args()
    hub: Path = args.hub
    keep = set(args.keep)

    for repo in hub.glob("models--*"):
        if repo.name in keep:
            prune_revisions(repo, keep)
        else:
            rmtree(repo)
            rmtree(hub / ".locks" / repo.name, ignore_errors=True)

    used = {
        link.resolve()
        for link in hub.glob("models--*/snapshots/**/*")
        if link.is_symlink()
    }

    for blob in [*hub.glob("models--*/blobs/*"), *hub.glob("blobs/**/*")]:
        if "." in blob.name or not (blob.is_file() or blob.is_symlink()):
            continue

        if blob.resolve() not in used:
            blob.unlink()


if __name__ == "__main__":
    main()
