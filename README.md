# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop peeks at the `model` field of an incoming OpenAI-compatible request and reverse-proxies it to the matching backend.
It is primarily designed for single-model inference servers like [vLLM](https://github.com/vllm-project/vllm) and [sglang](https://github.com/sgl-project/sglang) that serve one model per process and need a thin model-aware gateway in front of them, but it works with any OpenAI-compatible backend (including multi-model servers and hosted providers) whenever you want to consolidate several upstreams behind a single endpoint.

## Features

- OpenAI-compatible reverse proxy, model router and request dispatcher for self-hosted LLM inference.
- Path-based routing under `/route/{model}/` for clients and services that cannot put a `model` field into the body.
- Native `GET /v1/models` and `GET /v1/models/{model}` endpoints served directly from the config, so clients can discover every backend behind the single endpoint.
- Unauthenticated `GET /health` for load balancers and probes, plus `sd_notify` readiness so systemd reports the service as started only once the port answers.
- Stateless single-binary HTTP service: no database, no cache, no background workers, safe behind any load balancer.
- Zero external dependencies: pure Go, no third-party packages, no CGO.
- Works with any OpenAI API-compatible backend, self-hosted or remote: vLLM, sglang, TabbyAPI, Aphrodite, Ollama, LocalAI, OpenRouter, together.ai, DeepInfra, etc.
- Ships as a static binary, a minimal Docker image and a hardened NixOS module that can optionally spin up llama.cpp, sglang or vLLM workers alongside the router.

## How it works

1. Client sends a request with a JSON body containing `{"model": "..."}`.
2. LLMhop reads the `model` field and looks it up in its config.
3. The request is forwarded verbatim to the configured backend URL.
4. Unknown models return `404`.

`GET /v1/models` and `GET /v1/models/{model}` are answered by LLMhop itself from the configured models, never proxied, so the catalog reflects exactly what clients may ask for.
Everything else is dispatched by its `model` field as above, unless it is [path routed](#path-routing).
Invalid JSON request bodies return `400 Bad Request`.
Missing or non-string `model` values also return `400 Bad Request`.
When `authTokens` is set, all routes (the models API included) require a valid bearer token.

### Path routing

A request under `/route/{model}/` selects its backend by path instead of body.
LLMhop strips the `/route/{model}` prefix and forwards the rest unchanged (method, query, headers and body), so `POST /route/production/detect` reaches the `production` backend as `POST /detect`.
The body is never parsed or rewritten, so it need not be JSON or carry a `model` field.
Unknown models return `404`, and authentication, request limits, header injection and unix socket upstreams apply exactly as for body routing.
A model name containing `/` is written as `%2F`, as in `/route/Qwen%2FQwen3-8B/v1/chat/completions`.

```sh
curl $LLMHOP/route/production/detect -d '{"text": "..."}'
```

A backend marked `"unlisted": true` is routed like any other but left out of both model endpoints.
That is for services that are not inference models and should not look like one, such as the watermark detector below: they still reach clients through LLMhop's listener, bearer tokens and header injection, but never show up as something to send a completion to.

### Health

`GET /health` is served by LLMhop itself and is the one route that never requires a token, so probes and load balancers do not need a credential:

```json
{ "status": "ok", "models": 3 }
```

The model count lets a downstream check assert that the proxy came up with the catalog it expects, not merely that the process is listening.
It counts exactly what `GET /v1/models` advertises, so unlisted backends are excluded.
Under systemd the same guarantee comes for free: LLMhop sends `READY=1` only after the listener is bound, so a `Type=notify` unit stays in `activating` until requests are actually served.

## Authentication

LLMhop can optionally gate incoming requests with a list of bearer tokens and inject per-model `Authorization` (or any other) headers when forwarding to the backend.
Both sides are opt-in: leave `authTokens` and `models.*.headers` unset and headers are forwarded verbatim.

When `authTokens` is set, the router validates the incoming `Authorization: Bearer <token>` header (constant-time compare) and then strips it before forwarding, so the client-facing token never leaks upstream.
Per-model headers are applied last, so a configured `Authorization` always wins over whatever the client sent.

## Configuration

Create a `config.json`:

```json
{
  "host": "127.0.0.1",
  "port": 8080,
  "authTokens": ["${cred:llmhop.client-token}"],
  "models": {
    "llama-3-8b": {
      "url": "http://localhost:30000"
    },
    "qwen3-8b": {
      "url": "unix:///run/llmhop/vllm-qwen3-8b/http.sock"
    },
    "openai-gpt-4o": {
      "url": "https://api.openai.com",
      "headers": {
        "Authorization": "Bearer ${cred:openai-key}"
      }
    }
  }
}
```

`host` defaults to every interface and `port` to `8080`.
IPv6 literals are written plain (`"host": "::1"`) and bracketed internally.

A model `url` is either an absolute `http(s)` URL or `unix:///<socket path>`.
A socket URL carries no path prefix, so requests go to the root of the server listening on it.

Each model additionally takes `"unlisted": true`, which keeps the backend routable by name, in the body or the path, while hiding it from `GET /v1/models` and `GET /v1/models/{model}`.

### Secret references

String values inside `authTokens` and `models.*.headers` are expanded at startup, so no plaintext secret ever has to live in the config file:

- `${cred:name}`: read the systemd credential `name` from `$CREDENTIALS_DIRECTORY`, where systemd puts it.
  This is the same reference the NixOS module rewrites for the model backends, so one spelling covers every service: those servers receive the credential's path because they open the file themselves, while llmhop reads its own config and so receives its contents.
- `${env:NAME}`: read from the `NAME` environment variable.
- `${file:/absolute/path}`: read from a file llmhop is pointed at directly. The path must be absolute, since credentials are addressed by name with `${cred:name}`.
- `$$`: a literal `$`, so `$${env:NAME}` stays as written.
  A bare `$NAME` is rejected rather than read from the environment.

A single trailing newline is trimmed from a file's contents.

Unresolved references are a hard startup error.

### Validation

Unknown keys are rejected rather than ignored, so a misspelled `maxBodyBytes` fails loudly instead of silently falling back to its default, and every model `url` must be an absolute `http(s)` or `unix` URL.

`--check` runs the full startup path (parsing, validation, router construction) and exits without binding a port:

```sh
llmhop --check --config config.json
```

Secret references are left unexpanded in this mode, so a config can be validated where the referenced files and environment variables do not exist, such as a CI job or a Nix build.
The NixOS module uses exactly this to validate the generated config at build time.

### Request limits

LLMhop buffers each request body in memory so it can peek at the `model` field before forwarding.
Path-routed bodies are streamed instead, since the backend is known from the path.
To keep a single request from exhausting memory, the body is capped at 100 MiB by default, whether buffered or streamed.
Bodies beyond the cap are rejected with `413 Request Entity Too Large`.
A declared `Content-Length` above the cap is rejected before reading the body.
At most 8 proxied requests are active at once by default.
Additional requests receive `503 Service Unavailable` immediately.
Set either limit to `0` to disable it, or adjust both for larger multimodal payloads and expected concurrency:

```json
{ "maxBodyBytes": 524288000, "maxConcurrentRequests": 4 }
```

## Running

```sh
# native
llmhop --config config.json

# nix
nix run github:mirkolenz/llmhop -- --config config.json

# docker
docker run --rm -p 8080:8080 -v ./config.json:/config.json ghcr.io/mirkolenz/llmhop --config /config.json
```

## NixOS module

A hardened systemd service is provided out of the box.
Add LLMhop to your flake inputs and import the module into your system configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    llmhop = {
      url = "github:mirkolenz/llmhop";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    { nixpkgs, llmhop, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          llmhop.nixosModules.default
          {
            services.llmhop = {
              enable = true;
              port = 8080;
              openFirewall = true;
              settings.models = {
                "llama-3-8b".url = "http://localhost:30000";
                "qwen-2.5-7b".url = "http://localhost:30001";
              };
            };
          }
        ];
      };
    };
}
```

The unit runs as the `llmhop` system user with aggressive sandboxing (`ProtectSystem`, `PrivateTmp`, restricted syscalls and address families, no new privileges, ...) and restarts on failure.

The module and the binary are deliberately coupled in these places:

- Every listener is a `llmhop-<name>.socket` unit, handed to the one service through socket activation, so llmhop binds nothing itself and runs with `SocketBindDeny=any`. The top-level `port`, `host`, `socket`, `socketUser`, `socketGroup` and `socketMode` options define the `default` listener, and each entry of `listen` adds another one with the same options.
- A listener with a `port` binds `host:port`, with `host` an IP literal. The port joins the same global port registry the inference backends use, so a backend model reusing it fails evaluation instead of leaving one of the two services unable to bind, and `openFirewall` opens it. The `default` listener keeps `port = 8080` unless changed.
- A listener without a `port` is a unix socket at `socket` (default `<socketDirectory>/<name>.sock`), for a reverse proxy on the same host. systemd applies its `socketUser`, `socketGroup` and `socketMode` and removes the file on stop, so `listen.caddy.socketGroup = "caddy"` grants Caddy access. TCP and socket listeners can be combined freely.
- The generated config is validated at build time by the binary itself (`llmhop -check`), so a typo or a malformed model URL fails `nixos-rebuild` rather than the service. The schema therefore lives in exactly one place, the Go `Config` struct, instead of being mirrored in Nix. Validation is skipped when the target platform cannot be executed by the build machine (cross-compiled deployments).
- The unit is `Type=notify`, matching the binary's readiness signal, so anything ordered after `llmhop.service` can assume it serves.
- The same package ships `llmhop-notify`, which the native backends prefix to every model server's command line. None of them speak `sd_notify`, so it polls `/health` and reports readiness on their behalf, letting the worker units be `Type=notify` too. It stays the unit's main process and exits with the server's status, so a model that dies while loading fails its unit immediately instead of being waited out until `TimeoutStartSec`.

The NixOS module is split into two exports.
`nixosModules.default` ships the reverse proxy and the native systemd backends (llama.cpp, and vLLM and SGLang from prebuilt wheels), with no dependency on quadlet-nix, so it stays compatible with non-NixOS deployers such as [system-manager](https://github.com/numtide/system-manager).
`nixosModules.quadlet` includes all of that and additionally provides the container variants of llama.cpp, vLLM, and SGLang, pulling in the quadlet-nix dependency they require.
Import the latter only if you need `llama-cpp-quadlet`, `vllm-quadlet`, or `sglang-quadlet`.

### Inference backends

The module can also run the inference servers themselves, so you don't have to wire up llama.cpp, sglang or vLLM by hand.
Each backend exposes a `models` attrset under `services.llmhop.<backend>` and every entry becomes one isolated worker bound to a unix socket or a loopback port, with the matching route registered automatically with llmhop.
All three backends can be enabled side by side and mixed freely in the same configuration.

Every native worker stays in `activating` until its server answers `/health`, so `systemctl start <backend>-<model>` returns only once the model is actually servable rather than merely spawned.
Cold starts download weights and profile the GPU, so that wait can be long: `TimeoutStartSec` allows an hour.
The container variants get the same guarantee from their `Notify=healthy` health check.

llama.cpp runs as a native, hardened systemd system unit under `DynamicUser`, and the default `vllm` and `sglang` backends run the same way from prebuilt wheels, except under a dedicated system user (see [below](#native-vllm-and-sglang-from-prebuilt-wheels)).
All three engines can instead run as Podman containers through [quadlet-nix](https://github.com/mirkolenz/quadlet-nix), via the suffixed `llama-cpp-quadlet`, `vllm-quadlet`, and `sglang-quadlet` options.
They are rootful system units by default, matching Quadlet itself and requiring no host UID configuration.
Set `quadlet.user` to run them as rootless systemd user units instead.
The module can create a dedicated lingering account, or target an account managed elsewhere.

The dedicated user mode remains useful for NVIDIA systems affected by [NVIDIA/nvidia-container-toolkit#648](https://github.com/NVIDIA/nvidia-container-toolkit/issues/648).
`nvidia-cdi-hook` runs as an OCI `createContainer` hook inside the container's user namespace and can fail to read the OCI bundle's `config.json` with some UID-mapped namespaces.
Running the Quadlet under a real user's systemd manager avoids that system-manager launch path while retaining rootless Podman.

Native workers (`llama-cpp`, `vllm`, `sglang`) are plain system units, so they are managed with the usual `systemctl status <backend>-<model>` and `journalctl -u <backend>-<model>`.
The container variants are managed with the `quadletctl` command of quadlet-nix, which finds the manager of each unit on its own, whether rootful or rootless, for example `quadletctl systemctl status <backend>-<model>`, `quadletctl journalctl <backend>-<model> -f`, or `quadletctl podman <backend>-<model> ps`.
`quadletctl list` shows all units with their owner and state, and `quadletctl shell <backend>-<model>` opens a shell as the owner of a unit.

```nix
services.llmhop = {
  enable = true;
  llama-cpp = {
    enable = true;
    models."qwen3-8b".settings.hf-repo = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
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

See the [options reference](https://mirkolenz.github.io/llmhop/) for the full list of per-backend options.

#### Listeners

llama.cpp and vLLM workers, and native watermark detectors, default to `port = null`, which binds the unix socket `<socketDirectory>/<unit>/http.sock` instead of a TCP port.
`services.llmhop.socketDirectory` defaults to `/run/llmhop`, shared with llmhop's own socket listeners, and must stay below `/run`, since each backend directory is a `RuntimeDirectory=` of its unit.
Sockets claim nothing from the host's port space, and only llmhop and the backend's own workers can connect to them, instead of every local process.
Access is granted to llmhop through the backend's `group`, which it joins via `services.llmhop.supplementaryGroups`, or through a default ACL for `services.llmhop.user` on Quadlet sockets.
The read-only `socket` option of each model holds the resulting path.
Set `port` to bind `127.0.0.1:<port>` instead, for example to reach a worker without llmhop.
SGLang and Quadlet detectors have no socket support upstream, so they always take a `port`.

Containers see their socket directory at `/run/llmhop/socket`, mounted with Podman's `U` option, so sockets work with any `User=` and any `UserNS=`, `auto` included.
`quadlet.mountOptions.socket` replaces those options, for example with `[ "U" "z" ]` on SELinux hosts, beside `quadlet.mountOptions.credentials` for the credential mount.

#### Settings rendering

`modelSettings` and `settings` are rendered into the model server's own CLI flags.
Values keep their Nix type: strings, paths and store paths are passed verbatim, and anything else is serialised to JSON, so `0.6` stays `0.6` and an attribute set becomes the JSON object that options like vLLM's `--speculative-config` parse.

- `true` collapses to `--<key>`.
- `null` and empty lists are dropped.
- llama.cpp and vLLM render `false` as `--no-<key>`, because their parsers register a negated twin for every boolean. A flag with no such twin (an on-only one, or a tri-state one taking `on|off|auto`) has to be omitted or given its value explicitly rather than set to `false`.
- SGLang drops `false` instead, since its CLI pairs `--enable-X` with `--disable-X` rather than auto-negating. Write the negated key explicitly, for example `disable-radix-cache = true;`.
- vLLM and SGLang hand every element of a list to one flag (`--<key> a b`), which is what most of their multi-value options take. The few that expect a repeated flag have to be written out one value at a time.
- llama.cpp repeats the flag once per element (`--<key> a --<key> b`), all its hand-rolled parser understands.


#### Quadlet execution and user namespaces

The Quadlet backends separate the host account that invokes Podman from the identity used inside each container.
With no `quadlet.user`, quadlet-nix installs system units and Podman runs rootfully:

```nix
services.llmhop.vllm-quadlet = {
  enable = true;
  tag = "latest";
  models."qwen3-8b".model = "Qwen/Qwen3-8B";
};
```

llama.cpp uses the same interface, but selects one of the upstream server image variants and configures the model through llama-server flags:

```nix
services.llmhop.llama-cpp-quadlet = {
  enable = true;
  tag = "server-cuda";
  models."qwen3-8b".settings.hf-repo = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
};
```

To keep the previous dedicated-user layout, set a positive UID.
llmhop creates the matching system user and group, enables linger, creates its home, and asks NixOS to allocate subordinate IDs:

```nix
services.llmhop.vllm-quadlet.quadlet.user.uid = 503;
```

Every account detail remains configurable:

```nix
services.llmhop.vllm-quadlet.quadlet.user = {
  name = "inference";
  uid = 503;
  group = "inference";
  gid = 503;
  home = "/var/lib/inference";
};
```

The subordinate ID ranges are NixOS-allocated by default.
Pick them yourself through the native user options, which merge with what the module sets:

```nix
users.users.inference = {
  autoSubUidGidRange = false;
  subUidRanges = [
    {
      startUid = 300000;
      count = 65536;
    }
  ];
  subGidRanges = [
    {
      startGid = 300000;
      count = 65536;
    }
  ];
};
```

Set `manage = false` to select an existing account without changing it:

```nix
services.llmhop.vllm-quadlet.quadlet.user = {
  manage = false;
  name = "inference";
  uid = 1000;
  group = "inference";
};
```

Native Quadlet sections are exposed at backend level and on each model.
Backend settings apply to every generated container, then model settings override individual keys:

```nix
services.llmhop.vllm-quadlet = {
  quadlet.containerConfig = {
    User = "1000";
    UserNS = "auto:size=65536";
  };

  models."qwen3-8b".quadlet.containerConfig.GroupAdd = [ "keep-groups" ];
};
```

`containerConfig` accepts every [upstream `[Container]` key](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html#container-units-container), including `User`, `Group`, `GroupAdd`, `UserNS`, `UIDMap`, `GIDMap`, `SubUIDMap`, `SubGIDMap`, `PodmanArgs`, and `GlobalArgs`.
`serviceConfig`, `unitConfig`, `quadletConfig`, and `extraConfig` provide the corresponding systemd and Quadlet escape hatches.
The SGLang gateway has the same options under `gateway.quadlet`.

The Hugging Face cache mount is configured separately because host ownership depends on the selected mapping:

```nix
services.llmhop.vllm-quadlet.cache = {
  directory = "/var/cache/vllm";
  containerDirectory = "/cache/huggingface";
  user = "100000";
  group = "100000";
  mountOptions = [ "idmap" ];
};
```

Set `cache.manage = false` when another module owns the host directory.
Podman validates incompatible namespace combinations during the build, using the same generator that consumes the final unit.

### Native vLLM and SGLang from prebuilt wheels

The default vLLM and SGLang backends run as native systemd units built from upstream's prebuilt wheels: no Podman, and the same sandboxing as the llama.cpp backend.
They need a named system user rather than `DynamicUser`: the `/var/lib/private` layout `DynamicUser` implies hands the state and cache directories to the unit as noexec ID-mapped mounts, and these runtimes `dlopen` kernels they compiled into that cache.
Every native backend, like llmhop itself, runs as its `user` and `group`, which the module declares while they keep their default names.
vLLM, SGLang and llmhop default to an account named after them, optionally pinned with `uid` and `gid`.
llama.cpp defaults to `user = null`, a `DynamicUser` per worker, and runs as the named user instead once `user` is set.
vLLM and SGLang lean heavily on dev snapshots and architecture-specific builds, so there is no one-derivation-fits-all version, and you pin yours in a tiny [uv](https://docs.astral.sh/uv/) workspace and build the package with the flake's `mkUvEnv` helper.

```nix
# vllm-env/pyproject.toml — your single version knob; edit and run `uv lock` to follow upstream.
#   [project]
#   name = "vllm-env"
#   requires-python = "==3.12.*"
#   dependencies = [ "vllm==0.16.2" ]   # or a nightly via [tool.uv.sources] / [[tool.uv.index]]

services.llmhop.vllm = {
  enable = true;
  package = inputs.llmhop.legacyPackages.${pkgs.system}.mkUvEnv {
    workspaceRoot = ./vllm-env; # directory holding pyproject.toml + uv.lock
  };
  models."llama-3-8b".model = "meta-llama/Meta-Llama-3-8B-Instruct";
};
```

The interpreter follows from `requires-python`: `mkUvEnv` builds against the lowest one the lock admits, which is what uv resolved against, so nothing names a Python version twice.
Pass `python` to override that, and read the choice back from `passthru.python`.

`mkUvEnv` installs the wheels, so no GPU or C++ toolchain runs at build time, and patches them for NixOS by baking the GPU driver runpath into the closure.
The driver itself is host state, so enable `hardware.graphics` and your vendor configuration (`hardware.nvidia`, the `amdgpu` kernel driver, ...) as usual.
`services.llmhop.sglang` works identically, launched via `python -m sglang.launch_server`.

#### Runtime JIT compilers

vLLM and SGLang compile kernels while they serve, through flashinfer, DeepGEMM, tilelang or `torch.compile`.
Those compilers invoke `nvcc` themselves and look for it on `PATH` or below `/usr/local/cuda` unless `CUDA_HOME` names a prefix, and the CUDA wheels cannot be that prefix: they carry a runtime toolkit, with no `libcudart.so` namelink and no driver stub to link against.
The flake exposes `mkCudaHome` for the prefix, and the unit takes it through `environment`:

```nix
services.llmhop.vllm.environment.CUDA_HOME = "${
  inputs.llmhop.legacyPackages.${pkgs.system}.mkCudaHome {
    packages = with pkgs.${config.services.llmhop.vllm.package.cudaPackagesAttr}; [
      cuda_nvcc
      cuda_cudart
      cuda_crt
      cccl
      cuda_nvrtc
      cuda_cuobjdump
      libcublas
      libcurand
    ];
  }
}";
```

The CUDA line is not named a second time: the environment exposes `passthru.cudaPackagesAttr`, the `cudaPackages_*` attribute matching the line its own wheels were built for, taken from the `nvidia-cuda-runtime` the lock resolved.
It names an attribute rather than holding a package set, the way `python.pythonAttr` does in nixpkgs, so the packages come from your `pkgs`, with your configuration and overlays, rather than from this flake's.
One `uv lock` therefore moves the wheels and the prefix together, and a CUDA line nixpkgs has not packaged fails evaluation by name.
Components drift within a line, `libcublas` running ahead of `cuda_cudart`, so the runtime is the anchor rather than any single wheel.

The helper owns only the layout: it merges every output but `static`, since `symlinkJoin` links outputs and drops the propagation that would otherwise carry the headers, and it adds the `lib64` and `lib64/stubs` paths that some compilers link against and that only the retired runfile installer ever produced.
The package list is yours, the same way `buildInputs` is: it follows from which JIT paths your models take, and it has to stay on the CUDA line the wheels were built for.

#### GPUs other than NVIDIA

Nothing in the module is CUDA-specific.
Every GPU worker joins the `render` and `video` groups inside a `PrivateUsers = "identity"` namespace that keeps those group IDs intact, which is what opening `/dev/kfd` and `/dev/dri/renderD*` takes.
Runtime kernel caches are redirected into the unit's cache root for every stack at once, and the `NCCL_*` defaults cover AMD too, since RCCL reads the same variables.

Only the wheels differ per vendor:

| Stack | Native (uv) backends | Wheels |
| --- | --- | --- |
| NVIDIA CUDA | vLLM, SGLang | Published on PyPI, so a plain `vllm==<version>` pin resolves them. |
| AMD ROCm | vLLM | Published per ROCm release at `https://wheels.vllm.ai/rocm/<version>/<rocm>`. SGLang's are still landing upstream. |
| Intel XPU | vLLM | Published per release at `https://wheels.vllm.ai/<version>/xpu`, and they need torch's own XPU index alongside. |

The index URLs move with every release, so take them from vLLM's [installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/) rather than from here.
A non-CUDA workspace differs from a CUDA one only in where the wheel comes from:

```toml
# vllm-env/pyproject.toml — the ROCm version is part of both the pin and the index URL.
[project]
name = "vllm-env"
requires-python = "==3.12.*"
dependencies = [ "vllm==0.30.0" ]

[[tool.uv.index]]
name = "vllm-rocm"
url = "https://wheels.vllm.ai/rocm/0.30.0/rocm723"
explicit = true

[tool.uv.sources]
vllm = { index = "vllm-rocm" }
```

An XPU workspace takes the same shape with the XPU index, plus `https://download.pytorch.org/whl/xpu` for torch.
Upstream reaches that second index with `--index-strategy unsafe-best-match`, whose lockfile equivalent is `index-strategy = "unsafe-best-match"` under `[tool.uv]`.

These wheels carry a matched ROCm or oneAPI build of torch, so the host contributes only the kernel driver.
Expect a different set of missing native libraries than a CUDA workspace. The userspace driver of each stack is already in the `venvDriverLibs` default.

#### Missing build systems

Not every dependency ships a wheel.
The few that resolve to an sdist are built from source, and pre-PEP-517 projects that assume `setuptools` is simply present fail the build with `No module named 'setuptools'` or `The build backend returned an error`.
Declare what they need in the workspace rather than patching the Nix side, so uv and `mkUvEnv` read it from the same place:

```toml
# sglang-env/pyproject.toml — SGLang reaches antlr4 through omegaconf.
[tool.uv.extra-build-dependencies]
antlr4-python3-runtime = ["setuptools"]
```

Re-run `uv lock` afterwards.
The key is the package name as it appears in `uv.lock`, and the value is whatever its build backend needs (`setuptools`, `cython`, `meson-python`, ...).

#### Versions upstream leaves unconstrained

Some wheels have to move together although none of them depends on the others.
vLLM's flashinfer payloads are the recurring case: `flashinfer-cubin` and `flashinfer-jit-cache` have to match the `flashinfer-python` that vLLM pins by hand in `requirements/cuda.txt`, and flashinfer refuses to start otherwise.

Pin that package yourself, at the version the other two use, rather than leaving it to vLLM alone:

```toml
dependencies = [
  "vllm==0.30.0",
  "flashinfer-python==0.6.18",     # vLLM pins this exactly, so a bump conflicts here
  "flashinfer-cubin==0.6.18",
  "flashinfer-jit-cache==0.6.18",
]
```

The next `uv lock` after vLLM moves its pin then fails to resolve, naming both versions, instead of producing a lock that builds and dies on the GPU host.

#### Missing native libraries

Wheels are built for manylinux and expect a distro underneath them.
Which libraries a workspace needs beyond the driver follows from what it locks, so there are no defaults: you supply them per workspace through `buildInputs` and `runtimePaths`, which are merged into every wheel but pure `-any` ones.
`nativeBuildInputs` is accepted alongside them for build-time tooling an sdist needs beyond its Python build backend.

`buildInputs` covers libraries a wheel names in a `DT_NEEDED` entry.
They are added to the autoPatchelf search path, so a library only lands in the runpath of a wheel that actually links it and listing one nothing needs is harmless.
No wheel fails over an unresolved entry on its own, because in isolation it cannot see the siblings it will share a venv with: half of what a wheel misses at that point is another wheel.
The assembled environment is checked instead, where those have resolved, and every entry still unresolved there fails the build:

```
mkUvEnv: unresolved library libtbb.so.12, needed by lib/python3.12/site-packages/numba/np/ufunc/tbbpool...so
mkUvEnv: supply these through `buildInputs`, list them in `venvDriverLibs` if the host provides them, or list the libraries needing them in `venvOptionalLibs` if those load on demand only.
```

A soname that some file in the environment carries counts as resolved, even when `ldd` cannot reach it from the library that needs it.
Wheels rarely link their siblings through the runpath: torch preloads the CUDA wheels on import, and torchcodec expects torch to be loaded already, so the loader finds both by soname.
Every other entry is either a library nixpkgs should supply, which goes into `buildInputs`:

```nix
buildInputs = [
  pkgs.ffmpeg_8-headless # torchcodec supports FFmpeg 4 to 8, not the default 9
  pkgs.tbb_2022          # numba's threading layer, plain `tbb` is too old for libtbb.so.12
];
```

or a soname only the host provides at runtime, which goes into `venvDriverLibs`:

```nix
venvDriverLibs = [ "libcuda.so*" "libnvidia-*.so*" ];   # NVIDIA's userspace driver
```

`venvDriverLibs` defaults to the userspace driver of every stack vLLM publishes wheels for, NVIDIA, ROCm and XPU alike, since no build can resolve those anywhere.
Setting it replaces that default.

Or it is a dependency of a library that loads on demand only, which goes into `venvOptionalLibs` as a glob of that library's path relative to the environment root:

```nix
venvOptionalLibs = [
  "*/torchcodec/libtorchcodec_*[!8].so"    # variants for the FFmpeg majors not supplied
  "*/nvshmem_bootstrap_mpi.so.3"           # nvshmem plugins for an MPI launcher
];
```

The first build of a workspace names what it found, as does every later one the moment a wheel starts wanting something new, or nixpkgs moves a library to a soname the wheels were not built against.

Wheels tagged for any platform skip the ELF fixups, since patching the thousands of cubins in `flashinfer-cubin` would take longer than the rest of the environment.
Should one ship host code all the same, the environment fails to build and names it, and `hostWheels` gives it the fixups back:

```nix
hostWheels = [ "some-wheel" ];
```

`runtimePaths` covers the other kind, reached by a bare `dlopen("libfoo.so")` from Python via cffi or ctypes.
Nothing announces those in the ELF, so no build ever fails over one and no runpath resolves it; the environment builds cleanly and the import dies:

```
OSError: cannot load library 'libsndfile.so': cannot open shared object file
```

Only importing finds them, so run the modules you care about once after a version bump.
Entries here are appended to the runpath of every wheel rather than a chosen one, because the object issuing the `dlopen` is generally not the package that appears in the traceback — `soundfile` fails, but the call comes from cffi's `_cffi_backend`:

```nix
runtimePaths = [ "${pkgs.lib.getLib pkgs.libsndfile}/lib" ];   # soundfile, reached through cffi
```

NCCL reaches InfiniBand the same way: it `dlopen`s `libibverbs` by bare name, and when that fails it falls back to TCP sockets without an error.
A multi-node workspace therefore needs `rdma-core` here, besides `buildInputs` for the nvshmem and cuFile transports that link it:

```nix
buildInputs = [ pkgs.rdma-core ];                               # nvshmem, cuFile
runtimePaths = [ "${pkgs.lib.getLib pkgs.rdma-core}/lib" ];     # NCCL
```

Each model defaults to the backend's `package` but can pin its own with `models.<name>.package`, so a single model can follow a nightly build for a freshly-released architecture while the rest stay on the stable pin.

Because a unit only goes active once it is healthy, `startupOrdering` (on by default) is effective here: workers boot one at a time in ascending `name` order, each finishing its GPU-memory profiling before the next begins, which is what keeps two models sharing a device from racing into an OOM.

The container variants live under `services.llmhop.llama-cpp-quadlet`, `vllm-quadlet`, and `sglang-quadlet`.
A backend's native and container variants emit the same `<backend>-<model>` units and are therefore mutually exclusive, so enable at most one variant per backend.

### Inference server credentials

Credentials are granted to individual model services, never inherited from a backend.
This keeps one compromised worker from reading another model's keys.
Assign the same Nix value to multiple models when sharing is intentional.

```nix
services.llmhop.llama-cpp.models."qwen3-8b" = {
  credentials.api-keys = "/run/secrets/qwen-api-keys";
  settings = {
    hf-repo = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
    api-key-file = "\${cred:api-keys}";
  };
};
```

`credentials.<name>` takes one of three sources:

```nix
credentials = {
  # A file, loaded with `LoadCredential=`.
  api-keys = "/run/secrets/qwen-api-keys";
  # An encrypted file, loaded with `LoadCredentialEncrypted=`.
  tls-key = {
    source = "/run/secrets/qwen-tls-key.cred";
    encrypted = true;
  };
  # The credential of the same name in the system credential store, imported with `ImportCredential=`.
  "llmhop.hf-token" = { };
};
```

Sources must lie outside the Nix store, which every local user can read, so a store path fails evaluation.
An imported credential is looked up in `/etc/credstore`, `/etc/credstore.encrypted` and the other credential store directories, and among the credentials passed to the system, and decrypted as needed.
That store is shared by every service, so prefix an imported name with its service, as in `llmhop.hf-token` or `vllm.watermark-key`.
It needs no path in Nix at all, so it is the simplest way to provision a secret, as a plain file in the root-only `/etc/credstore`:

```sh
(umask 077; systemd-ask-password -n > /etc/credstore/llmhop.hf-token)
```

To keep it encrypted at rest with the host key, and the TPM if present, write it to `/etc/credstore.encrypted` instead:

```sh
systemd-ask-password -n | systemd-creds encrypt --name=llmhop.hf-token - /etc/credstore.encrypted/llmhop.hf-token
```

`systemd-creds` embeds the name into an encrypted credential, and systemd refuses to load it under any other, so encrypt with `--name=<name>`.
For rootless Quadlets, the selected user's systemd manager must be able to read the source, and its encrypted credentials must be created with `systemd-creds encrypt --user`.

`${cred:name}` expands to the read-only credential path, not its contents.
Unknown references fail evaluation.
Native workers use their systemd credential directory through the `%d` specifier.
Quadlet workers mount only that unit's credential directory at `/run/llmhop/credentials`.

vLLM and SGLang also accept a per-model YAML file through their `--config` flag.
That is an ordinary file-taking setting, so it needs no dedicated option:

```nix
services.llmhop.vllm-quadlet.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  credentials."config.yaml" = "/run/secrets/qwen-vllm.yaml";
  settings.config = "\${cred:config.yaml}";
};
```

vLLM requires the `.yaml` or `.yml` extension, which the credential name carries into its path.

llama.cpp has no general server config file, so use its file-taking settings such as `api-key-file`, `ssl-key-file`, and `ssl-cert-file` instead.

The default root user in rootful containers and the mapped root user in rootless containers can read the credential mount.
If `[Container] User=` selects another identity, its user namespace mapping must map the systemd unit owner to that container UID.
The module does not weaken credential modes to make an incompatible mapping work.
Use an idmapped credential mount when the selected namespace does not already provide that mapping:

```nix
models."qwen3-8b".quadlet.mountOptions.credentials = [
  "idmap=uids=0-1000-1;gids=0-1000-1"
];
```

Literal values remain available for non-secret development configuration:

```nix
services.llmhop.sglang.models.test.settings.api-key = "development-only";
```

Such values enter the world-readable Nix store and should not be used for production secrets.

### vLLM watermark detection

Recent vLLM revisions include watermark generation and detector primitives, but the OpenAI server does not expose the detector as an endpoint.
Both vLLM modules can run a small detector server as a named service next to their model workers.
It takes the same `watermark-config` the generating worker receives, so one attribute set configures both sides:

```nix
services.llmhop.vllm = let
  watermark-config = {
    algorithm = "gumbel";
    key = 123456789;
    context_width = 4;
  };
in {
  models.qwen = {
    model = "Qwen/Qwen3-8B";
    settings = { inherit watermark-config; };
  };
  detectors.production = {
    tokenizer = "Qwen/Qwen3-8B";
    settings = {
      inherit watermark-config;
      p-value-threshold = 0.01;
    };
  };
};
```

The server validates the configuration with vLLM's own `WatermarkConfig`, so every field and algorithm the installed release accepts is accepted here too, and a typo fails at startup rather than silently changing the key.
vLLM offers no detector factory, so the server picks the detector class and its arguments by vLLM's naming conventions.
An algorithm added upstream works without changes when it follows them, and fails loudly rather than detecting with mismatched parameters otherwise.
`p-value-threshold` is the only detection-side setting.

`tokenizer`, the key and the rest of the configuration must match the generation side.
`tokenizer` and the listener are options of their own, since llmhop owns the latter.
Each detector is a separate `vllm-detector-<name>` service serving `POST /detect`, with readiness taken from `GET /health`.
They do not receive a GPU device in Quadlet mode.

The server lives in `nix/pkgs/mkVllmDetector` rather than coming from vLLM's example, which has no unix socket support, no health endpoint, no file-based key, and covers only `gumbel`.
`mkVllmDetector`, exposed under `legacyPackages`, checks it against a vLLM environment at build time: the server must import and detect with every algorithm the release declares, so a `uv lock` that breaks the vLLM modules it relies on fails the build rather than the unit.
The native default is that checked script, run with the detector's `package`.
The Quadlet container mounts the unchecked script into the selected image and runs it with the image's interpreter, so there the same failure surfaces at startup.
`script` replaces it with a server of your own, which receives the same flags.
Both require a vLLM revision containing `vllm.v1.watermarking`, which no release before 0.30.0 has.

#### Routing detectors through llmhop

A detector binds only to a unix socket or host loopback and is registered with llmhop, so clients reach it at llmhop's own address under llmhop's bearer tokens rather than on a second, unauthenticated port.
The attribute name is the routing key, so it shares one namespace with every backend's model names and a collision fails evaluation.

Detectors are registered `unlisted`, so they never appear in `GET /v1/models`.
Select one by [path routing](#path-routing), so the body carries only the candidate text:

```sh
curl https://llmhop.example.com/route/production/detect \
  -H "Authorization: Bearer $LLMHOP_TOKEN" \
  -d '{"text":"candidate text"}'
```

The response contains `score`, `p_value`, `num_scored_tokens`, and `is_watermarked`.

This puts llmhop's authentication in front of a server that has none of its own.
A detector given a `port` is still unauthenticated there, like every model worker given one, so anything else on the host can reach it directly.
On its default socket, only llmhop can.

#### Keeping the key secret

An inline `watermark-config` enters the Nix store and the process arguments.
`watermark-config-file` instead reads the same configuration as JSON from a file, typically a credential:

```nix
services.llmhop.vllm.detectors.production = {
  tokenizer = "Qwen/Qwen3-8B";
  credentials.watermark = "/etc/llmhop/watermark.json";
  settings.watermark-config-file = "\${cred:watermark}";
};
```

The generating worker takes no such flag, but `vllm serve --config` reads a YAML file whose `watermark-config` key holds the same configuration, and it can be handed over the same way.

SGLang and llama.cpp workers can coexist with the detector, but they only produce detectable text if they implement the same watermark generation algorithm and parameters.

### llmhop credentials

The generated config file lives in the world-readable Nix store, so secrets should never be placed in `services.llmhop.settings` directly.
Instead, reference them via [`${cred:...}`](#secret-references) and hand them to llmhop through its `credentials` option, which takes the same [three sources](#inference-server-credentials) as the model backends: a path for systemd's `LoadCredential=`, an entry with `encrypted = true` for `LoadCredentialEncrypted=`, and `{ }` for `ImportCredential=` from the system credential store.
A path is any file outside the Nix store, so anything that produces one works: [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) outputs, a manually-managed file, or a path emitted by your own secret-provisioning tool.

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

`${cred:...}` references are resolved against `$CREDENTIALS_DIRECTORY`, which systemd exposes as a per-unit tmpfs accessible only to this service, compatible with `DynamicUser` and the rest of the sandbox.
`${env:...}` picks up variables the unit inherits, for example through `systemd.services.llmhop.serviceConfig.EnvironmentFile`, for secret tooling that only produces environment files.
