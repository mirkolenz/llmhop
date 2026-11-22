# Detection adapted from https://github.com/vllm-project/vllm/blob/main/examples/basic/online_serving/watermark_detection_server.py
"""Watermarking of vLLM and SGLang with keys read from files.

`serve` runs `sglang serve` with the keys merged into its config file,
while vLLM reads its key file itself.
`detect` serves the detection of the watermarks of either engine.
Every key file holds an unsigned 64-bit integer,
so no key ever appears on a command line.
"""

import argparse
import dataclasses
import inspect
import json
import os
import sys
import tempfile
from collections.abc import Callable, Container, Mapping, Sequence
from pathlib import Path
from typing import Any, Literal, Protocol, get_args

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel, TypeAdapter

# SGLang still supports Python 3.11, which lacks `type` statements.
Engine = Literal["vllm", "sglang"]

# vLLM detector parameters without a generation-side counterpart.
# The config's `deduplicate_contexts` shares a name but governs generation only,
# detection keeps its own default as vLLM recommends.
VLLM_DETECTION_ONLY = frozenset({"p_value_threshold", "deduplicate_contexts"})


class Tokenizer(Protocol):
    """Encoder of candidate text."""

    def encode(self, text: str, *, add_special_tokens: bool) -> list[int]: ...


class Score(BaseModel, frozen=True):
    """Significance of the watermark in a token sequence."""

    score: float
    p_value: float
    num_scored_tokens: int


Detector = Callable[[list[int]], Score]


class DetectionRequest(BaseModel):
    """Candidate text, extra keys are ignored."""

    text: str


class Profile(BaseModel):
    """Tokenizer and watermark of one generation configuration."""

    tokenizer: str
    revision: str | None = None
    key_file: Path
    key_b_file: Path | None = None
    config: dict[str, Any] = {}


class Detection(Score, frozen=True):
    """Detection of the most significant profile, named by `profile`."""

    is_watermarked: bool
    profile: str


# A tokenizer and the detectors of the profiles sharing it, keyed by name.
Group = tuple[Tokenizer, dict[str, Detector]]


def read_key(path: Path) -> int:
    """Watermark key of a file holding only the integer, errors omitting it."""
    text = path.read_text().strip()

    if not (text.isascii() and text.isdigit() and int(text) < 1 << 64):
        raise ValueError(
            f"{path} must hold only the watermark key, an unsigned 64-bit integer"
        )

    return int(text)


def sglang_config(
    config: Mapping[str, Any], key_file: Path, key_b_file: Path | None
) -> dict[str, Any]:
    """SGLang's watermark config, `config` with the hex keys of the files.

    It is validated by SGLang, whose errors omit the keys.
    """
    from sglang.srt.sampling.watermarking.config import load_watermark_config

    keys = {"key": key_file} | ({"key_b": key_b_file} if key_b_file else {})
    merged = {**config} | {name: f"{read_key(path):x}" for name, path in keys.items()}
    load_watermark_config(json.dumps(merged))
    return merged


def vllm_detector(
    config: Mapping[str, Any], key: int, p_value_threshold: float
) -> Detector:
    """Detector matching the generation side of vLLM's `config`.

    The class is the exported detector named after the algorithm,
    and each of its parameters takes the config field `config_field` names.
    A parameter without one raises instead of keeping its default,
    since a detector disagreeing with generation fails silently.
    """
    import vllm.v1.watermarking
    from pydantic import ValidationError
    from vllm.config.watermarking import WatermarkConfig
    from vllm.v1.watermarking import WatermarkDetector

    try:
        watermark = TypeAdapter(WatermarkConfig).validate_python({**config, "key": key})
    except ValidationError as error:
        messages = (
            f"{'.'.join(map(str, details['loc'])) or 'config'}: {details['msg']}"
            for details in error.errors(include_input=False)
        )
        raise ValueError(f"invalid watermark config: {', '.join(messages)}") from None

    detectors = {
        name.removesuffix("WatermarkDetector").lower(): cls
        for name in vllm.v1.watermarking.__all__
        if isinstance(cls := getattr(vllm.v1.watermarking, name), type)
        and issubclass(cls, WatermarkDetector)
        and not inspect.isabstract(cls)
    }
    cls = detectors.get(watermark.algorithm.replace("_", ""))

    if cls is None:
        raise ValueError(
            f"vLLM has no detector for watermarking algorithm {watermark.algorithm!r}"
        )

    fields = {field.name for field in dataclasses.fields(watermark)}
    parameters = inspect.signature(cls).parameters.keys() - VLLM_DETECTION_ONLY
    detector = cls(
        p_value_threshold=p_value_threshold,
        **{
            name: getattr(watermark, config_field(fields, watermark.algorithm, name))
            for name in parameters
        },
    )

    def detect(token_ids: list[int]) -> Score:
        result = detector.detect(token_ids)
        return Score(
            score=result.score,
            p_value=result.p_value,
            num_scored_tokens=result.num_scored_tokens,
        )

    return detect


