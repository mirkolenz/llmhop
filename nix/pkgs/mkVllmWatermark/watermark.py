# Adapted from https://github.com/vllm-project/vllm/blob/main/examples/basic/online_serving/watermark_detection_server.py
"""vLLM watermarking with keys read from files.

`serve` runs `vllm serve` and `detect` a server detecting its watermarks.
Both take the `WatermarkConfig` of `vllm serve` without its `key`,
which a key file supplies instead,
so no key ever appears on a command line.
"""

import argparse
import dataclasses
import inspect
import json
import sys
from collections.abc import Callable, Container, Mapping, Sequence
from pathlib import Path
from typing import Any, get_args

import uvicorn
import vllm.v1.watermarking
from fastapi import FastAPI
from pydantic import BaseModel, TypeAdapter, ValidationError
from vllm.config.watermarking import WatermarkConfig, WatermarkingAlgorithm
from vllm.tokenizers import TokenizerLike, get_tokenizer
from vllm.v1.watermarking import WatermarkDetection, WatermarkDetector

# Concrete detectors keyed like `WatermarkConfig.algorithm` without underscores,
# e.g. `dualkeygumbel` for `DualKeyGumbelWatermarkDetector`.
DETECTORS: dict[str, type[WatermarkDetector]] = {
    name.removesuffix("WatermarkDetector").lower(): cls
    for name in vllm.v1.watermarking.__all__
    if isinstance(cls := getattr(vllm.v1.watermarking, name), type)
    and issubclass(cls, WatermarkDetector)
    and not inspect.isabstract(cls)
}

# Detector parameters without a generation-side counterpart.
# The config's `deduplicate_contexts` shares a name but governs generation only,
# detection keeps its own default as vLLM recommends.
DETECTION_ONLY = frozenset({"p_value_threshold", "deduplicate_contexts"})


class DetectionRequest(BaseModel):
    """Candidate text, extra keys are ignored."""

    text: str


class Profile(BaseModel):
    """Tokenizer and watermark of one generation configuration."""

    tokenizer: str
    revision: str | None = None
    key_file: Path
    config: dict[str, Any] = {}


@dataclasses.dataclass(frozen=True, slots=True)
class Detection(WatermarkDetection):
    """Detection of the most significant profile, named by `profile`."""

    profile: str


# A tokenizer and the detectors of the profiles sharing it, keyed by name.
Group = tuple[TokenizerLike, dict[str, WatermarkDetector]]


def read_key(path: Path) -> int:
    """Watermark key of a file holding only the integer, errors omitting it."""
    text = path.read_text().strip()

    if not (text.isascii() and text.isdigit()):
        raise ValueError(
            f"{path} must hold only the watermark key, an unsigned integer"
        )

    return int(text)


def load_config(config: Mapping[str, Any], key_file: Path) -> WatermarkConfig:
    """`config` completed with the key of `key_file` and validated by vLLM.

    Errors omit the input, since it holds the key.
    """
    if "key" in config:
        raise ValueError("pass the watermark key as a file")

    try:
        return TypeAdapter(WatermarkConfig).validate_python(
            {**config, "key": read_key(key_file)}
        )
    except ValidationError as error:
        messages = (
            f"{'.'.join(map(str, details['loc'])) or 'config'}: {details['msg']}"
            for details in error.errors(include_input=False)
        )
        raise ValueError(f"invalid watermark config: {', '.join(messages)}") from None


def config_field(fields: Container[str], algorithm: str, parameter: str) -> str:
    """Config field feeding a detector parameter, preferring `<algorithm>_<name>`.

    >>> config_field({"key", "sbw_gamma"}, "sbw", "gamma")
    'sbw_gamma'
    >>> config_field({"key"}, "sbw", "key")
    'key'
    """
    for field in (f"{algorithm}_{parameter}", parameter):
        if field in fields:
            return field

    raise ValueError(
        f"no WatermarkConfig field provides {parameter!r} for {algorithm!r}"
    )


def create_detector(
    config: WatermarkConfig, p_value_threshold: float
) -> WatermarkDetector:
    """Detector matching the generation side of `config`.

    The class is the exported detector named after `config.algorithm`,
    and each of its parameters takes the config field `config_field` names.
    A parameter without one raises instead of keeping its default,
    since a detector disagreeing with generation fails silently.
    """
    cls = DETECTORS.get(config.algorithm.replace("_", ""))

    if cls is None:
        raise ValueError(
            f"vLLM has no detector for watermarking algorithm {config.algorithm!r}"
        )

    fields = {field.name for field in dataclasses.fields(config)}
    parameters = inspect.signature(cls).parameters.keys() - DETECTION_ONLY
    return cls(
        p_value_threshold=p_value_threshold,
        **{
            name: getattr(config, config_field(fields, config.algorithm, name))
            for name in parameters
        },
    )


