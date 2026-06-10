# Changelog

## [1.2.3](https://github.com/mirkolenz/llmhop/compare/v1.2.2...v1.2.3) (2026-06-10)

### Bug Fixes

* **llama-cpp:** set memlock limit to infinity ([d7082b0](https://github.com/mirkolenz/llmhop/commit/d7082b07e9b9ccc4327b9797ff1b56cda82d96fa))
* **systemd:** drop unsupported hardening flag ([7adf7df](https://github.com/mirkolenz/llmhop/commit/7adf7df214b6e7bce2e8afac5038212e9319fb1e))
* **vllm:** always restart services, not just on failure ([4fba157](https://github.com/mirkolenz/llmhop/commit/4fba15741e01d6ce34250aef958709114df968bb))

## [1.2.2](https://github.com/mirkolenz/llmhop/compare/v1.2.1...v1.2.2) (2026-05-29)

### Bug Fixes

* **nixos:** remove read-only config from container-based services ([689cb34](https://github.com/mirkolenz/llmhop/commit/689cb345009973a21510ff4b2aaae724a58ab11f))

## [1.2.1](https://github.com/mirkolenz/llmhop/compare/v1.2.0...v1.2.1) (2026-05-18)

### Bug Fixes

* **nixos:** allow arbitrary devices to be added to quadlet, not just nvidia gpus ([e4d5f8c](https://github.com/mirkolenz/llmhop/commit/e4d5f8c9986bf114f8d6c1b44904a4993b118759))

## [1.2.0](https://github.com/mirkolenz/llmhop/compare/v1.1.0...v1.2.0) (2026-05-13)

### Features

* **nixos:** add options for serving llama-cpp, sglang, vllm ([67c07d4](https://github.com/mirkolenz/llmhop/commit/67c07d44b398fec73600b4323657c83311d1cb78))

## [1.1.0](https://github.com/mirkolenz/llmhop/compare/v1.0.1...v1.1.0) (2026-04-14)

### Features

* add support for auth tokens and model headers ([c302742](https://github.com/mirkolenz/llmhop/commit/c30274258dab54228f1b071ca8e6cf0c7f8c936d))

## [1.0.1](https://github.com/mirkolenz/llmhop/compare/v1.0.0...v1.0.1) (2026-04-14)

### Bug Fixes

* **build:** use image streams for docker manifest ([1a8a1a6](https://github.com/mirkolenz/llmhop/commit/1a8a1a6f10cc2ea373fbb97910805eb865ebb3d7))

## 1.0.0 (2026-04-14)

### Features

* initial commit ([b82381b](https://github.com/mirkolenz/llmhop/commit/b82381be65c5c0513615fba0b23181f3c91077f4))
