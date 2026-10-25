# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop peeks at the `model` field of an incoming OpenAI-compatible request and reverse-proxies it to the matching backend.
It is built for single-model inference servers like [vLLM](https://github.com/vllm-project/vllm) and [sglang](https://github.com/sgl-project/sglang) that need a thin model-aware gateway, but it works with any OpenAI-compatible backend, including multi-model servers and hosted providers.

## Features

- Model-aware reverse proxy for any OpenAI-compatible backend, self-hosted or remote: vLLM, sglang, TabbyAPI, Aphrodite, Ollama, LocalAI, OpenRouter, together.ai, DeepInfra, etc.
- Path-based routing under `/route/{model}/`, a models API served from the config, and an unauthenticated `/health` with `sd_notify` readiness.
- Stateless single binary in pure Go with no third-party packages and no CGO, safe behind any load balancer.
- Ships as a static binary, a minimal Docker image and a hardened NixOS module that can also run llama.cpp, sglang or vLLM workers alongside the router.

## How it works

LLMhop reads the `model` field of the JSON request body, looks it up in its config, and forwards the request verbatim to the configured backend.
Unknown models return `404`, while invalid JSON and a missing or non-string `model` return `400`.
`GET /v1/models` and `GET /v1/models/{model}` are answered by LLMhop itself, never proxied, so the catalog reflects exactly what clients may ask for.
When `authTokens` is set, all routes except `/health` require a valid bearer token.

### Path routing

A request under `/route/{model}/` selects its backend by path instead of body.
LLMhop strips the `/route/{model}` prefix and forwards the rest unchanged, so `POST /route/production/detect` reaches the `production` backend as `POST /detect`.
The body is never parsed, so it need not be JSON or carry a `model` field.
Unknown models return `404`, and authentication, request limits, header injection and unix socket upstreams apply as for body routing.
A model name containing `/` is written as `%2F`, as in `/route/Qwen%2FQwen3-8B/v1/chat/completions`.

```sh
curl $LLMHOP/route/production/detect -d '{"text": "..."}'
```

A backend marked `"unlisted": true` is routed like any other but left out of both model endpoints.
That suits services that are not inference models, such as the [watermark detector](#routing-detectors-through-llmhop), which still get LLMhop's listener, bearer tokens and header injection.

### Health

`GET /health` never requires a token and returns the number of models that `GET /v1/models` advertises, so a check can assert that the proxy came up with the expected catalog:

```json
{ "status": "ok", "models": 3 }
```

LLMhop sends `READY=1` only after the listener is bound, so its `Type=notify` NixOS unit stays `activating` until requests are served.

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
    "llama-3-8b": { "url": "http://localhost:30000" },
    "qwen3-8b": { "url": "unix:///run/llmhop/vllm-qwen3-8b/http.sock" },
    "openai-gpt-4o": {
      "url": "https://api.openai.com",
      "headers": { "Authorization": "Bearer ${cred:openai-key}" }
    }
  }
}
```

`host` defaults to every interface and `port` to `8080`.
IPv6 literals are written plain (`"host": "::1"`).
A model `url` is an absolute `http(s)` URL or `unix:///<socket path>`, which carries no path prefix, so requests go to the root of the server on that socket.
`"unlisted": true` keeps a model routable while hiding it from both model endpoints.

### Secret references

String values in `authTokens` and `models.*.headers` are expanded at startup, so no plaintext secret has to live in the config file:

- `${cred:name}`: the systemd credential `name` from `$CREDENTIALS_DIRECTORY`.
  The NixOS module uses the same reference for the model backends, which receive the credential's path because they open the file themselves, while llmhop receives its contents.
- `${env:NAME}`: the `NAME` environment variable.
- `${file:/absolute/path}`: a file at an absolute path.
- `$$`: a literal `$`, so `$${env:NAME}` stays as written, while a bare `$NAME` is rejected.

A single trailing newline is trimmed from a file's contents.
Unresolved references are a hard startup error.

### Validation

