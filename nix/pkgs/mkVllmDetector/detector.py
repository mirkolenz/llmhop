# Adapted from https://github.com/vllm-project/vllm/blob/main/examples/basic/online_serving/watermark_detection_server.py
"""Watermark detection server configured like `vllm serve`.

It reads the `--watermark-config` JSON of the generating worker,
validated by vLLM's own `WatermarkConfig`,
and serves `POST /detect` on a TCP port or a unix socket.
"""

import argparse
import dataclasses
import inspect
from collections.abc import Container
from pathlib import Path
from typing import get_args

import uvicorn
import vllm.v1.watermarking
from fastapi import FastAPI
from pydantic import BaseModel, TypeAdapter
from vllm.config.watermarking import WatermarkConfig, WatermarkingAlgorithm
from vllm.tokenizers import TokenizerLike, cached_get_tokenizer
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
    """Candidate text, extra keys such as llmhop's `model` are ignored."""

    text: str


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


def create_app(tokenizer: TokenizerLike, detector: WatermarkDetector) -> FastAPI:
    """Serve `GET /health` and `POST /detect`."""
    app = FastAPI()

    @app.get("/health")
    def health() -> None:
        pass

    @app.post("/detect")
    def detect(request: DetectionRequest) -> WatermarkDetection:
        token_ids = tokenizer.encode(request.text, add_special_tokens=False)
        return detector.detect(token_ids)

    return app


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tokenizer", required=True)
    config = parser.add_mutually_exclusive_group(required=True)
    config.add_argument(
        "--watermark-config",
        help="JSON watermark configuration, as passed to `vllm serve`.",
    )
    config.add_argument(
        "--watermark-config-file",
        dest="watermark_config",
        type=lambda path: Path(path).read_text(),
        help="File holding the JSON of `--watermark-config`.",
    )
    parser.add_argument("--p-value-threshold", type=float, default=0.01)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--uds", help="Unix socket to bind instead of a port.")
    return parser.parse_args()


def main(args: argparse.Namespace) -> None:
    config = TypeAdapter(WatermarkConfig).validate_json(args.watermark_config)
    app = create_app(
        cached_get_tokenizer(args.tokenizer),
        create_detector(config, args.p_value_threshold),
    )
    uvicorn.run(app, host=args.host, port=args.port, uds=args.uds)


if __name__ == "__main__":
    main(parse_args())
