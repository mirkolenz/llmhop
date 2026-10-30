# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop peeks at the `model` field of an incoming OpenAI-compatible request and reverse-proxies it to the matching backend.
It is built for single-model inference servers like [vLLM](https://github.com/vllm-project/vllm) and [sglang](https://github.com/sgl-project/sglang) that need a thin model-aware gateway, but it works with any OpenAI-compatible backend, including multi-model servers and hosted providers.

## Features

- Model-aware reverse proxy for any OpenAI-compatible backend, self-hosted or remote: vLLM, sglang, TabbyAPI, Aphrodite, Ollama, LocalAI, OpenRouter, together.ai, DeepInfra, etc.
- Path-based routing under `/route/{model}/`, a models API served from the config, an unauthenticated `/health` with `sd_notify` readiness and a `/readiness` probing the backends.
- Stateless single binary in pure Go with no third-party packages and no CGO, safe behind any load balancer, draining in-flight requests on shutdown.
- Ships as a static binary, a minimal Docker image and a hardened NixOS module that runs llama.cpp, sglang or vLLM workers behind llmhop, SMG, Bifrost or no gateway at all.

## How it works

LLMhop reads the `model` field of the JSON request body, looks it up in its config, and forwards the request verbatim to the configured backend.
Unknown models return `404`, while invalid JSON and a missing or non-string `model` return `400`.
`GET /v1/models` and `GET /v1/models/{model}` are answered by LLMhop itself, never proxied, so the catalog reflects exactly what clients may ask for.
When `authTokens` is set, all routes except `/health` and `/readiness` require a valid bearer token.

### Path routing

A request under `/route/{model}/` selects its backend by path instead of body.
LLMhop strips the `/route/{model}` prefix and forwards the rest unchanged, so `POST /route/production/detect` reaches the `production` backend as `POST /detect`.
The body is never parsed, so it need not be JSON or carry a `model` field.
Unknown models return `404`, and authentication, request limits, header injection and unix socket upstreams apply as for body routing.
A model name containing `/` is written as `%2F`, as in `/route/Qwen%2FQwen3-8B/v1/chat/completions`.
A backend marked `"unlisted": true` is routed like any other but left out of both model endpoints, which suits services that are not inference models, such as the [watermark detector](#routing-detectors-through-llmhop).

### Health

`GET /health` never requires a token and returns the number of models that `GET /v1/models` advertises, so a check can assert that the proxy came up with the expected catalog:

```json
{ "status": "ok", "models": 3 }
```

LLMhop sends `READY=1` only after the listener is bound, so its `Type=notify` NixOS unit stays `activating` until requests are served.

`GET /readiness` never requires a token either and probes the `health` path of every model that sets one, concurrently and with a timeout of 5 seconds each.
It answers `200` when every probe returns `2xx`, and `503` otherwise, logging each failure but naming no model in the response:

```json
{ "status": "unavailable", "ready": 1, "probed": 2 }
```

On `SIGTERM` or `SIGINT`, LLMhop stops accepting connections and drains in-flight requests, streams included, until they finish, a second signal arrives or systemd's `TimeoutStopSec` expires.

## Authentication

Both sides are opt-in: without `authTokens` and `models.*.headers`, headers are forwarded verbatim.
When `authTokens` is set, the incoming `Authorization: Bearer <token>` header is validated in constant time and stripped before forwarding, so the client token never leaks upstream.
Per-model `headers` are applied last, so a configured `Authorization` always wins over what the client sent.

## Configuration

```json
{
  "host": "127.0.0.1",
  "port": 8080,
  "authTokens": ["${cred:llmhop.client-token}"],
  "models": {
    "llama-3-8b": { "url": "http://localhost:30000", "health": "/health" },
    "qwen3-8b": {
      "url": "unix:///run/llmhop/vllm-qwen3-8b/http.sock",
      "health": "/health",
      "maxConcurrentRequests": 16
    },
    "openai-gpt-4o": {
      "url": "https://api.openai.com",
      "headers": { "Authorization": "Bearer ${cred:openai-key}" }
    }
  }
}
```

`host` defaults to every interface and `port` to `8080`, with IPv6 literals written plain (`"host": "::1"`).
A model `url` is an absolute `http(s)` URL or `unix:///<socket path>`, which carries no path prefix, so requests go to the root of the server on that socket.
`health` is the backend path that [`/readiness`](#health) probes, and a model without one is not probed.

### Secret references

String values in `authTokens` and `models.*.headers` are expanded at startup, so no plaintext secret has to live in the config file:

- `${cred:name}`: the systemd credential `name` from `$CREDENTIALS_DIRECTORY`.
- `${env:NAME}`: the `NAME` environment variable.
- `${file:/absolute/path}`: a file at an absolute path, with trailing newlines trimmed.
- `$$`: a literal `$`, so `$${env:NAME}` stays as written, while a bare `$NAME` is rejected.

Unresolved references are a hard startup error.
The NixOS module uses `${cred:name}` for the model backends too, which receive the credential's path instead of its contents, since they open the file themselves.

### Validation

Unknown keys are rejected, so a misspelled `maxBodyBytes` fails loudly instead of silently falling back to its default.
`llmhop --check --config config.json` runs the full startup path and exits without binding a port.
It leaves secret references unexpanded, so a config can be validated where they do not resolve, such as in CI or a Nix build.

### Request limits

Body-routed requests are buffered in memory to read the `model` field, while path-routed ones are streamed.
Either way, bodies above `maxBodyBytes`, 100 MiB by default, are rejected with `413`, a declared `Content-Length` above it before reading.
At most `maxBufferedRequests` bodies, 8 by default, are buffered at once, each from its arrival until the backend has received it, so memory stays bounded while long responses hold no slot, and further body-routed requests get `503` immediately.
A buffered body must arrive within a minute, or the request gets `408`.
A model's `maxConcurrentRequests` caps its proxied requests, so a busy model never starves another, and further ones get `503` immediately.
That is unlimited by default, since inference servers queue requests themselves, and `0` disables any of these limits.

## Running

```sh
llmhop --config config.json
nix run github:mirkolenz/llmhop -- --config config.json
docker run --rm -p 8080:8080 -v ./config.json:/config.json ghcr.io/mirkolenz/llmhop --config /config.json
```

## NixOS module

Add the flake input `github:mirkolenz/llmhop` and import `llmhop.nixosModules.default`:

```nix
services.llmhop = {
  gateway.type = "builtin";
  gateway.builtin.listen.default.host = "";
  gateway.builtin.openFirewall = true;
  llama-cpp.enable = true;
  llama-cpp.models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
};
```

`nixosModules.default` ships the gateways and the native backends without depending on quadlet-nix, so it also works with [system-manager](https://github.com/numtide/system-manager).
`nixosModules.quadlet` includes it and adds the container variants `llama-cpp-quadlet`, `vllm-quadlet` and `sglang-quadlet` of the backends and `smg-quadlet` and `bifrost-quadlet` of the gateways.
The design rationale is collected in the [module internals](https://mirkolenz.github.io/llmhop/internals.html).

### Gateways

`services.llmhop.gateway.type` selects at most one gateway, configured by the option set of the same name, which routes every listed model of every backend by its `name`.

| `type`                           | Gateway                                                          | Reaches unix sockets | Routes detectors |
| -------------------------------- | ---------------------------------------------------------------- | -------------------- | ---------------- |
| `null`                           | none, clients connect to each model                              |                      |                  |
| `"builtin"`                      | llmhop, this repository's binary                                 | yes                  | yes              |
| `"smg"`, `"smg-quadlet"`         | the [Shepherd Model Gateway](https://github.com/smg-project/smg) | no                   | no               |
| `"bifrost"`, `"bifrost-quadlet"` | [Bifrost](https://github.com/maximhq/bifrost)                    | no                   | no               |

A routed model must stay on loopback so no client bypasses the gateway, and leave authentication to the gateway.
A gateway without socket support requires every routed model to set a `port`.
Each gateway listens on `127.0.0.1:8080` by default and uses its own secret interface, configured below.

#### Without a gateway

Each model is served on its own, on its default unix socket or on its `port`, bound to `host`.
Configure authentication through the server's own credential-backed settings, keeping keys off the command line and out of the Nix store.
For vLLM and SGLang, provision a private YAML file containing `api-key: "your-secret"` and pass it through `settings.config`:

```nix
services.llmhop.vllm.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  port = 8001;
  host = "0.0.0.0";
  openFirewall = true;
  credentials."config.yaml" = "/run/secrets/qwen-vllm.yaml";
  settings.config = "\${cred:config.yaml}";
};
```

llama.cpp reads its keys directly through `settings.api-key-file`, as shown under [inference server credentials](#inference-server-credentials).
`services.llmhop.socketClients` lists the users that may connect to every model socket, such as a reverse proxy in front of them.

#### Built-in llmhop

The unit runs as the `llmhop` system user with aggressive sandboxing, restarts on failure and reaches every model socket.
Its listeners are `llmhop-<name>.socket` units handed over through socket activation, one per entry of `listen`, which always holds a `default` one on port `8080`, as in `listen.default.host = ""` or `listen.caddy.socketGroup = "caddy"` for a unix socket listener.
Every model and detector is a model of its config with `health = "/health"`, so `/readiness` reports whether all of them serve.
The generated config is validated at build time with `llmhop -check`, so a typo fails `nixos-rebuild` rather than the service, except in cross-compiled deployments.

#### SMG

The [Shepherd Model Gateway](https://github.com/smg-project/smg) registers every listed model of any engine from a generated discovery file, retrying each until it serves.
Natively, its `package` is a Python environment built with [`mkUvEnv`](#native-vllm-and-sglang-from-prebuilt-wheels), and the container runs the complete reference in `image`.
`settings` takes SMG's CLI flags, where a credential reference resolves to a file path:

```nix
services.llmhop.gateway = {
  type = "smg-quadlet";
  smg-quadlet = {
    image = "ghcr.io/smg-project/smg:nightly";
    credentials."smg.api-key" = null;
    settings.api-key-file = "\${cred:smg.api-key}";
  };
};
```

File-based authentication requires an SMG build supporting `--api-key-file` and `--tenant-api-keys-file`, which are available on upstream `main` but absent from v1.13.0.
Use a package or image built from a revision with those flags when configuring them.
SMG forwards the client's `Authorization` header to the model, so routed models leave authentication to the gateway.

#### Bifrost

[Bifrost](https://github.com/maximhq/bifrost) gets every listed model as a key of its `vllm` provider, or `sgl` for SGLang, so clients send `vllm/<name>`, or the plain name.
`settings` is its `config.json`, using Bifrost's native `env.NAME` references for secrets loaded from `environmentFile`:

```nix
services.llmhop.gateway = {
  type = "bifrost";
  bifrost = {
    package = inputs.bifrost.packages.${pkgs.system}.bifrost-http;
    environmentFile = "/run/secrets/bifrost.env";
    settings.encryption_key = "env.BIFROST_ENCRYPTION_KEY";
  };
};
```

Provision that file outside the Nix store with `BIFROST_ENCRYPTION_KEY=<secret>`, readable only by the service manager.
nixpkgs lacks Bifrost, so the native `package` comes from Bifrost's own flake, and the container's `image` selects a reference such as `docker.io/maximhq/bifrost:v2.3.2`, both with their app directory at `/var/lib/bifrost`.

### Inference backends

Each backend exposes a `models` attrset under `services.llmhop.<backend>`, and every entry becomes an isolated worker on a unix socket or port, routed by the selected [gateway](#gateways) automatically.
All backends can be enabled side by side, while a backend's native and container variants share unit names, so evaluation rejects any port, unit or routing key that two of them claim.
See the [options reference](https://mirkolenz.github.io/llmhop/) for every option.

```nix
services.llmhop = {
  llama-cpp = {
    enable = true;
    models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  };
  sglang = {
    enable = true;
    package = inputs.llmhop.legacyPackages.${pkgs.system}.mkUvEnv { workspaceRoot = ./sglang-env; };
    models."qwen3-coder" = {
      port = 19001;
      model = "Qwen/Qwen3-8B";
      settings.reasoning-parser = "qwen3";
    };
  };
  vllm = {
    enable = true;
    package = inputs.llmhop.legacyPackages.${pkgs.system}.mkUvEnv { workspaceRoot = ./vllm-env; };
    models."llama-3-8b".model = "meta-llama/Meta-Llama-3-8B-Instruct";
  };
};
```

Native workers are hardened system units running as the backend's `user`, managed with `systemctl status <backend>-<model>` and `journalctl -u <backend>-<model>`.
llama.cpp comes from nixpkgs, vLLM and SGLang from [prebuilt wheels](#native-vllm-and-sglang-from-prebuilt-wheels).
The container variants run through [quadlet-nix](https://github.com/mirkolenz/quadlet-nix) as rootful system units, managed with `quadletctl`, as in `quadletctl systemctl status <unit>`, `quadletctl journalctl <unit> -f`, `quadletctl podman <unit> ps`, `quadletctl list` and `quadletctl shell <unit>`.
Each native model or detector inherits its backend's `package`, while each container model or detector inherits its backend's `image`, with either overridable per workload.
Container backends and gateways require a complete `image` reference with a tag or digest, such as `docker.io/vllm/vllm-openai:latest` or `docker.io/vllm/vllm-openai@sha256:<digest>`.
A worker stays `activating` until its server answers `/health`, so `startupOrdering` boots them one at a time in ascending `name` order, as the [internals](https://mirkolenz.github.io/llmhop/internals.html#lifecycle) explain.

The module exposes no escape hatches for unit settings, since NixOS merges definitions of the generated units themselves.
Lists such as `SupplementaryGroups` extend what the module sets, and `lib.mkForce` replaces a setting:

```nix
systemd.services.vllm-qwen3-8b.serviceConfig.MemoryHigh = "64G";
virtualisation.quadlet.containers.vllm-qwen3-8b.containerConfig.GroupAdd = [ "keep-groups" ];
```

#### Listeners

llama.cpp and vLLM models and watermark detectors default to `port = null`, which binds the read-only `socket` below `services.llmhop.socketDirectory`, reachable only by the backend's workers, the llmhop gateway and `socketClients`.
Set `port` to bind `<host>:<port>` instead, which every gateway but llmhop requires and SGLang always needs, lacking socket support upstream.
Containers see their socket directory at `/run/llmhop/socket`, mounted with Podman's `U` option, so sockets work with any `User=` and `UserNS=`.

#### Fetching and offline servers

Every model runs as two units, the fetcher `<backend>-<model>-fetch`, which downloads everything the server loads, and the offline server `<backend>-<model>`.
The fetcher runs before its server and stays active, so a restarted server does not fetch again.
Each model has its own cache `cache.directory/<name>`, which no other model touches, even one serving the same repository.
A failed or interrupted download leaves the server on its last complete download, and the next fetch resumes the partial files.
A server never starts from an incomplete snapshot.
Fetchers use `hf download` from the backend's package or image, or `llama download`, which resolves quantization tags, split files and the mmproj as `llama-server` would.
A `model` that is an absolute path is served as is without a fetcher.

```nix
services.llmhop.vllm.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  revision = "main"; # branch, tag or commit, `null` follows the default branch
  extraModels = [ "Qwen/Qwen3-0.6B" ]; # referenced in `settings`, never downloaded by the server
  settings.speculative-config = {
    model = "Qwen/Qwen3-0.6B";
    num_speculative_tokens = 4;
  };
};
```

Only the fetchers get the backend's `fetch` credentials and environment, such as a token for gated repositories or a proxy, while llama.cpp reads no token file and takes `HF_TOKEN` through `fetch.environmentFile`:

```nix
services.llmhop.vllm.fetch = {
  credentials."llmhop.hf-token" = null;
  environment.HF_TOKEN_PATH = "\${cred:llmhop.hf-token}";
};
```

Servers only read their hub cache, so they always get `HF_HUB_OFFLINE`, llama.cpp also `--offline`, and native servers have no DNS resolver.
On its default unix socket, a server runs without any network, while a native server on a `port` can only reach `127.0.0.1` and `::1`, and a container on a `port` stays in Podman's default network, so prefer the socket.
`offline = false` lifts these network restrictions for one model or detector.
Point `cache.directory` at a data disk for large models, and inspect a model's cache with the standard `hf cache` tooling and `HF_HOME=<cache.directory>/<name>`.

`<backend>-update` restarts every fetcher of its backend one after another on the `fetch.interval` schedule, daily by default.
A complete download deletes every repository and revision its model no longer references, while llama.cpp keeps every downloaded quantization of its repository.
It then restarts the server if the cache changed, and starts it if it failed, such as after a first boot without network.
A failed fetcher stays failed until the next update and leaves the other fetchers alone.
Containers reference a shared Quadlet image unit `<backend>-<image-hash>-image` with `Pull=never`, and the image unit uses Podman's default pull policy.
A server tracking a tag is labeled `AutoUpdate=registry`, while digest-pinned servers and fetchers do not auto update.
Set `virtualisation.quadlet.autoUpdate.enable = true` to update and restart tagged servers through Quadlet Nix's timer, which runs `podman-auto-update.service`.
Its separate `autoPrune.enable` timer removes unused images, as described in [quadlet-nix](https://github.com/mirkolenz/quadlet-nix#updates-and-pruning).

Features that download at runtime need another source:

- vLLM and SGLang need `flashinfer-cubin` in their uv workspace, which the official images ship.
- SGLang's native fetchers also download the flash-attention kernels its images ship, `kernels-community/sgl-flash-attn3` at the revision SGLang loads.
- Remote code whose `auto_map` points to another repository, and a draft model, LoRA adapter or tokenizer referenced in `settings`, belong in `extraModels`.
- Media URLs in requests cannot be fetched, so send media inline or set `offline = false`.

#### Settings rendering

`settings` is rendered into the server's CLI flags, over the backend's `modelSettings`.
The flags derived from the other options, such as the listener and the served model name, always win, so gateways, health checks and fetchers agree with the server.
Strings and paths are passed verbatim and everything else as JSON, so `0.6` stays `0.6` and an attribute set becomes the JSON object that options like vLLM's `--speculative-config` parse.

- `true` becomes `--<key>`, while `null` and empty lists are dropped.
- llama.cpp and vLLM render `false` as `--no-<key>`, so a flag without that twin, such as an on-only or `on|off|auto` one, has to be omitted or given its value.
- SGLang drops `false`, so write the negated key, as in `disable-radix-cache = true;`.
- vLLM and SGLang pass a list to one flag (`--<key> a b`), so the few options expecting a repeated flag need one value at a time, while llama.cpp repeats the flag per element (`--<key> a --<key> b`).

#### Quadlet execution and user namespaces

quadlet-nix installs system units and Podman runs rootfully, where llama.cpp's `image` selects one of the upstream server image variants:

```nix
services.llmhop.llama-cpp-quadlet = {
  enable = true;
  image = "ghcr.io/ggml-org/llama.cpp:server-cuda";
  models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
};
```

User namespaces and other [`[Container]` keys](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html#container-units-container) go on the generated containers, the server and its fetcher alike, so both see the cache under one owner.
With `idmap`, the container sees host IDs unshifted, so `cache` sets the container user as the host owner.
Rootful `UserNS=auto` allocates from the subordinate IDs of the `containers` user, which NixOS does not declare:

```nix
virtualisation.quadlet.containers = lib.genAttrs [ "vllm-qwen3-8b" "vllm-qwen3-8b-fetch" ] (_: {
  containerConfig = {
    User = "1000";
    UserNS = "auto:size=65536";
  };
});
services.llmhop.vllm-quadlet.cache = {
  user = "1000";
  group = "1000";
  mountOptions = [ "idmap" ];
};
users.users.containers = {
  isSystemUser = true;
  group = "containers";
  subUidRanges = [ { startUid = 100000; count = 1048576; } ];
  subGidRanges = [ { startGid = 100000; count = 1048576; } ];
};
users.groups.containers = { };
```

Podman validates incompatible namespace combinations at build time.

### Native vLLM and SGLang from prebuilt wheels

The native vLLM and SGLang backends run from upstream's prebuilt wheels with the same sandboxing as llama.cpp.
Their dev snapshots and architecture-specific builds rule out one fitting derivation, so you pin the version in a small [uv](https://docs.astral.sh/uv/) workspace and build the `package` with `mkUvEnv`, as in the [example above](#inference-backends):

```toml
# vllm-env/pyproject.toml, then run `uv lock`
[project]
name = "vllm-env"
requires-python = "==3.12.*"
dependencies = [ "vllm==0.16.2" ]
```

`mkUvEnv` builds against the lowest Python that `requires-python` admits, overridable with `python` and exposed as `passthru.python`.
It installs the wheels without a GPU or C++ toolchain and bakes the GPU driver runpath into them, while the driver itself is host state, so enable `hardware.graphics` and your vendor configuration as usual.
`models.<name>.package` overrides the backend's `package` per model, for example to run a nightly for a new architecture.

#### Runtime JIT compilers

vLLM and SGLang compile kernels at runtime through flashinfer, DeepGEMM, tilelang or `torch.compile`, which find `nvcc` through `CUDA_HOME`, `PATH` or `/usr/local/cuda`.
The CUDA wheels cannot serve as that prefix, so build one with `mkCudaHome`, listing the packages your models' JIT paths need:

```nix
services.llmhop.vllm.environment.CUDA_HOME = "${
  inputs.llmhop.legacyPackages.${pkgs.system}.mkCudaHome {
    packages = with pkgs.${config.services.llmhop.vllm.package.cudaPackagesAttr}; [
      cuda_nvcc cuda_cudart cuda_crt cccl cuda_nvrtc cuda_cuobjdump libcublas libcurand
    ];
  }
}";
```

`passthru.cudaPackagesAttr` names the `cudaPackages_*` attribute matching the `nvidia-cuda-runtime` the lock resolved, so one `uv lock` moves wheels and prefix together, and a CUDA line nixpkgs lacks fails evaluation by name.
The helper merges every output but `static` and adds the `lib64` and `lib64/stubs` paths some compilers expect.

#### GPUs other than NVIDIA

Nothing in the module is CUDA-specific, since GPU workers join the `render` and `video` groups, redirect every stack's kernel caches, and the `NCCL_*` defaults also apply to AMD's RCCL.
Only the wheels differ:

| Stack       | Native backends | Wheels                                                                                                         |
| ----------- | --------------- | -------------------------------------------------------------------------------------------------------------- |
| NVIDIA CUDA | vLLM, SGLang    | On PyPI, so a plain `vllm==<version>` pin resolves them.                                                       |
| AMD ROCm    | vLLM            | Per ROCm release at `https://wheels.vllm.ai/rocm/<version>/<rocm>`, while SGLang's are still landing upstream. |
| Intel XPU   | vLLM            | Per release at `https://wheels.vllm.ai/<version>/xpu`, plus torch's own XPU index.                             |

Add the index as an explicit `[[tool.uv.index]]` that `[tool.uv.sources]` selects for `vllm`, taking the current URL from vLLM's [installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/), and for XPU also `https://download.pytorch.org/whl/xpu` with `index-strategy = "unsafe-best-match"` under `[tool.uv]`.
These wheels bundle a matched torch, so the host only contributes the kernel driver, and `venvDriverLibs` already covers each stack's userspace driver.

#### Missing build systems

Dependencies without a wheel are built from sdists, where pre-PEP-517 projects fail with `No module named 'setuptools'` or `The build backend returned an error`.
Declare their build dependencies in the workspace, keyed by the name in `uv.lock`, and re-run `uv lock`:

```toml
# SGLang reaches antlr4 through omegaconf.
[tool.uv.extra-build-dependencies]
antlr4-python3-runtime = ["setuptools"]
```

#### Versions upstream leaves unconstrained

`flashinfer-cubin` and `flashinfer-jit-cache` must match the `flashinfer-python` that vLLM pins by hand, or flashinfer refuses to start.
Pin all three, so the next `uv lock` after vLLM moves its pin fails to resolve instead of producing an environment that dies on the GPU host:

```toml
dependencies = [
  "vllm==0.30.0",
  "flashinfer-python==0.6.18",
  "flashinfer-cubin==0.6.18",
  "flashinfer-jit-cache==0.6.18",
]
```

#### Missing native libraries

Wheels are built for manylinux and expect a distro underneath, so each workspace supplies the libraries its lock needs through `buildInputs` and `runtimePaths`, which have no defaults and are merged into every wheel but pure `-any` ones.
`nativeBuildInputs` adds build-time tooling an sdist needs beyond its Python build backend.

`buildInputs` covers libraries a wheel links in a `DT_NEEDED` entry, added to the autoPatchelf search path, so listing an unneeded one is harmless.
The assembled environment fails to build naming every entry still unresolved, so a version bump or a soname change in nixpkgs surfaces immediately, and each entry goes into one of three arguments:

```nix
# Libraries nixpkgs supplies.
buildInputs = [
  pkgs.ffmpeg_8-headless # torchcodec supports FFmpeg 4 to 8, not the default 9
  pkgs.tbb_2022          # numba needs libtbb.so.12, plain `tbb` is too old
];
# Sonames only the host provides at runtime. Replaces the default, the userspace driver of NVIDIA, ROCm and XPU.
venvDriverLibs = [ "libcuda.so*" "libnvidia-*.so*" ];
# Globs relative to the environment root of libraries that load on demand only.
venvOptionalLibs = [
  "*/torchcodec/libtorchcodec_*[!8].so"    # variants for the FFmpeg majors not supplied
  "*/nvshmem_bootstrap_mpi.so.3"           # nvshmem plugins for an MPI launcher
];
```

Wheels tagged for any platform skip the ELF fixups, since patching the thousands of cubins in `flashinfer-cubin` would dominate the build.
One that ships host code all the same fails the build by name, and `hostWheels = [ "some-wheel" ];` restores its fixups.

`runtimePaths` covers libraries reached by a bare `dlopen("libfoo.so")` from Python through cffi or ctypes, such as `"${pkgs.lib.getLib pkgs.libsndfile}/lib"` for `soundfile`.
Nothing in the ELF announces them, so the build succeeds and only the import fails, as in `OSError: cannot load library 'libsndfile.so'`.
Import the modules you need once after a version bump.
Entries are appended to the runpath of every wheel, since the `dlopen` usually comes from another package than the traceback names, such as cffi's `_cffi_backend` for `soundfile`.
NCCL loads `libibverbs` the same way and silently falls back to TCP without it, so multi-node workspaces need `rdma-core` in `runtimePaths`, and in `buildInputs` for nvshmem and cuFile.

### Inference server credentials

Credentials are granted per model, never inherited from a backend, so a compromised worker cannot read another model's keys.
`credentials.<name>` maps a name to a file outside the Nix store, or to `null` to import it from the system credential store, and `${cred:name}` in `settings` or `environment` expands to the read-only credential path, while unknown references fail evaluation:

```nix
services.llmhop.llama-cpp.models."qwen3-8b" = {
  model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  credentials = {
    # A file, loaded with `LoadCredential=`.
    api-keys = "/run/secrets/qwen-api-keys";
    # The credential of this name in the system credential store, imported with `ImportCredential=`.
    "llmhop.hf-token" = null;
  };
  settings.api-key-file = "\${cred:api-keys}";
};
```

Imported credentials come from `/etc/credstore`, `/etc/credstore.encrypted` and the other credential store directories, or from those passed to the system.
The store is shared by every service, so prefix names with their service, and provision one as a root-only file, or encrypted with the host key and TPM under the same `--name`:

```sh
(umask 077; systemd-ask-password -n > /etc/credstore/llmhop.hf-token)
systemd-ask-password -n | systemd-creds encrypt --name=llmhop.hf-token - /etc/credstore.encrypted/llmhop.hf-token
```

Containers get only their unit's credential directory, mounted at `/run/llmhop/credentials` and readable by root inside the container, rootful or mapped.
For another `User=`, the user namespace must map the unit owner to that UID, since the module never weakens credential modes, or an idmapped mount must, as in `mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ]`.

vLLM and SGLang take a per-model YAML file through the setting `config`, as in `credentials."config.yaml" = "/run/secrets/qwen-vllm.yaml"` with `settings.config = "\${cred:config.yaml}"`, where the credential name carries the `.yaml` extension vLLM requires.
llama.cpp has no general config file, so use file-taking settings such as `api-key-file`, `ssl-key-file` and `ssl-cert-file`.
Literal values such as `settings.api-key = "development-only"` still work, but enter the world-readable Nix store.

### vLLM watermarking

vLLM ships watermark generation and detection primitives, but its OpenAI server exposes no detector.
Both vLLM modules can watermark a model's output and run detector servers next to their workers.
A `watermark` holds vLLM's `WatermarkConfig` fields without the key, plus the `credential` holding the key, `vllm.watermark-key` by default.
A detector tests every one of its `profiles`, each the tokenizer, revision and `watermark` of a generation configuration:

```nix
services.llmhop.vllm = {
  models.qwen = {
    model = "Qwen/Qwen3-8B";
    revision = "main";
    watermark = {
      algorithm = "dual_key_gumbel";
      credential = "vllm.watermark-key.2026-10";
    };
  };
  detectors.production = {
    profiles.qwen = {
      tokenizer = "Qwen/Qwen3-8B";
      inherit (config.services.llmhop.vllm.models.qwen) revision watermark;
    };
    settings.p-value-threshold = 0.01;
  };
};
```

Each key is an unsigned 64-bit integer credential, imported from the system credential store, or given per service as a file in `credentials`:

```sh
(umask 077; od -An -N8 -tu8 /dev/urandom | tr -d ' \n' > /etc/credstore/vllm.watermark-key.2026-10)
```

The key never enters the Nix store, the command line or the journal, and a `key` in a `watermark` or in `settings.watermark-config` fails evaluation.
Both sides validate the configuration with vLLM's own `WatermarkConfig`, so a typo fails at startup rather than changing the watermark.
Speculative decoding needs `dual_key_gumbel`, or `allow_target_only_watermarking = true` for the others.
`p-value-threshold` is the only detection-side setting, while every profile must match its generation side, including the tokenizer revision.

A detector encodes the text once per tokenizer and revision and tests it against every profile.
It responds with the most significant profile, its `p_value` Bonferroni-corrected by the number of profiles as vLLM recommends, and `is_watermarked` decided on that corrected value.
Every profile therefore weakens detection a little, so keep only those whose text still needs checking.

To rotate a key, provision it under a new credential name and point the model's `watermark.credential` to it, which restarts the worker.
Keep a profile with the old credential to detect text generated before the rotation, unless the key is compromised, since anyone holding it can forge the watermark.
Replacing the contents of a credential under the same name restarts nothing.
Each detector is a `vllm-<name>` service, named like a model, serving `POST /detect` with readiness from `GET /health`, and receives no GPU in Quadlet mode.
A detector's `script` replaces the default server with your own, which receives the same flags after `detect`.
Watermarking requires a vLLM revision with `vllm.v1.watermarking`, which no release before 0.30.0 has.

#### Routing detectors through llmhop

The llmhop gateway routes detectors as `unlisted`, so clients reach them under its address and bearer tokens, while every other gateway leaves them to direct clients.
The attribute name is the routing key, shared with every backend's model names, which [path routing](#path-routing) selects:

```sh
curl https://llmhop.example.com/route/production/detect \
  -H "Authorization: Bearer $LLMHOP_TOKEN" \
  -d '{"text":"candidate text"}'
```

The response contains `score`, `p_value`, `num_scored_tokens` and `is_watermarked` like vLLM's example detector, plus the name of the matching `profile`.
A detector given a `port` is unauthenticated there, like any worker on a port.
SGLang and llama.cpp output is only detectable if they implement the same algorithm and parameters.

### llmhop credentials

The generated config lives in the world-readable Nix store, so reference secrets in `services.llmhop.gateway.builtin.settings` as [`${cred:...}`](#secret-references) and provide them through `credentials`, which takes the same [files and imports](#inference-server-credentials) as the model backends, such as [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) outputs.
`${env:...}` reads variables the unit inherits, for example from `systemd.services.llmhop.serviceConfig.EnvironmentFile`, for tooling that only produces environment files.
