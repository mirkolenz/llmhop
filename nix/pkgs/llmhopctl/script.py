"""Control the llmhop gateway that the NixOS module set up.

Tokens are the credentials that `authTokenCredentials` of the gateway's
config imports, in the credential stores of systemd, encrypted ones with
`systemd-creds`, and a rotated one stays in the store holding it.
Changes apply through `try-reload-or-restart`, which reloads a native gateway
in place and restarts a container, whose credentials are those of its start.
"""

import json
import os
import secrets
import sys
from argparse import ArgumentParser, ArgumentTypeError
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from string import ascii_letters, digits
from subprocess import run
from tempfile import mkstemp
from typing import NoReturn

__all__ = ["main"]

CONFIG = Path("/etc/llmhop/config.json")
# Names reach backends in the `X-Llmhop-Client` header.
NAME_CHARS = frozenset(ascii_letters + digits + "_.-")


def fail(message: str) -> NoReturn:
    """Exit with exit code 1 after printing `message` to stderr."""
    sys.exit(f"llmhopctl: {message}")


@dataclass(frozen=True, slots=True)
class Store:
    """A systemd credential store, whose files are encrypted or not."""

    directory: Path
    encrypted: bool = False

    def path(self, filename: str) -> Path:
        """Return the path of the credential `filename`."""
        return self.directory / filename

    def write(self, filename: str, token: str, *, replace: bool) -> None:
        """Write `token` to the credential `filename` atomically.

        Raises:
            FileExistsError: If the credential exists and `replace` is unset.
        """
        fd, name = mkstemp(dir=self.directory, prefix=".llmhopctl.")
        os.close(fd)
        tmp = Path(name)
        path = self.path(filename)

        try:
            if self.encrypted:
                run(
                    [
                        "systemd-creds",
                        "encrypt",
                        f"--name={filename}",
                        "-",
                        tmp,
                    ],
                    input=token,
                    text=True,
                    check=True,
                )
            else:
                tmp.write_text(token)

            # A link, unlike a rename, never replaces an existing file.
            if replace:
                tmp.replace(path)
            else:
                path.hardlink_to(tmp)
        finally:
            tmp.unlink(missing_ok=True)


PLAIN = Store(Path("/etc/credstore"))
ENCRYPTED = Store(Path("/etc/credstore.encrypted"), encrypted=True)
STORES = (PLAIN, ENCRYPTED)


@dataclass(frozen=True, slots=True)
class Config:
    """The token settings of the gateway's config.

    Attributes:
        glob: The `authTokenCredentials` glob, whose only `*` ends it, as
            `llmhop check` ensured when the config was built.
        reserved: The clients that `authTokens` sets.
    """

    glob: str
    reserved: frozenset[str]

    @classmethod
    def load(cls, path: Path) -> Config:
        """Read the token settings of the gateway's config at `path`."""
        settings = json.loads(path.read_text())

        if not (glob := settings.get("authTokenCredentials")):
            fail("the gateway sets no authTokenCredentials")

        return cls(glob, frozenset(settings.get("authTokens") or {}))

    @property
    def prefix(self) -> str:
        """The part of the glob before its wildcard."""
        return self.glob.partition("*")[0]

    def filename(self, name: str) -> str:
        """Return the credential filename of the token `name`.

        >>> Config("llmhop.token.*", frozenset()).filename("x")
        'llmhop.token.x'
        """
        return self.prefix + name

    def holders(self, name: str) -> tuple[Store, ...]:
        """Return the stores that hold the token `name`."""
        filename = self.filename(name)

        return tuple(
            store for store in STORES if store.path(filename).is_file()
        )


def token_name(value: str) -> str:
    """Check a token name given on the command line.

    >>> token_name("hivegent")
    'hivegent'
    """
    if not value or not NAME_CHARS.issuperset(value):
        raise ArgumentTypeError(f"invalid token name {value!r}")

    return value


def existing(config: Config, name: str) -> tuple[Store, ...]:
    """Return the stores holding the token `name`, failing if none does."""
    if not (stores := config.holders(name)):
        fail(f"token {name!r} does not exist")

    return stores


def apply() -> None:
    """Make the gateway pick up the changed credentials if it runs."""
    unit = "llmhop.service"

    reload = run(["systemctl", "try-reload-or-restart", unit], check=False)
    # llmhop reports a failed reload, which systemd lacks, through ERRNO=.
    status = run(
        ["systemctl", "show", "--property=StatusErrno", "--value", unit],
        capture_output=True,
        text=True,
        check=False,
    )

    if reload.returncode or status.returncode or status.stdout.strip() != "0":
        fail(
            f"the tokens changed, but {unit} failed to pick them up,"
            f" see `systemctl status {unit}`"
        )


def token_list(config: Config, _: str) -> None:
    """Print the names of all tokens."""
    skip = len(config.prefix)
    names = {
        path.name[skip:]
        for store in STORES
        for path in store.directory.glob(config.glob)
        if path.is_file()
    }

    for name in sorted(names):
        print(name)


def token_create(config: Config, name: str) -> None:
    """Create the token `name` and print it."""
    if name in config.reserved:
        fail(f"token {name!r} is already set in authTokens")

    if config.holders(name):
        fail(f"token {name!r} already exists")

    PLAIN.directory.mkdir(mode=0o700, exist_ok=True)
    token = secrets.token_hex(32)

    try:
        PLAIN.write(config.filename(name), token, replace=False)
    except FileExistsError:
        fail(f"token {name!r} already exists")

    # Printed first, so that a failed reload never loses the stored token.
    print(token, flush=True)
    apply()


def token_rotate(config: Config, name: str) -> None:
    """Replace the token `name` and print the new one."""
    token = secrets.token_hex(32)
    filename = config.filename(name)

    for store in existing(config, name):
        store.write(filename, token, replace=True)

    print(token, flush=True)
    apply()


def token_revoke(config: Config, name: str) -> None:
    """Delete the token `name`."""
    filename = config.filename(name)

    for store in existing(config, name):
        store.path(filename).unlink()

    apply()


TOKEN_COMMANDS: tuple[tuple[str, Callable[[Config, str], None]], ...] = (
    ("create", token_create),
    ("rotate", token_rotate),
    ("revoke", token_revoke),
)


def main() -> None:
    """Run the command given on the command line."""
    parser = ArgumentParser(prog="llmhopctl", allow_abbrev=False)
    commands = parser.add_subparsers(
        dest="command", required=True, metavar="COMMAND"
    )
    token = commands.add_parser(
        "token",
        help="manage the client tokens of authTokenCredentials",
        description="Manage the client tokens of authTokenCredentials.",
        allow_abbrev=False,
    )
    actions = token.add_subparsers(
        dest="action", required=True, metavar="ACTION"
    )
    actions.add_parser(
        "list", help=token_list.__doc__, allow_abbrev=False
    ).set_defaults(run=token_list, name="")

    for action, command in TOKEN_COMMANDS:
        subparser = actions.add_parser(
            action, help=command.__doc__, allow_abbrev=False
        )
        subparser.add_argument("name", type=token_name)
        subparser.set_defaults(run=command)

    args = parser.parse_args()

    if os.geteuid() != 0:
        fail("must be run as root")

    args.run(Config.load(CONFIG), args.name)


if __name__ == "__main__":
    main()
