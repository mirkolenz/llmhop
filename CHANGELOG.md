# Changelog

## [3.1.2](https://github.com/mirkolenz/llmhop/compare/v3.1.1...v3.1.2) (2026-11-10)

### Bug Fixes

* **nixos:** keep module docs out of the manual ([e2ae20e](https://github.com/mirkolenz/llmhop/commit/e2ae20ea26332a4ac85e0456ed07bf86b0c8bb28))

## [3.1.1](https://github.com/mirkolenz/llmhop/compare/v3.1.0...v3.1.1) (2026-11-09)

### Bug Fixes

* **nixos:** add native.devices to confine native model units ([8da0e7e](https://github.com/mirkolenz/llmhop/commit/8da0e7eee7d78776ec5234353648807ac9222961))

## [3.1.0](https://github.com/mirkolenz/llmhop/compare/v3.0.0...v3.1.0) (2026-11-06)

### ⚠ BREAKING CHANGES

* **nixos:** the `-quadlet` backends and gateways are replaced by `runtime = "quadlet"` on `services.llmhop.<engine>` and `services.llmhop.gateway.<type>`, or globally on `services.llmhop.runtime`. `nixosModules.quadlet` is merged into `nixosModules.default`, `systemManagerModules.default` is new, the `cache.user` and `cache.group` of container backends are now `user` and `group`, and `<engine>-quadlet-update` is now `<engine>-update`. llmhop now requires a quadlet-nix release with `systemManagerModules` and `lib.mkBundle`.

### Features

* **nixos:** replace quadlet variants with runtime option and add system-manager module ([3a18898](https://github.com/mirkolenz/llmhop/commit/3a1889877c20694539f262d3dcf507b5f4e18670))

### Bug Fixes

* **nixos:** allow backends without fetchers, cache directory and image unit ([8a9a401](https://github.com/mirkolenz/llmhop/commit/8a9a4019df283f783812c24b03458e5327371a26))
* **nixos:** reject offline workloads that cannot be isolated ([f65375a](https://github.com/mirkolenz/llmhop/commit/f65375acc9b15172ae3de1fc8a19822f07c7df71))

## [3.0.0](https://github.com/mirkolenz/llmhop/compare/v2.2.1...v3.0.0) (2026-11-05)

### ⚠ BREAKING CHANGES

* **nixos:** rework module options and socket-activate quadlet llmhop gateway
* **pkgs:** drop venv prefix of mkUvEnv arguments
* **cli:** take config as argument, listen on configured addresses and name auth tokens
* **router:** route model names containing slashes
* **router:** answer errors as openai json with retry and auth headers
* **router:** bound buffered bodies by bytes instead of requests
* **nixos:** open firewall per llmhop listener and reject it on loopback
* **cli:** replace flags with serve and check subcommands
* **nixos:** test several watermark profiles per detector and drop detector unit prefix
* **nixos:** use complete container image references
* **nixos:** serve models through one selectable gateway or none
* **router:** limit concurrency per model and add readiness probe
* remove llmhop-notify in favor of post-start health checks
* **nixos:** remove rootless quadlet user, unit override options and encrypted credentials
* **nixos:** fetch models in separate units, serve them offline and prune hub cache

### Features

* **cli:** replace flags with serve and check subcommands ([52bd09d](https://github.com/mirkolenz/llmhop/commit/52bd09d211e0a25fb9ceae3c77fefe15e8db2c5d))
* **cli:** take config as argument, listen on configured addresses and name auth tokens ([01211a8](https://github.com/mirkolenz/llmhop/commit/01211a8e156ef7c33d83e73b6384ad01265eace7))
* drain in-flight requests on shutdown ([96a639f](https://github.com/mirkolenz/llmhop/commit/96a639fe1c4b969c3b192a2057ff10d55c1dfa3b))
* **nixos:** add bundle uninstall script and retire units dropped on reinstall ([0f8d0d8](https://github.com/mirkolenz/llmhop/commit/0f8d0d892768cf2e857360ab6bbe01ecb7775b2a))
* **nixos:** add fetch token credential for gated repositories ([eaed844](https://github.com/mirkolenz/llmhop/commit/eaed844c360d2497a3b4143846cbc2eee19ed711))
* **nixos:** add llmhop-quadlet gateway running bundled image archive ([be3ee92](https://github.com/mirkolenz/llmhop/commit/be3ee927f977c0a7659eed1d7a19c78af76594e1))
* **nixos:** configure user namespaces and mount options for every quadlet container ([3a2a8dc](https://github.com/mirkolenz/llmhop/commit/3a2a8dca5a806b3ff447e706b6608ee10a562aef))
* **nixos:** expand credential references in worker and gateway environments ([b376a3d](https://github.com/mirkolenz/llmhop/commit/b376a3df50804389e8265b2918e9a207627bc5b3))
* **nixos:** export quadlet units as bundle for hosts without nix ([da8a43e](https://github.com/mirkolenz/llmhop/commit/da8a43ebca1f096b662b2ac6894869d97e8bedc8))
* **nixos:** fetch models in separate units, serve them offline and prune hub cache ([0f0212f](https://github.com/mirkolenz/llmhop/commit/0f0212f4470330784ff7aea7d984e267c7876a85))
* **nixos:** open firewall per llmhop listener and reject it on loopback ([d9c4aeb](https://github.com/mirkolenz/llmhop/commit/d9c4aeb418bcd78ae2a721a893088e04efa9bd64))
* **nixos:** prune hub caches with llmhop instead of python ([c1aa4b5](https://github.com/mirkolenz/llmhop/commit/c1aa4b5b925f9823d533a4be5417227267603283))
* **nixos:** restart quadlet containers with their image ([93a637d](https://github.com/mirkolenz/llmhop/commit/93a637d4b856313fd198644cdd896154c11b1fdb))
* **nixos:** rework module options and socket-activate quadlet llmhop gateway ([08743c0](https://github.com/mirkolenz/llmhop/commit/08743c0ff85b5d807c136128632d9a36bd522b15))
* **nixos:** serve models through one selectable gateway or none ([b8f9a6e](https://github.com/mirkolenz/llmhop/commit/b8f9a6e8effb39b67f0d29f7a7fda5dd11b1bc1a))
* **nixos:** test several watermark profiles per detector and drop detector unit prefix ([4597700](https://github.com/mirkolenz/llmhop/commit/4597700752a87689f228b9299690e2140526abbe))
* **nixos:** use complete container image references ([abe1353](https://github.com/mirkolenz/llmhop/commit/abe13531dc0dbb40189ce9d17420ee0b0e917a2a))
* **nixos:** wait for native servers with llmhop instead of curl ([77b5b3e](https://github.com/mirkolenz/llmhop/commit/77b5b3e4653ab47f1579e03e3e2a54af161fe4ca))
* **pkgs:** drop venv prefix of mkUvEnv arguments ([658c746](https://github.com/mirkolenz/llmhop/commit/658c746589b669f1baf325dbb3d8caae97c47edf))
* **router:** answer errors as openai json with retry and auth headers ([b477f40](https://github.com/mirkolenz/llmhop/commit/b477f4012ebafea363efd7b6ecc0604f729b57eb))
* **router:** bound buffered bodies by bytes instead of requests ([22acd74](https://github.com/mirkolenz/llmhop/commit/22acd74ec63ca19054a8130313b0cf98aa4df93d))
* **router:** limit concurrency per model and add readiness probe ([cbf4fc8](https://github.com/mirkolenz/llmhop/commit/cbf4fc8039d95a030f1aec28e699704308bb1caa))
* **router:** route model names containing slashes ([9b7845b](https://github.com/mirkolenz/llmhop/commit/9b7845b8b253f47606d4aa228363466dc0f69feb))

### Bug Fixes

* close idle keep-alive connections ([1448d9d](https://github.com/mirkolenz/llmhop/commit/1448d9dc41fb00a1a4932d1be636ada07b30a9c2))
* **docker:** run image as nobody and ship llmhop and ca certificates in its root ([ac126aa](https://github.com/mirkolenz/llmhop/commit/ac126aa703b25244b2ab6dd2513c82f1dfae2db5))
* **nixos:** always restart every server ([fc8d780](https://github.com/mirkolenz/llmhop/commit/fc8d780ea2f9e046f683f0c61f75a61896948862))
* **nixos:** restart native gateway with its listener sockets ([c682dac](https://github.com/mirkolenz/llmhop/commit/c682dac0102e78e75cab0a34d6fcbf714fb74788))

### Performance Improvements

* **upstream:** keep more idle connections per backend ([62f44b0](https://github.com/mirkolenz/llmhop/commit/62f44b053045f93ff817f694a17767f5466cc18b))

### Code Refactoring

* **nixos:** remove rootless quadlet user, unit override options and encrypted credentials ([2130b43](https://github.com/mirkolenz/llmhop/commit/2130b438607f20088124ef3a5ac1dccb431e5863))
* remove llmhop-notify in favor of post-start health checks ([9ae5e38](https://github.com/mirkolenz/llmhop/commit/9ae5e38f33636147df800fc6dbd506456e50a4e2))

## [2.2.1](https://github.com/mirkolenz/llmhop/compare/v2.2.0...v2.2.1) (2026-10-01)

### Bug Fixes

* **nixos:** configure vllm watermarking declaratively with a key credential ([4a6aa6a](https://github.com/mirkolenz/llmhop/commit/4a6aa6a146d774f22f7401faf08211e12df93dea))
* **nixos:** import credentials by name and keep them out of the nix store ([6bc97ad](https://github.com/mirkolenz/llmhop/commit/6bc97addc9dd4d4978be8598e7988bcf452c47cd))
* **router:** select the backend by a /route/{model} path prefix ([60174bd](https://github.com/mirkolenz/llmhop/commit/60174bd1154a40e261532b9c70198a115913e045))

## [2.2.0](https://github.com/mirkolenz/llmhop/compare/v2.1.2...v2.2.0) (2026-10-01)

### Features

* **config:** validate inputs and expose request limits ([6bec84a](https://github.com/mirkolenz/llmhop/commit/6bec84ae96fdad5fe2cc1343d91045ce23b1f6c9))
* **nixos:** vendor the vllm watermark detector server ([c53fdeb](https://github.com/mirkolenz/llmhop/commit/c53fdeb92df662f137b0e2cb04cfdc6ad3f23312))
* **nix:** reach backends and serve clients over unix sockets ([62d47a1](https://github.com/mirkolenz/llmhop/commit/62d47a1e65f9ed2f2d5b39a0f2e3a348677dad6d))
* **nix:** unify service identities across backends and llmhop ([6651e22](https://github.com/mirkolenz/llmhop/commit/6651e228e12b7345a3cefe808a0cd8fd173d0bd3))
* **router:** bound and validate proxied requests ([d1acfd1](https://github.com/mirkolenz/llmhop/commit/d1acfd1e9984adb5157c610f491636a669751d16))
* **secrets:** expand only scheme references through os.Expand ([89738d3](https://github.com/mirkolenz/llmhop/commit/89738d32bc7689c1c96c240093fb538acb9bfd67))
* serve every socket passed by systemd socket activation ([c8c05fa](https://github.com/mirkolenz/llmhop/commit/c8c05fa93c3c2e0c4c3b1e092010fdaf38ef1ee3))
* support unix socket model urls ([c07d2d2](https://github.com/mirkolenz/llmhop/commit/c07d2d25126e63dd5cecec0cc63959648bb567c3))

### Bug Fixes

* **authz:** match the bearer scheme case-insensitively ([4dde6e4](https://github.com/mirkolenz/llmhop/commit/4dde6e44af8952487d6568e48fffcfa1ea1cccb5))
* check ignored close and unsetenv errors ([1098cde](https://github.com/mirkolenz/llmhop/commit/1098cde481078e781ec33001f8ce25ec0fc81bd9))
* drop quadlet user helpers in favor of quadletctl ([8593ac7](https://github.com/mirkolenz/llmhop/commit/8593ac7b102237fa842b6767b929bb0bce80c7ed))
* **nix:** count only loadable ELF libraries as providers ([96d3e37](https://github.com/mirkolenz/llmhop/commit/96d3e375cf24db7633f5a00990915dbb9d3ae532))
* **nix:** omit unsupported x86 Darwin outputs ([787406b](https://github.com/mirkolenz/llmhop/commit/787406b7500d26d19b9929d0a92d9b178beb7b64))
* **nix:** probe SGLang gateways at their configured address ([7a84f91](https://github.com/mirkolenz/llmhop/commit/7a84f91eea015dfc6824cf37a313c609414b60ad))
* **nix:** reach native worker sockets through backend groups ([2401443](https://github.com/mirkolenz/llmhop/commit/2401443d56dcdbd6dbe24eff43116b25b8acfe28))
* **nix:** reject unsafe socket directory paths ([731a050](https://github.com/mirkolenz/llmhop/commit/731a0501e5c6290164c618054bca73ec16af793d))
* **secrets:** trim exactly one line terminator from secret files ([a92f9bd](https://github.com/mirkolenz/llmhop/commit/a92f9bd75752d765d03453cebdd88af869d75e6a))
* **systemd:** handle readiness and activation failures ([02c7be3](https://github.com/mirkolenz/llmhop/commit/02c7be3b78fa65da4d7cbff8b906af8059df9f39))

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