def sglang_detector(
    config: Mapping[str, Any], key_file: Path, key_b_file: Path | None
) -> Detector:
    """Detector matching the generation side of SGLang's `config`.

    It scores the combined statistic, which partitions the contexts by key
    for dual-key watermarks.
    """
    from sglang.srt.sampling.watermarking import WatermarkDetector

    merged = sglang_config(config, key_file, key_b_file)
    detector = WatermarkDetector(
        merged["key"],
        key_b=merged.get("key_b"),
        mixing_probability=merged.get("mixing_probability", 0.5),
        context_window=merged.get("context_window", 4),
    )

    def detect(token_ids: list[int]) -> Score:
        result = detector.detect_tokens(token_ids).combined
        return Score(
            score=result.score,
            p_value=result.p_value,
            num_scored_tokens=result.num_contexts,
        )

    return detect


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
    engine: Engine, profile: Profile, p_value_threshold: float
) -> Detector:
    """Detector of `profile` for the watermarks of `engine`."""
    match engine:
        case "vllm":
            if profile.key_b_file is not None:
                raise ValueError("vLLM derives both keys of dual-key watermarks")

            return vllm_detector(
                profile.config, read_key(profile.key_file), p_value_threshold
            )
        case "sglang":
            return sglang_detector(profile.config, profile.key_file, profile.key_b_file)


def load_tokenizer(engine: Engine, name: str, revision: str | None) -> Tokenizer:
    """Tokenizer `name` as `engine` loads it."""
    match engine:
        case "vllm":
            from vllm.tokenizers import get_tokenizer

            return get_tokenizer(name, revision=revision)
        case "sglang":
            from transformers import AutoTokenizer

            return AutoTokenizer.from_pretrained(name, revision=revision)


def check(engine: Engine) -> None:
    """Build and run a detector for every algorithm `engine` declares."""
    with tempfile.TemporaryDirectory() as directory:
        key_file = Path(directory, "key")
        key_file.write_text("18446744073709551615")

        match engine:
            case "vllm":
                from vllm.config.watermarking import WatermarkingAlgorithm

                profiles = [
                    Profile(tokenizer="", key_file=key_file, config={"algorithm": a})
                    for a in get_args(WatermarkingAlgorithm)
                ]
            case "sglang":
                profiles = [
                    Profile(tokenizer="", key_file=key_file),
                    Profile(tokenizer="", key_file=key_file, key_b_file=key_file),
                ]

        for profile in profiles:
            create_detector(engine, profile, 0.01)(list(range(16)))


def create_groups(
    engine: Engine, profiles: Mapping[str, Profile], p_value_threshold: float
) -> list[Group]:
    """Detectors of `profiles` grouped by tokenizer, each loaded once."""
    groups: dict[tuple[str, str | None], dict[str, Detector]] = {}

    for name, profile in profiles.items():
        try:
            detector = create_detector(engine, profile, p_value_threshold)
        except ValueError as error:
            error.add_note(f"in profile {name!r}")
            raise

        groups.setdefault((profile.tokenizer, profile.revision), {})[name] = detector

    return [
        (load_tokenizer(engine, tokenizer, revision), detectors)
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
        results: dict[str, Score] = {}

        for tokenizer, detectors in groups:
            token_ids = tokenizer.encode(request.text, add_special_tokens=False)
            results |= {
                name: detector(token_ids) for name, detector in detectors.items()
            }

        profile = min(results, key=lambda name: results[name].p_value)
        best = results[profile]
        p_value = min(1.0, best.p_value * len(results))
        return Detection(
            **best.model_dump() | {"p_value": p_value},
            is_watermarked=p_value <= p_value_threshold,
            profile=profile,
        )

    return app


def serve(argv: Sequence[str]) -> None:
    """Run `sglang serve` with its keys merged into its watermark config file.

    The file is private to the server, in its own `/tmp`,
    and SGLang redacts the config in its logs.
    """
    parser = argparse.ArgumentParser(
        prog="watermark.py serve", add_help=False, allow_abbrev=False
    )
    parser.add_argument("--watermark-settings", type=json.loads, default={})
    parser.add_argument("--watermark-key-file", type=Path, required=True)
    parser.add_argument("--watermark-key-b-file", type=Path)
    args, rest = parser.parse_known_args(argv)
    config = sglang_config(
        args.watermark_settings, args.watermark_key_file, args.watermark_key_b_file
    )

    descriptor, path = tempfile.mkstemp(prefix="watermark-", suffix=".json")

    with os.fdopen(descriptor, "w") as file:
        json.dump(config, file)

    from sglang.cli.main import main

    sys.argv = ["sglang", "serve", *rest, "--watermark-config", path]
    main()


def detect(argv: Sequence[str]) -> None:
    """Serve the detection of the watermarks of an engine."""
    parser = argparse.ArgumentParser(prog="watermark.py detect", allow_abbrev=False)
    parser.add_argument("--engine", choices=get_args(Engine), required=True)
    parser.add_argument(
        "--profiles",
        type=json.loads,
        required=True,
        help="JSON object of the profiles to test, keyed by name, each with "
        "`tokenizer`, `revision`, `key_file`, the optional `key_b_file` "
        "and the keyless `config`.",
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
        create_groups(args.engine, profiles, args.p_value_threshold),
        args.p_value_threshold,
    )
    uvicorn.run(app, host=args.host, port=args.port, uds=args.uds)


def main() -> None:
    command, *argv = sys.argv[1:] or [""]

    match command:
        case "serve":
            serve(argv)
        case "detect":
            detect(argv)
        case _:
            raise SystemExit(f"usage: {sys.argv[0]} {{serve,detect}} ...")


if __name__ == "__main__":
    main()
