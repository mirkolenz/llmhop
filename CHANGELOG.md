# Changelog

## [2.1.2](https://github.com/mirkolenz/llmhop/compare/v2.1.1...v2.1.2) (2026-09-23)

### Bug Fixes

* **nix/uv:** don't patch pure wheels ([a15d90b](https://github.com/mirkolenz/llmhop/commit/a15d90b6fc21ccdd6e891d13d554948aade692de))
* **nix/uv:** make missing links check more robust ([acd31ad](https://github.com/mirkolenz/llmhop/commit/acd31ad93f4d4a05f5848c783b1c9adec66c1cb6))
* **nix/uv:** split missing lib exceptions into driver and optional ones ([83b4469](https://github.com/mirkolenz/llmhop/commit/83b4469035b65d9b56d4d3eecb32caff74a65689))

## [2.1.1](https://github.com/mirkolenz/llmhop/compare/v2.1.0...v2.1.1) (2026-09-22)

### Bug Fixes

* **nix:** update packaging of missing libs check ([a52a7e2](https://github.com/mirkolenz/llmhop/commit/a52a7e2d6657ec284e1e1240ffcd229d55db43c2))

## [2.1.0](https://github.com/mirkolenz/llmhop/compare/v2.0.3...v2.1.0) (2026-09-22)

### Features

* address systemd credentials by name ([a750301](https://github.com/mirkolenz/llmhop/commit/a750301aedddc4ebd3de53a97a0cab9225d41232))
* hide unlisted backends from the model catalog ([086673a](https://github.com/mirkolenz/llmhop/commit/086673ae054b354d62646f5680995cc9e945f56c))
* **nix:** add mkCudaHome for runtime jit compilers ([aa6f185](https://github.com/mirkolenz/llmhop/commit/aa6f18534dc4d9b9bc5ee4e3f9516e8e3721a30e))
* **nix:** derive cuda package set from uv.lock ([a9de83c](https://github.com/mirkolenz/llmhop/commit/a9de83c0b298f194d3d454b282e7180f7b2a0c92))
* **nixos:** add llama.cpp quadlet backend ([1f1fa46](https://github.com/mirkolenz/llmhop/commit/1f1fa46d7fbc148f790c99ad09a879960cedf5ef))
* **nixos:** default the watermark detector script to locked vllm sdist ([60a410d](https://github.com/mirkolenz/llmhop/commit/60a410d65c86f5f96030ed6b296a727ecf77b473))
* **nixos:** fail build on unresolved shared libraries ([66ccd29](https://github.com/mirkolenz/llmhop/commit/66ccd29420431809169fa0f5ef91f45dc26b3f7b))
* **nixos:** route watermark detectors through llmhop ([8f65a0c](https://github.com/mirkolenz/llmhop/commit/8f65a0c523fd497e79b48b04da78a43f2cca7026))
* **nixos:** select python interpreter from uv.lock ([e82353f](https://github.com/mirkolenz/llmhop/commit/e82353f72dd3190064611be4310b960b048a706f))
* **nixos:** serve vllm watermark detectors ([e3090a2](https://github.com/mirkolenz/llmhop/commit/e3090a21578fd0845df4acc77857fd221edd6a36))
* **nixos:** support rootful and configurable quadlets ([7db4526](https://github.com/mirkolenz/llmhop/commit/7db4526906390b665805a64bf8719b16b1278887))
* **notify:** allow configuring readiness path ([0283f48](https://github.com/mirkolenz/llmhop/commit/0283f48ed57190868622272ad2931e183939b73a))

### Bug Fixes

* **nixos:** give module-managed flags precedence over settings ([4084801](https://github.com/mirkolenz/llmhop/commit/40848013a655a2326302df4b65aad365a9dbcb93))
* **nixos:** key llmhop models by their routing name ([3d101bc](https://github.com/mirkolenz/llmhop/commit/3d101bc6f89f3f9d7a4825a0466d2ca94f9c5055))
* **nixos:** reject native backend and its quadlet twin ([7b7c0a9](https://github.com/mirkolenz/llmhop/commit/7b7c0a93ef68a43f73a3b0d2c54850f27f640a5a))
* **nixos:** require key for watermark detectors ([cf33a8e](https://github.com/mirkolenz/llmhop/commit/cf33a8e225b452d7711b12aa2ca272ea16be1add))
* **nixos:** validate systemd credential names ([f605f53](https://github.com/mirkolenz/llmhop/commit/f605f5366f5b060a1c2d8a00ca661ae24eaee7fb))

## [2.0.3](https://github.com/mirkolenz/llmhop/compare/v2.0.2...v2.0.3) (2026-08-31)

### Bug Fixes

* **nixos:** add network-online dependency to systemd units ([b91426a](https://github.com/mirkolenz/llmhop/commit/b91426a06f8d9190fc70bf4a697abb75e51aed03))
* **nixos:** allow overriding systemd unit config ([822d67f](https://github.com/mirkolenz/llmhop/commit/822d67f6972015e7fd77f64e4b1ffc92fe3fc7d8))

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
