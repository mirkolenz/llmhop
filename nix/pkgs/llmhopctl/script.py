"""Control the llmhop gateway that the NixOS module set up.

Keys are the credentials `llmhop.api-key.<client>` in the credential stores
of systemd, encrypted ones with `systemd-creds`, which the gateway imports as
clients with `"clientCredentials": true`, unless a declared client has their
name. Each holds a JSON object with its `key`, `policy` and `expiresAt`, and a
rotated one stays in the store holding it. Changes apply through
`try-reload-or-restart`, which reloads a native gateway in place and restarts
a container, whose credentials are those of its start.
"""

import json
import os
import secrets
import sys
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import astuple, dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from subprocess import PIPE, Popen, run
from tempfile import mkstemp
from typing import Annotated, Any, Literal, NoReturn, NotRequired, TypedDict

import typer

__all__ = ["app"]

CONFIG = Path("/etc/llmhop/config.json")
UNIT = "llmhop.service"
PREFIX = "llmhop.api-key."
UNITS = {
    "h": timedelta(hours=1),
    "d": timedelta(days=1),
    "w": timedelta(weeks=1),
}

# The gateway's config.
type Settings = Mapping[str, Any]


def fail(message: str) -> NoReturn:
    """Exit with exit code 1 after printing `message` to stderr."""
    sys.exit(f"llmhopctl: {message}")


def config() -> Settings:
    """Return the gateway's config."""
    return json.loads(CONFIG.read_text())


def root_config() -> Settings:
    """Return the gateway's config, failing unless run as root."""
    if os.geteuid() != 0:
        fail("must be run as root")

    return config()


class Credential(TypedDict):
    """A client credential, the only fields of which llmhop accepts."""

    key: str
    policy: NotRequired[str]
    expiresAt: NotRequired[str]


def parse(value: str) -> Credential:
    """Parse a credential holding a JSON object or a bare key.

    Like llmhop, it trims the line terminators of a bare key.

    >>> parse('{"key": "k", "policy": "guest"}')
    {'key': 'k', 'policy': 'guest'}
    >>> parse("k\\r\\n")
    {'key': 'k'}
    """
    if value.lstrip().startswith("{"):
        return json.loads(value)

    return {"key": value.rstrip("\r\n")}


@dataclass(frozen=True, slots=True)
class Store:
    """A systemd credential store, whose files are encrypted or not."""

    directory: Path
    encrypted: bool = False

    def path(self, name: str) -> Path:
        """Return the path of the credential of the client `name`."""
        return self.directory / (PREFIX + name)

    def read(self, name: str) -> Credential:
        """Read the credential of the client `name`."""
        path = self.path(name)

        if not self.encrypted:
            return parse(path.read_text())

        decrypted = run(
            ["systemd-creds", "decrypt", f"--name={path.name}", path, "-"],
            capture_output=True,
            text=True,
            check=True,
        )

        return parse(decrypted.stdout)

    def write(
        self, name: str, credential: Credential, *, replace: bool
    ) -> None:
        """Write `credential` of the client `name` atomically.

        Raises:
            FileExistsError: If the credential exists and `replace` is unset.
        """
        fd, tmpname = mkstemp(dir=self.directory, prefix=".llmhopctl.")
        os.close(fd)
        tmp = Path(tmpname)
        path = self.path(name)
        value = json.dumps(credential)

        try:
            if self.encrypted:
                run(
                    [
                        "systemd-creds",
                        "encrypt",
                        f"--name={path.name}",
                        "-",
                        tmp,
                    ],
                    input=value,
                    text=True,
                    check=True,
                )
            else:
                tmp.write_text(value)

            # A link, unlike a rename, never replaces an existing file.
            if replace:
                tmp.replace(path)
            else:
                path.hardlink_to(tmp)
        finally:
            tmp.unlink(missing_ok=True)


PLAIN = Store(Path("/etc/credstore"))
STORES = (PLAIN, Store(Path("/etc/credstore.encrypted"), encrypted=True))


def keys(settings: Settings) -> dict[str, tuple[Store, ...]]:
    """Return the stores holding the key of each client by client."""
    declared = settings.get("clients") or {}
    names = {
        path.name.removeprefix(PREFIX)
        for store in STORES
        for path in store.directory.glob(f"{PREFIX}?*")
        if path.is_file()
    }

    return {
        name: tuple(s for s in STORES if s.path(name).is_file())
        for name in sorted(names - declared.keys())
    }


def existing(settings: Settings, name: str) -> tuple[Store, ...]:
    """Return the stores holding the key of the client `name`, or fail."""
    if not (stores := keys(settings).get(name)):
        fail(f"client {name!r} has no key")

    return stores


def duration(value: str) -> timedelta:
    """Parse a positive duration in hours, days or weeks, such as `30d`.

    >>> duration("30d")
    datetime.timedelta(days=30)
    """
    count, unit = value[:-1], value[-1:]

    if not count.isdecimal() or int(count) == 0 or unit not in UNITS:
        raise typer.BadParameter(f"invalid duration {value!r}")

    try:
        return int(count) * UNITS[unit]
    except OverflowError:
        raise typer.BadParameter(f"duration {value!r} is too long") from None


