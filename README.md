# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop peeks at the `model` field of an incoming OpenAI-compatible request and reverse-proxies it to the matching backend.
It is primarily designed for single-model inference servers like [vLLM](https://github.com/vllm-project/vllm) and [sglang](https://github.com/sgl-project/sglang) that serve one model per process and need a thin model-aware gateway in front of them, but it works with any OpenAI-compatible backend (including multi-model servers and hosted providers) whenever you want to consolidate several upstreams behind a single endpoint.

## Features

- OpenAI-compatible reverse proxy, model router and request dispatcher for self-hosted LLM inference.
- Native `GET /v1/models` and `GET /v1/models/{model}` endpoints served directly from the config, so clients can discover every backend behind the single endpoint.
- Stateless single-binary HTTP service: no database, no cache, no background workers, safe behind any load balancer.
- Zero external dependencies: pure Go, no third-party packages, no CGO.
- Works with any OpenAI API-compatible backend, self-hosted or remote: vLLM, sglang, TabbyAPI, Aphrodite, Ollama, LocalAI, OpenRouter, together.ai, DeepInfra, etc.
- Ships as a static binary, a minimal Docker image and a hardened NixOS module that can optionally spin up llama.cpp, sglang or vLLM workers alongside the router.

## How it works

1. Client sends a request with a JSON body containing `{"model": "..."}`.
2. LLMhop reads the `model` field and looks it up in its config.
3. The request is forwarded verbatim to the configured backend URL.
4. Unknown models return `404`.

`GET /v1/models` and `GET /v1/models/{model}` are answered by LLMhop itself from the configured models, never proxied, so the catalog reflects exactly what is routable.
Everything else is dispatched by its `model` field as above.
When `authTokens` is set, all routes (the models API included) require a valid bearer token.

## Authentication

LLMhop can optionally gate incoming requests with a list of bearer tokens and inject per-model `Authorization` (or any other) headers when forwarding to the backend.
Both sides are opt-in: leave `authTokens` and `models.*.headers` unset and headers are forwarded verbatim.

When `authTokens` is set, the router validates the incoming `Authorization: Bearer <token>` header (constant-time compare) and then strips it before forwarding, so the client-facing token never leaks upstream.
Per-model headers are applied last, so a configured `Authorization` always wins over whatever the client sent.

## Configuration

Create a `config.json`:

```json
{
  "listen": ":8080",
  "authTokens": ["${file:client_token}"],
  "models": {
    "llama-3-8b": {
      "url": "http://localhost:30000"
    },
    "openai-gpt-4o": {
      "url": "https://api.openai.com",
      "headers": {
        "Authorization": "Bearer ${env:OPENAI_KEY}"
      }
    }
  }
}
```

### Secret references

String values inside `authTokens` and `models.*.headers` are expanded at startup, so no plaintext secret ever has to live in the config file:

- `${env:NAME}`: read from the `NAME` environment variable.
- `${file:path}`: read from a file. Relative paths are resolved against `$CREDENTIALS_DIRECTORY` when set (e.g. when launched by systemd with `LoadCredential=`), otherwise against the current working directory. A single trailing newline is trimmed.
- `$NAME`: shorthand for `${env:NAME}`.

Unresolved references are a hard startup error.

### Request size limit

LLMhop buffers each request body in memory so it can peek at the `model` field before forwarding.
To keep a single request from exhausting memory, the body is capped at 100 MiB by default; bodies beyond the cap are rejected with `413 Request Entity Too Large`.
Override it when vision or other multimodal payloads need more:

```json
{ "maxBodyBytes": 524288000 }
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
              settings = {
                listen = ":8080";
                models = {
                  "llama-3-8b".url = "http://localhost:30000";
                  "qwen-2.5-7b".url = "http://localhost:30001";
                };
              };
            };
          }
        ];
      };
    };
}
```

The unit runs under `DynamicUser` with aggressive sandboxing (`ProtectSystem`, `PrivateTmp`, restricted syscalls and address families, no new privileges, ...) and restarts on failure.

The NixOS module is split into two exports.
`nixosModules.default` ships the reverse proxy and the native systemd backends (llama.cpp, and vLLM and SGLang from prebuilt wheels), with no dependency on quadlet-nix, so it stays compatible with non-NixOS deployers such as [system-manager](https://github.com/numtide/system-manager).
`nixosModules.quadlet` includes all of that and additionally provides the container variants of vLLM and SGLang, pulling in the quadlet-nix dependency they require.
Import the latter only if you need `vllm-quadlet` or `sglang-quadlet`.

### Inference backends

The module can also run the inference servers themselves, so you don't have to wire up llama.cpp, sglang or vLLM by hand.
Each backend exposes a `models` attrset under `services.llmhop.<backend>` and every entry becomes one isolated worker bound to a loopback port, with the matching route registered automatically with llmhop.
All three backends can be enabled side by side and mixed freely in the same configuration.

Every native worker stays in `activating` until its server answers `/health`, so `systemctl start <backend>-<model>` returns only once the model is actually servable rather than merely spawned.
Cold starts download weights and profile the GPU, so that wait can be long: `TimeoutStartSec` allows an hour.
The container variants get the same guarantee from their `Notify=healthy` health check.

llama.cpp runs as a native, hardened systemd system unit under `DynamicUser`, and the default `vllm` and `sglang` backends do the same from prebuilt wheels (see [below](#native-vllm-and-sglang-from-prebuilt-wheels)).
As a last resort, when the prebuilt wheels cannot be used, vLLM and SGLang can instead run as rootless Podman containers through [quadlet-nix](https://github.com/mirkolenz/quadlet-nix), via the suffixed `vllm-quadlet` and `sglang-quadlet` options.
Each Quadlet backend gets a dedicated, lingering system user (`sglang`, `vllm`) that owns its cache directory, sub-UID range and rootless container store.
The container units are installed under that user's per-UID search path and therefore run as **systemd user units**, not system units.
This is a deliberate workaround for [NVIDIA/nvidia-container-toolkit#648](https://github.com/NVIDIA/nvidia-container-toolkit/issues/648):
`nvidia-cdi-hook` runs as an OCI `createContainer` hook inside the container's user namespace and fails to read the OCI bundle's `config.json` whenever Podman uses a UID-mapped namespace (e.g., `--userns auto` or `--userns nomap`), which is the mode you end up in when systemd's system manager launches a rootless container.
Running each Quadlet unit under a real, lingering system user's systemd instance keeps Podman in the `keep-id`-style mapping where the CDI hook can read the bundle and the GPU is correctly exposed.
No worker ever runs as root.

For convenience, the module injects a tiny per-backend helper into `environment.systemPackages` whenever the backend's default user is used:

- Native workers (`llama-cpp`, `vllm`, `sglang`) are plain system units, so they are managed with the usual `systemctl status <backend>-<model>` and `journalctl -u <backend>-<model>`.
- For the container variants, `sglang-shell` and `vllm-shell` are `writeShellApplication` wrappers around `machinectl shell` that drop you into the backend user's session, where `systemctl --user`, `journalctl --user` and `podman ps` see the worker units directly. Run them with no arguments for an interactive shell, or pass a command to execute it inside the session.

```nix
services.llmhop = {
  enable = true;
  llama-cpp = {
    enable = true;
    models."qwen3-8b" = {
      port = 18001;
      settings.hf-repo = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
    };
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
    models."llama-3-8b" = {
      port = 20001;
      model = "meta-llama/Meta-Llama-3-8B-Instruct";
    };
  };
};
```

See the [options reference](https://mirkolenz.github.io/llmhop/) for the full list of per-backend options.

### Native vLLM and SGLang from prebuilt wheels

The default vLLM and SGLang backends run as native systemd units built from upstream's prebuilt CUDA wheels: no Podman, and the same `DynamicUser` hardening as the llama.cpp backend.
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
  models."llama-3-8b" = {
    model = "meta-llama/Meta-Llama-3-8B-Instruct";
    port = 20001;
  };
};
```

`mkUvEnv` installs the wheels, so no CUDA or C++ toolchain runs at build time, and patches them for NixOS by baking the GPU driver runpath into the closure.
The driver itself is host state, so enable `hardware.graphics` and your `hardware.nvidia` configuration as usual.
`services.llmhop.sglang` works identically, launched via `python -m sglang.launch_server`.

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

#### Missing native libraries

Wheels are built for manylinux and expect a distro underneath them.
Which libraries a workspace needs beyond the driver follows from what it locks, so there are no defaults: you supply them per workspace through `buildInputs` and `runtimePaths`, which are merged into every wheel.
`nativeBuildInputs` is accepted alongside them for build-time tooling an sdist needs beyond its Python build backend.

`buildInputs` covers libraries a wheel names in a `DT_NEEDED` entry.
They are added to the autoPatchelf search path, so a library only lands in the runpath of a wheel that actually links it and listing one nothing needs is harmless.
By default an unresolved entry does not fail the build, because most of them are unresolvable on purpose: the host driver, sibling wheels that only meet each other once the venv merges them, and alternative backends where one of several variants is expected to load.
To see the whole list, narrow `ignoreMissingLibs` for one build:

```nix
mkUvEnv {
  workspaceRoot = ./vllm-env;
  ignoreMissingLibs = [ ];   # accept nothing; every unresolved entry is now an error
}
```

Each error names both the library and the wheel that wants it:

```
auto-patchelf could not satisfy dependency libtbb.so.12 wanted by
  /nix/store/...-numba-0.65.0/lib/python3.12/site-packages/numba/np/ufunc/tbbpool...so
```

Triage that list, then add the ones that are genuinely missing and drop the tightened setting again:

```nix
buildInputs = [
  pkgs.ffmpeg-headless   # torchcodec, PyAV
  pkgs.tbb_2022          # numba's threading layer — plain `tbb` is too old for libtbb.so.12
  pkgs.z3.lib            # tilelang's TVM analyzer
];
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

Each model defaults to the backend's `package` but can pin its own with `models.<name>.package`, so a single model can follow a nightly build for a freshly-released architecture while the rest stay on the stable pin.

Because a unit only goes active once it is healthy, `startupOrdering` (on by default) is effective here: workers boot one at a time in ascending `port` order, each finishing its GPU-memory profiling before the next begins, which is what keeps two models sharing a device from racing into an OOM.

The container variants live under `services.llmhop.vllm-quadlet` and `sglang-quadlet`.
A backend's native (`vllm`/`sglang`) and container (`vllm-quadlet`/`sglang-quadlet`) variants emit the same `vllm-<model>` and `sglang-<model>` units and are therefore mutually exclusive, so enable at most one per backend.

### Secrets

The generated config file lives in the world-readable Nix store, so secrets should never be placed in `services.llmhop.settings` directly.
Instead, reference them via `${file:...}` and hand the files to the service with systemd's `LoadCredential=`.
The right-hand side of each `LoadCredential` entry is just a file path, so anything that produces a file works: [agenix](https://github.com/ryantm/agenix) or [sops-nix](https://github.com/Mic92/sops-nix) outputs, a manually-managed file under `/etc/llmhop/`, or a path emitted by your own secret-provisioning tool.

```nix
services.llmhop.settings = {
  authTokens = [ "\${file:client_token}" ];
  models."openai-gpt-4o" = {
    url = "https://api.openai.com";
    headers.Authorization = "Bearer \${env:OPENAI_KEY}";
  };
};

systemd.services.llmhop.serviceConfig = {
  LoadCredential = [ "client_token:/etc/llmhop/client-token" ];
  EnvironmentFile = [ "/etc/llmhop/openai.env" ];
};
```

`/etc/llmhop/openai.env` is a plain `KEY=VALUE` file:

```env
OPENAI_KEY=sk-...
```

`${file:...}` references are resolved against `$CREDENTIALS_DIRECTORY`, which systemd exposes as a per-unit tmpfs accessible only to this service, compatible with `DynamicUser` and the rest of the sandbox.
`${env:...}` picks up anything the unit inherits, typically via `EnvironmentFile=`.
Pick whichever matches how your secret tooling hands you the data; mixing both in one config is fine.