def check() -> None:
    """Build and run a detector for every algorithm vLLM declares."""
    for algorithm in get_args(WatermarkingAlgorithm):
        config = WatermarkConfig(key=0, algorithm=algorithm)
        create_detector(config, 0.01).detect(list(range(16)))


def create_groups(
    profiles: Mapping[str, Profile], p_value_threshold: float
) -> list[Group]:
    """Detectors of `profiles` grouped by tokenizer, each loaded once."""
    groups: dict[tuple[str, str | None], dict[str, WatermarkDetector]] = {}

    for name, profile in profiles.items():
        try:
            config = load_config(profile.config, profile.key_file)
        except ValueError as error:
            error.add_note(f"in profile {name!r}")
            raise

        groups.setdefault((profile.tokenizer, profile.revision), {})[name] = (
            create_detector(config, p_value_threshold)
        )

    return [
        (get_tokenizer(tokenizer, revision=revision), detectors)
        for (tokenizer, revision), detectors in groups.items()
    ]


def create_app(groups: Sequence[Group], p_value_threshold: float) -> FastAPI:
    """Serve `GET /health` and `POST /detect`.

    The text is encoded once per tokenizer and tested against every profile.
    The response is that of the lowest p-value,
    Bonferroni-corrected for the number of profiles as vLLM recommends.
    """
    app = FastAPI()

    @app.get("/health")
    def health() -> None:
        pass

    @app.post("/detect")
    def detect(request: DetectionRequest) -> Detection:
        results: dict[str, WatermarkDetection] = {}

        for tokenizer, detectors in groups:
            token_ids = tokenizer.encode(request.text, add_special_tokens=False)
            results |= {
                name: detector.detect(token_ids) for name, detector in detectors.items()
            }

        profile = min(results, key=lambda name: results[name].p_value)
        best = results[profile]
        p_value = min(1.0, best.p_value * len(results))
        return Detection(
            score=best.score,
            p_value=p_value,
            num_scored_tokens=best.num_scored_tokens,
            is_watermarked=p_value <= p_value_threshold,
            profile=profile,
        )

    return app


def serve(argv: Sequence[str]) -> None:
    """Run `vllm serve` with the key merged into `--watermark-config` in-process.

    vLLM redacts `watermark_config` in its logs,
    and hands it to its engine processes through multiprocessing.
    """
    parser = argparse.ArgumentParser(
        prog="watermark.py serve", add_help=False, allow_abbrev=False
    )
    parser.add_argument("--watermark-config", type=json.loads, default={})
    parser.add_argument("--watermark-key-file", type=Path, required=True)
    args, rest = parser.parse_known_args(argv)
    config = load_config(args.watermark_config, args.watermark_key_file)

    from vllm.entrypoints.cli.main import main

    sys.argv = [
        "vllm",
        "serve",
        *rest,
        "--watermark-config",
        json.dumps(dataclasses.asdict(config)),
    ]
    main()


def detect(argv: Sequence[str]) -> None:
    """Serve detection for the watermarks of `vllm serve`."""
    parser = argparse.ArgumentParser(prog="watermark.py detect", allow_abbrev=False)
    parser.add_argument(
        "--profiles",
        type=json.loads,
        required=True,
        help="JSON object of the profiles to test, keyed by name, each with "
        "`tokenizer`, `revision`, `key_file` and the keyless `config`.",
    )
    parser.add_argument("--p-value-threshold", type=float, default=0.01)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--uds", help="Unix socket to bind instead of a port.")
    args = parser.parse_args(argv)

    profiles = TypeAdapter(dict[str, Profile]).validate_python(args.profiles)

    if not profiles:
        parser.error("--profiles must hold at least one profile")

    app = create_app(
        create_groups(profiles, args.p_value_threshold), args.p_value_threshold
    )
    uvicorn.run(app, host=args.host, port=args.port, uds=args.uds)


COMMANDS: dict[str, Callable[[Sequence[str]], None]] = {
    "serve": serve,
    "detect": detect,
}


def main() -> None:
    command, *argv = sys.argv[1:] or [""]

    if command not in COMMANDS:
        raise SystemExit(f"usage: {sys.argv[0]} {{{','.join(COMMANDS)}}} ...")

    COMMANDS[command](argv)


if __name__ == "__main__":
    main()
