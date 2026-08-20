# Changelog

## [2.0.2](https://github.com/mirkolenz/llmhop/compare/v2.0.1...v2.0.2) (2026-08-20)

### Bug Fixes

* **nix:** improve conversion of settings to cli flags ([e0c09f9](https://github.com/mirkolenz/llmhop/commit/e0c09f9c770746ea75815a20aa8ac44aaa5e0d96))

## [2.0.1](https://github.com/mirkolenz/llmhop/compare/v2.0.0...v2.0.1) (2026-08-13)

### Bug Fixes

* **nixos:** add --preserve-origin to auto patchelf flags ([e29e622](https://github.com/mirkolenz/llmhop/commit/e29e62298783cdd0cad61106f8665b99c6917a1f))
* **nixos:** generalize for gpu acceleration beyond cuda ([38df11a](https://github.com/mirkolenz/llmhop/commit/38df11ad9d18e3b0bb30dd14dc97448e57d1378d))
* **nixos:** give the gpu workers the toolchain, env, and proc cuda needs ([b267e5d](https://github.com/mirkolenz/llmhop/commit/b267e5d27fffd5752f9dee2fcfb19306f99d73db))
* **nixos:** supervise worker readiness with llmhop-notify ([009b2e6](https://github.com/mirkolenz/llmhop/commit/009b2e6dfde1e8d2d92b1217d3ee2be75cc0fbbf))
* **nixos:** use dedicated users for uv workers ([90fc83a](https://github.com/mirkolenz/llmhop/commit/90fc83af344d8265d4a1b572c2d7ede3978c19e6))
* **notify:** simplify helper functions ([bb77c1b](https://github.com/mirkolenz/llmhop/commit/bb77c1b0af4a3dac0870af67e484f1de834e467c))

## [2.0.0](https://github.com/mirkolenz/llmhop/compare/v1.3.0...v2.0.0) (2026-08-07)

### ⚠ BREAKING CHANGES

* **nixos:** vllm and sglang are now native systemd units by default. The quadlet-based approach is still available as a fallback for the time being. The new services require users to set up a custom uv workspace to lock dependencies.

### Features

* couple go binary and systemd module more closely ([bbbe7db](https://github.com/mirkolenz/llmhop/commit/bbbe7db2c388ea5ad9725f44713d91267df45554))
* **nixos:** add systemd-based vllm and sglang services using uv ([4917357](https://github.com/mirkolenz/llmhop/commit/49173576d6ccd45670d57b00af85cff3bf494580))

### Bug Fixes

* **nixos:** add support for nccl to llama-cpp ([fdc9578](https://github.com/mirkolenz/llmhop/commit/fdc95780066e898ecb2f30272d355a44c2858ce8))

## [1.3.0](https://github.com/mirkolenz/llmhop/compare/v1.2.4...v1.3.0) (2026-06-30)

### Features

* add optional support for openai models endpoint ([1f63b26](https://github.com/mirkolenz/llmhop/commit/1f63b26548dc5c6660afd84089bd18e2ede525bd))

### Bug Fixes

* **nixos:** remove protect clock from systemd units ([74b14f1](https://github.com/mirkolenz/llmhop/commit/74b14f195319a329de17f335ae29ed1b483ad6b2))

## [1.2.4](https://github.com/mirkolenz/llmhop/compare/v1.2.3...v1.2.4) (2026-06-28)

### Bug Fixes

* **nixos:** split up module into core and quadlet parts ([410a053](https://github.com/mirkolenz/llmhop/commit/410a053e0e5e969500390a6d658673ec08a24863))

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