def credential_name(name: str) -> bool:
    """Whether `name` is a credential name llmhop accepts.

    The subset of systemd's that llmhop and its NixOS module share.

    >>> credential_name("llmhop.api-key.alice-1"), credential_name("a+b")
    (True, False)
    """
    return (
        0 < len(name) <= 255
        and name[0] not in ".-"
        and all(c.isascii() and (c.isalnum() or c in "_.-") for c in name)
    )


def apply(output: str = "") -> None:
    """Print `output`, then make the gateway pick up the changed credentials.

    The output comes first, so that a failed reload never loses a stored key.
    """
    if output:
        print(output, flush=True)

    reload = run(["systemctl", "try-reload-or-restart", UNIT], check=False)
    # llmhop reports a failed reload, which systemd lacks, through ERRNO=.
    status = run(
        ["systemctl", "show", "--property=StatusErrno", "--value", UNIT],
        capture_output=True,
        text=True,
        check=False,
    )

    if reload.returncode or status.returncode or status.stdout.strip() != "0":
        fail(
            f"the keys changed, but {UNIT} failed to pick them up,"
            f" see `systemctl status {UNIT}`"
        )


def edit(
    credential: Credential,
    policy: str | None,
    expires: timedelta | None,
    no_expires: bool = False,
) -> Credential:
    """Return `credential` with the changed policy and expiry.

    An empty policy and `no_expires` remove them.

    >>> credential = {"key": "k", "policy": "guest", "expiresAt": "2027"}
    >>> edit(credential, "", None, no_expires=True)
    {'key': 'k'}
    """
    edited = credential.copy()

    if policy is not None:
        edited.pop("policy", None)

    if policy:
        edited["policy"] = policy

    if no_expires:
        edited.pop("expiresAt", None)

    if expires is not None:
        expiry = datetime.now(UTC) + expires
        edited["expiresAt"] = expiry.isoformat(timespec="seconds")

    return edited


def check_policy(settings: Settings, policy: str | None) -> None:
    """Fail unless `policy` is unset, empty or in `settings`."""
    if policy and policy not in (settings.get("policies") or {}):
        fail(f"the gateway has no policy {policy!r}")


def rewrite(
    settings: Settings,
    name: str,
    change: Callable[[Credential], Credential],
    output: str = "",
) -> None:
    """Change the credential of the client `name` in every store holding it.

    Every store is read before any is written.
    """
    changed = {s: change(s.read(name)) for s in existing(settings, name)}

    for store, credential in changed.items():
        store.write(name, credential, replace=True)

    apply(output)


app = typer.Typer(
    no_args_is_help=True,
    add_completion=False,
    pretty_exceptions_show_locals=False,
)
key_app = typer.Typer(
    no_args_is_help=True,
    help="Manage the client keys of clientCredentials.",
)
app.add_typer(key_app, name="key")

Name = Annotated[str, typer.Argument(help="Name of the client.")]
Policy = Annotated[
    str | None, typer.Option(help="Policy of the client, empty for none.")
]
Expires = Annotated[
    timedelta | None,
    typer.Option(parser=duration, help="Validity, such as 30d, 12h or 2w."),
]


@key_app.command("list")
def key_list() -> None:
    """Print every client with a key and its fields but the key."""
    for name, stores in keys(root_config()).items():
        fields = {k: v for k, v in stores[0].read(name).items() if k != "key"}
        print(name, json.dumps(fields, separators=(",", ":")), sep="\t")


@key_app.command("create")
def key_create(
    name: Name, policy: Policy = None, expires: Expires = None
) -> None:
    """Create a key for the client `name` and print it."""
    settings = root_config()

    if settings.get("clientCredentials") is not True:
        fail("the gateway does not import clientCredentials")

    if name in (settings.get("clients") or {}):
        fail(f"client {name!r} is declared in the config")

    if not name or not credential_name(PREFIX + name):
        fail(f"client {name!r} is no valid credential name")

    if name in keys(settings):
        fail(f"client {name!r} already has a key")

    check_policy(settings, policy)
    credential = edit({"key": secrets.token_hex(32)}, policy, expires)
    PLAIN.directory.mkdir(mode=0o700, exist_ok=True)

    try:
        PLAIN.write(name, credential, replace=False)
    except FileExistsError:
        fail(f"client {name!r} already has a key")

    apply(credential["key"])


@key_app.command("update")
def key_update(
    name: Name,
    policy: Policy = None,
    expires: Expires = None,
    no_expires: Annotated[
        bool, typer.Option("--no-expires", help="Remove the expiry.")
    ] = False,
) -> None:
    """Change the policy or expiry of the client `name`, keeping its key."""
    settings = root_config()
    check_policy(settings, policy)
    rewrite(settings, name, lambda c: edit(c, policy, expires, no_expires))


@key_app.command("rotate")
def key_rotate(name: Name) -> None:
    """Replace the key of the client `name`, keeping its metadata."""
    new = secrets.token_hex(32)
    rewrite(root_config(), name, lambda c: c | {"key": new}, new)


@key_app.command("revoke")
def key_revoke(name: Name) -> None:
    """Delete the key of the client `name`."""
    for store in existing(root_config(), name):
        store.path(name).unlink()

    apply()


if __name__ == "__main__":
    app()