Unknown keys are rejected, so a misspelled `maxBodyBytes` fails loudly instead of silently falling back to its default.
`--check` runs the full startup path and exits without binding a port:

```sh
llmhop --check --config config.json
```

It leaves secret references unexpanded, so a config can be validated where they do not resolve, such as in CI or a Nix build.

### Request limits

Body-routed requests are buffered in memory to read the `model` field, while path-routed ones are streamed.
Either way, bodies above 100 MiB are rejected with `413`, a declared `Content-Length` above the cap before reading.
At most 8 proxied requests run at once, and further ones get `503` immediately.
`0` disables a limit:

```json
{ "maxBodyBytes": 524288000, "maxConcurrentRequests": 4 }
```

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
  enable = true;
  port = 8080;
  openFirewall = true;
  settings.models = {
    "llama-3-8b".url = "http://localhost:30000";
    "qwen-2.5-7b".url = "http://localhost:30001";
  };
};
```

The unit runs as the `llmhop` system user with aggressive sandboxing and restarts on failure.
The design rationale of the module is collected in the [module internals](https://mirkolenz.github.io/llmhop/internals.html).
The module and the binary are coupled in these places:

- Every listener is a `llmhop-<name>.socket` unit handed over through socket activation, so llmhop binds nothing itself and runs with `SocketBindDeny=any`.
  The top-level `port`, `host`, `socket`, `socketUser`, `socketGroup` and `socketMode` options define the `default` listener, and each entry of `listen` adds another with the same options.
- A listener with a `port` binds `host:port`, with `host` an IP literal and `8080` as the `default` port, and `openFirewall` opens it.
  The port joins the global port registry of the inference backends, so a model reusing it fails evaluation.
- A listener without a `port` is a unix socket at `socket`, `<socketDirectory>/<name>.sock` by default, with the given owner and mode and removed on stop, so `listen.caddy.socketGroup = "caddy"` grants Caddy access.
  TCP and socket listeners combine freely.
- The generated config is validated at build time with `llmhop -check`, so a typo fails `nixos-rebuild` rather than the service and the schema lives only in the Go `Config` struct.
  Cross-compiled deployments skip this check.
- `llmhop-notify` prefixes every native model server, polls its `/health` and reports readiness, so worker units are `Type=notify` too.
  It exits with the server's status, so a model that dies while loading fails its unit immediately.

`nixosModules.default` ships the proxy and the native backends without depending on quadlet-nix, so it also works with [system-manager](https://github.com/numtide/system-manager).
`nixosModules.quadlet` includes it and adds the container variants `llama-cpp-quadlet`, `vllm-quadlet` and `sglang-quadlet`.

### Inference backends

Each backend exposes a `models` attrset under `services.llmhop.<backend>`, and every entry becomes an isolated worker on a unix socket or loopback port, registered with llmhop automatically.
All backends can be enabled side by side, but a backend's native and container variants emit the same units, so enable at most one of them.
See the [options reference](https://mirkolenz.github.io/llmhop/) for every option.

```nix
services.llmhop = {
  enable = true;
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

Native workers are hardened system units running as the backend's `user` and `group`, named after the backend by default, optionally pinned with `uid` and `gid`, and declared by the module while they keep their default names.
llama.cpp comes from nixpkgs, vLLM and SGLang from [prebuilt wheels](#native-vllm-and-sglang-from-prebuilt-wheels).
Manage them with `systemctl status <backend>-<model>` and `journalctl -u <backend>-<model>`.
The container variants run through [quadlet-nix](https://github.com/mirkolenz/quadlet-nix), rootful by default or rootless with [`quadlet.user`](#quadlet-execution-and-user-namespaces).
Manage them with `quadletctl`, which finds the manager of each unit, as in `quadletctl systemctl status <unit>`, `quadletctl journalctl <unit> -f`, `quadletctl podman <unit> ps`, `quadletctl list` and `quadletctl shell <unit>`.

A worker stays `activating` until its server answers `/health`, through `llmhop-notify` natively and `Notify=healthy` in a container, with an hour of `TimeoutStartSec` for loading.
With `startupOrdering`, on by default, workers therefore boot one at a time in ascending `name` order, so two models sharing a GPU do not race into an OOM while profiling memory.
Model servers restart with `Restart=always`.

#### Listeners

llama.cpp and vLLM models and native watermark detectors default to `port = null`, which binds `<socketDirectory>/<unit>/http.sock`, exposed as the read-only `socket` option.
`services.llmhop.socketDirectory` defaults to `/run/llmhop`, shared with llmhop's own socket listeners, and must stay below `/run`.
Only llmhop and the backend's own workers can connect, through the backend's `group` that llmhop joins via `services.llmhop.supplementaryGroups`, or through a default ACL for `services.llmhop.user` on Quadlet sockets.
Set `port` to bind `127.0.0.1:<port>` instead, for example to reach a worker without llmhop.
SGLang has no socket support upstream, so its models need a `port`.

Containers see their socket directory at `/run/llmhop/socket`, mounted with Podman's `U` option, so sockets work with any `User=` and `UserNS=`.
`quadlet.mountOptions.socket` replaces those options, for example with `[ "U" "z" ]` on SELinux hosts.

#### Fetching and offline servers

Every model runs as two units, the fetcher `<backend>-<model>-fetch`, which downloads everything the server loads, and the offline server `<backend>-<model>`.
The fetcher runs before its server and stays active, like an image unit, so a restarted server does not fetch again.
A failed download keeps what the cache holds, as `Policy=newer` keeps a local image.
Fetchers use `hf download` from the backend's package or image, or `llama download`, which resolves quantization tags, split files and the mmproj as `llama-server` would.
A `model` that is an absolute path is served as is without a fetcher.

```nix
services.llmhop.vllm.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  # Branch, tag or commit, `null` follows the default branch.
  revision = "main";
  # Repositories referenced in `settings`, which the offline server cannot download.
  extraModels = [ "Qwen/Qwen3-0.6B" ];
  settings.speculative-config = {
    model = "Qwen/Qwen3-0.6B";
    num_speculative_tokens = 4;
  };
};
```

Only the fetchers get the backend's `fetch` credentials and environment, such as a token for gated repositories or a proxy:

```nix
services.llmhop.vllm.fetch = {
  credentials."llmhop.hf-token" = { };
  environment.HF_TOKEN_PATH = "\${cred:llmhop.hf-token}";
};
```

llama.cpp reads no token file, so pass `HF_TOKEN` through `fetch.environmentFile`.

Servers get `HF_HUB_OFFLINE`, llama.cpp also `--offline`, and native servers have no DNS resolver.
On its default unix socket, a server runs without any network, natively in a network namespace of its own and in a container with `Network=none`.
A native server on a `port` can only reach `127.0.0.1` and `::1`, while a container on a `port` stays in Podman's default network, which publishes the port on loopback, so prefer the socket.
Set `offline = false` on a model or detector that needs network access, which lifts all of these restrictions for that server alone.

Native and container units share this layout, with containers mounting each directory at its host path:

| Path                                                 | Contents                                                               |
| ---------------------------------------------------- | ---------------------------------------------------------------------- |
| `cache.directory`, `/var/cache/<backend>` by default | `HF_HOME` of fetchers and servers, with the models in `hub/`           |
| `/var/cache/<backend>-<model>`                       | compile and runtime caches of one server, removed by `systemctl clean` |
| `/var/lib/<backend>-<model>`                         | state of one native server, removed by `systemctl clean`               |
| `<socketDirectory>/<backend>-<model>/http.sock`      | the socket of one server                                               |

systemd-tmpfiles creates `cache.directory`, which fetchers write and servers only read, in containers through a read-only mount.
Point it at a data disk for large models, and use the standard `hf cache` tooling on it.

`<backend>-update`, the counterpart of `podman auto-update` for models, restarts every fetcher of its backend on the `fetch.interval` schedule, daily by default.
A fetcher restarts its server when the downloaded revision changed, and starts it if it failed, such as after a first boot without network.
With `fetch.prune = true`, the update then deletes every repository and revision that no enabled workload references, so the cache must belong to that backend alone.
llama.cpp keeps every downloaded quantization of a referenced repository.

Containers do not pull either.
Each distinct image, the backend's `image` at a model's `tag` or `digest`, gets a Quadlet image unit `<backend>-<tag>-image` that pulls with `Policy=newer`, while servers and fetchers reference it with `Pull=never`.
A server tracking a tag is labeled `AutoUpdate=registry`, so enable Podman's `podman-auto-update` timer to update, restart and prune, as described in [quadlet-nix](https://github.com/mirkolenz/quadlet-nix#updates-and-pruning).

Features that download at runtime need another source:

- vLLM and SGLang need `flashinfer-cubin` in their uv workspace, which the official images ship.
- SGLang's native fetchers also download the flash-attention kernels its images ship, `kernels-community/sgl-flash-attn3` at the revision SGLang loads.
- Remote code whose `auto_map` points to another repository, and a draft model, LoRA adapter or tokenizer referenced in `settings`, belong in `extraModels`.
- Media URLs in requests cannot be fetched, so send media inline or set `offline = false`.

#### Settings rendering

`modelSettings` and `settings` are rendered into the server's CLI flags, as explained in the [internals](https://mirkolenz.github.io/llmhop/internals.html#cli-dialects).
Strings and paths are passed verbatim and everything else as JSON, so `0.6` stays `0.6` and an attribute set becomes the JSON object that options like vLLM's `--speculative-config` parse.

- `true` becomes `--<key>`, while `null` and empty lists are dropped.
- llama.cpp and vLLM render `false` as `--no-<key>`.
  A flag without such a twin, such as an on-only or `on|off|auto` one, has to be omitted or given its value instead.
- SGLang drops `false`, so write the negated key, as in `disable-radix-cache = true;`.
- vLLM and SGLang pass a list to one flag (`--<key> a b`), so the few options expecting a repeated flag need one value at a time.
- llama.cpp repeats the flag per element (`--<key> a --<key> b`).

#### Quadlet execution and user namespaces

Without `quadlet.user`, quadlet-nix installs system units and Podman runs rootfully:

```nix
services.llmhop = {
  vllm-quadlet = {
    enable = true;
    tag = "latest";
    models."qwen3-8b".model = "Qwen/Qwen3-8B";
  };
  # llama.cpp selects one of the upstream server image variants.
  llama-cpp-quadlet = {
    enable = true;
    tag = "server-cuda";
    models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  };
};
```

A positive `quadlet.user.uid` runs the units rootless under a dedicated user, which llmhop creates with its group, home, linger and NixOS-allocated subordinate IDs.
This also avoids [NVIDIA/nvidia-container-toolkit#648](https://github.com/NVIDIA/nvidia-container-toolkit/issues/648), where `nvidia-cdi-hook` fails to read the OCI bundle in some UID-mapped namespaces.
Every account detail is configurable, and `manage = false` selects an existing account without changing it:

```nix
services.llmhop.vllm-quadlet.quadlet.user = {
  name = "inference";
  uid = 503;
  group = "inference";
  gid = 503;
  home = "/var/lib/inference";
};
```

To pick the subordinate ID ranges yourself, set `users.users.<name>.subUidRanges` and `subGidRanges` with `autoSubUidGidRange = false`.

Native Quadlet sections exist at backend level and per model, where model settings override individual keys:

```nix
services.llmhop.vllm-quadlet = {
  quadlet.containerConfig = {
    User = "1000";
    UserNS = "auto:size=65536";
  };
  models."qwen3-8b".quadlet.containerConfig.GroupAdd = [ "keep-groups" ];
  # Cache ownership depends on the selected mapping.
  cache = {
    user = "100000";
    group = "100000";
    mountOptions = [ "idmap" ];
  };
};
```

`containerConfig` accepts every [upstream `[Container]` key](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html#container-units-container), and `serviceConfig`, `unitConfig`, `quadletConfig` and `extraConfig` are the systemd and Quadlet escape hatches.
The SGLang gateway has the same options under `gateway.quadlet`.
A fetcher takes only the identity keys (`User`, `Group`, `GroupAdd`, `UserNS` and the ID maps) of these overrides, so it sees the cache as its server does.
Set `cache.manage = false` when another module owns the host directory.
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

`services.llmhop.sglang` works the same, launched via `python -m sglang.launch_server`.
`models.<name>.package` overrides the backend's `package` per model, for example to run a nightly for a new architecture.
`mkUvEnv` builds against the lowest Python that `requires-python` admits, overridable with `python` and exposed as `passthru.python`.
It installs the wheels without a GPU or C++ toolchain and bakes the GPU driver runpath into them.
The driver itself is host state, so enable `hardware.graphics` and your vendor configuration as usual.

#### Runtime JIT compilers

vLLM and SGLang compile kernels at runtime through flashinfer, DeepGEMM, tilelang or `torch.compile`, which find `nvcc` through `CUDA_HOME`, `PATH` or `/usr/local/cuda`.
The CUDA wheels cannot serve as that prefix, so build one with `mkCudaHome`:

```nix
services.llmhop.vllm.environment.CUDA_HOME = "${
  inputs.llmhop.legacyPackages.${pkgs.system}.mkCudaHome {
    packages = with pkgs.${config.services.llmhop.vllm.package.cudaPackagesAttr}; [
      cuda_nvcc cuda_cudart cuda_crt cccl cuda_nvrtc cuda_cuobjdump libcublas libcurand
    ];
  }
}";
```

`passthru.cudaPackagesAttr` names the `cudaPackages_*` attribute matching the `nvidia-cuda-runtime` the lock resolved, so the packages come from your `pkgs` on the CUDA line of the wheels.
One `uv lock` thus moves wheels and prefix together, and a CUDA line nixpkgs lacks fails evaluation by name.
The helper merges every output but `static` and adds the `lib64` and `lib64/stubs` paths some compilers expect.
The package list depends on which JIT paths your models take.

#### GPUs other than NVIDIA

Nothing in the module is CUDA-specific.
GPU workers join the `render` and `video` groups, redirect every stack's kernel caches into their cache directory, and the `NCCL_*` defaults also apply to AMD's RCCL.
Only the wheels differ:

| Stack       | Native backends | Wheels                                                                                                         |
| ----------- | --------------- | -------------------------------------------------------------------------------------------------------------- |
| NVIDIA CUDA | vLLM, SGLang    | On PyPI, so a plain `vllm==<version>` pin resolves them.                                                       |
| AMD ROCm    | vLLM            | Per ROCm release at `https://wheels.vllm.ai/rocm/<version>/<rocm>`, while SGLang's are still landing upstream. |
| Intel XPU   | vLLM            | Per release at `https://wheels.vllm.ai/<version>/xpu`, plus torch's own XPU index.                             |

Take the current index URLs from vLLM's [installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/).
A ROCm workspace only adds the index, whose URL repeats the version:

```toml
[project]
dependencies = [ "vllm==0.30.0" ]

[[tool.uv.index]]
name = "vllm-rocm"
url = "https://wheels.vllm.ai/rocm/0.30.0/rocm723"
explicit = true

[tool.uv.sources]
vllm = { index = "vllm-rocm" }
```

An XPU workspace uses the XPU index plus `https://download.pytorch.org/whl/xpu` for torch, with `index-strategy = "unsafe-best-match"` under `[tool.uv]`.
These wheels bundle a matched torch, so the host only contributes the kernel driver, and `venvDriverLibs` already covers each stack's userspace driver.

#### Missing build systems

Dependencies without a wheel are built from sdists, and pre-PEP-517 projects fail with `No module named 'setuptools'` or `The build backend returned an error`.
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
The assembled environment fails to build on every entry still unresolved, where a soname that any file in it carries counts as resolved:

```
mkUvEnv: unresolved library libtbb.so.12, needed by lib/python3.12/site-packages/numba/np/ufunc/tbbpool...so
mkUvEnv: supply these through `buildInputs`, list them in `venvDriverLibs` if the host provides them, or list the libraries needing them in `venvOptionalLibs` if those load on demand only.
```

Every build names what is missing, so a version bump or a soname change in nixpkgs surfaces immediately, and each entry goes into one of three arguments:

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

`runtimePaths` covers libraries reached by a bare `dlopen("libfoo.so")` from Python through cffi or ctypes.
Nothing in the ELF announces them, so the build succeeds and only the import fails, as in `OSError: cannot load library 'libsndfile.so'`.
Import the modules you need once after a version bump.
Entries are appended to the runpath of every wheel, since the `dlopen` usually comes from another package than the traceback names, such as cffi's `_cffi_backend` for `soundfile`.
NCCL loads `libibverbs` the same way and silently falls back to TCP without it, so multi-node workspaces need `rdma-core` in both places:

```nix
runtimePaths = [
  "${pkgs.lib.getLib pkgs.libsndfile}/lib"   # soundfile
  "${pkgs.lib.getLib pkgs.rdma-core}/lib"    # NCCL
];
buildInputs = [ pkgs.rdma-core ];            # nvshmem, cuFile
```

### Inference server credentials

Credentials are granted per model, never inherited from a backend, so a compromised worker cannot read another model's keys.
Assign the same value to several models to share one.
`credentials.<name>` takes one of three sources, and `${cred:name}` in `settings` or `environment` expands to the read-only credential path:

```nix
services.llmhop.llama-cpp.models."qwen3-8b" = {
  model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  credentials = {
    # A file, loaded with `LoadCredential=`.
    api-keys = "/run/secrets/qwen-api-keys";
    # An encrypted file, loaded with `LoadCredentialEncrypted=`.
    tls-key = {
      source = "/run/secrets/qwen-tls-key.cred";
      encrypted = true;
    };
    # The credential of this name in the system credential store, imported with `ImportCredential=`.
    "llmhop.hf-token" = { };
  };
  settings.api-key-file = "\${cred:api-keys}";
};
```

Sources must lie outside the world-readable Nix store, and unknown references fail evaluation.
Imported credentials come from `/etc/credstore`, `/etc/credstore.encrypted` and the other credential store directories, or from those passed to the system.
The store is shared by every service, so prefix names with their service, as in `llmhop.hf-token`.
Provision one as a root-only file, or encrypted with the host key and TPM:

```sh
(umask 077; systemd-ask-password -n > /etc/credstore/llmhop.hf-token)
systemd-ask-password -n | systemd-creds encrypt --name=llmhop.hf-token - /etc/credstore.encrypted/llmhop.hf-token
```

systemd refuses an encrypted credential under another name than the one given with `--name`.
For rootless Quadlets, the user's systemd manager must be able to read the source, and encrypted credentials need `systemd-creds encrypt --user`.

Native workers read credentials from their systemd credential directory, and containers get only their unit's directory mounted at `/run/llmhop/credentials`.
Root inside a container, rootful or mapped, can read that mount.
For another `User=`, the user namespace must map the unit owner to that UID, since the module never weakens credential modes, so add an idmapped mount otherwise:

```nix
models."qwen3-8b".quadlet.mountOptions.credentials = [ "idmap=uids=0-1000-1;gids=0-1000-1" ];
```

vLLM and SGLang take a per-model YAML file through the ordinary file-taking setting `config`, as in `credentials."config.yaml" = "/run/secrets/qwen-vllm.yaml"` with `settings.config = "\${cred:config.yaml}"`.
vLLM requires the `.yaml` or `.yml` extension, which the credential name carries into its path.

llama.cpp has no general config file, so use file-taking settings such as `api-key-file`, `ssl-key-file` and `ssl-cert-file`.
Literal values such as `settings.api-key = "development-only"` still work, but enter the world-readable Nix store.

### vLLM watermarking

vLLM ships watermark generation and detection primitives, but its OpenAI server exposes no detector.
Both vLLM modules can watermark a model's output and run detector servers next to their workers, configured by the same `watermark` option, vLLM's `WatermarkConfig` fields without the key:

```nix
services.llmhop.vllm = let
  watermark.algorithm = "dual_key_gumbel";
in {
  models.qwen = {
    model = "Qwen/Qwen3-8B";
    inherit watermark;
  };
  detectors.production = {
    tokenizer = "Qwen/Qwen3-8B";
    inherit watermark;
    settings.p-value-threshold = 0.01;
  };
};
```

The key is the unsigned 64-bit integer credential `vllm.watermark-key`, imported from the system credential store by every service with a `watermark`:

```sh
(umask 077; od -An -N8 -tu8 /dev/urandom | tr -d ' \n' > /etc/credstore/vllm.watermark-key)
```

It may also be [encrypted](#inference-server-credentials) or given per service through any credential source, as in `credentials."vllm.watermark-key" = "/run/secrets/watermark-key";`, which is also how two models use different keys.
The key never enters the Nix store, the command line or the journal, and setting `watermark-config` in `settings` or `key` in `watermark` fails evaluation.

`nix/pkgs/mkVllmWatermark` provides the `serve` command, which merges the key into the `--watermark-config` of `vllm serve` in-process, and the `detect` command.
Both validate the configuration with vLLM's own `WatermarkConfig`, so a typo fails at startup rather than changing the watermark.
Speculative decoding needs `dual_key_gumbel`, or `allow_target_only_watermarking = true` for the others.
The detector picks its class by vLLM's naming conventions, so a new upstream algorithm that follows them works unchanged, and one that does not fails loudly.
`p-value-threshold` is the only detection-side setting, while `tokenizer` and `watermark` must match the generation side.

Each detector is a `vllm-detector-<name>` service serving `POST /detect` with readiness from `GET /health`, and receives no GPU in Quadlet mode.
vLLM's example detector lacks unix sockets, a health endpoint, a file-based key and every algorithm but `gumbel`, hence the own script.
`mkVllmWatermark` under `legacyPackages` checks it against a vLLM environment at build time, so a `uv lock` that breaks it fails the native build, while containers run it unchecked with the image's interpreter and fail at startup instead.
A detector's `script` replaces it with your own server, which receives the same flags after `detect`.
Watermarking requires a vLLM revision with `vllm.v1.watermarking`, which no release before 0.30.0 has.

#### Routing detectors through llmhop

Detectors are registered with llmhop as `unlisted`, so clients reach them under llmhop's address and bearer tokens.
The attribute name is the routing key, shared with every backend's model names, and a collision fails evaluation.
Select a detector by [path routing](#path-routing):

```sh
curl https://llmhop.example.com/route/production/detect \
  -H "Authorization: Bearer $LLMHOP_TOKEN" \
  -d '{"text":"candidate text"}'
```

The response contains `score`, `p_value`, `num_scored_tokens` and `is_watermarked`.
A detector given a `port` is unauthenticated there, like any worker on a port, while only llmhop can reach its default socket.
SGLang and llama.cpp output is only detectable if they implement the same algorithm and parameters.

### llmhop credentials

The generated config lives in the world-readable Nix store, so reference secrets in `services.llmhop.settings` via [`${cred:...}`](#secret-references) and provide them through `credentials`, which takes the same [three sources](#inference-server-credentials) as the model backends.
A path can be any file outside the store, such as [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) outputs.

```nix
services.llmhop = {
  credentials = {
    "llmhop.client-token" = { };
    openai-key = "/run/secrets/openai-key";
  };
  settings = {
    authTokens = [ "\${cred:llmhop.client-token}" ];
    models."openai-gpt-4o" = {
      url = "https://api.openai.com";
      headers.Authorization = "Bearer \${cred:openai-key}";
    };
  };
};
```

`${env:...}` reads variables the unit inherits, for example from `systemd.services.llmhop.serviceConfig.EnvironmentFile`, for tooling that only produces environment files.
