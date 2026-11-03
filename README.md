# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop reads the `model` field of an incoming request and reverse-proxies it to the matching backend.
It is built for single-model servers like [vLLM](https://github.com/vllm-project/vllm) and [SGLang](https://github.com/sgl-project/sglang), but works with any OpenAI-compatible backend, self-hosted or remote.

- Pure Go, no third-party packages, no CGO, stateless and safe behind any load balancer.
- Body and path routing, a models API served from the config, health and readiness endpoints, graceful draining.
- Ships as a static binary, a Docker image and a hardened NixOS module running llama.cpp, SGLang or vLLM behind llmhop, SMG, Bifrost or no gateway.

## How it works

LLMhop looks up the request's `model` in its config and forwards the request verbatim.
Unknown models return `404`, invalid JSON or a missing `model` return `400`.
`GET /v1/models` and `GET /v1/models/{model}` are answered from the config and never proxied.

A request under `/route/{model}/` is routed by path instead, with the prefix stripped and the body left unparsed, so `POST /route/production/detect` reaches `production` as `POST /detect`.
Write a `/` in a model name as `%2F`.
A model marked `"unlisted": true` is routed but left out of the models API, which suits services such as a watermark detector.

`GET /health` returns `{ "status": "ok", "models": 3 }` with the number of listed models.
`GET /readiness` probes the `health` path of every model that sets one and answers `200` only if all respond `2xx`, else `503`.
Both never require a token.
LLMhop sends `READY=1` to systemd once its listeners are bound, and drains in-flight requests on `SIGTERM` or `SIGINT`.

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
      "maxConcurrentRequests": 16
    },
    "openai-gpt-4o": {
      "url": "https://api.openai.com",
      "headers": { "Authorization": "Bearer ${cred:openai-key}" }
    }
  }
}
```

`host` defaults to every interface and `port` to `8080`.
A `url` is an absolute `http(s)` URL or `unix:///<socket path>`.
With `authTokens` set, every route but `/health` and `/readiness` requires a matching bearer token, which is stripped before forwarding.
A model's `headers` are applied last, so a configured `Authorization` replaces the client's.
Unknown keys are rejected, and `llmhop --check --config config.json` validates a config without binding a port or expanding secrets.

### Secret references

Strings in `authTokens` and `models.*.headers` are expanded at startup, and an unresolved reference is a startup error:

- `${cred:name}`: the systemd credential `name` from `$CREDENTIALS_DIRECTORY`.
- `${env:NAME}`: an environment variable.
- `${file:/absolute/path}`: a file, with trailing newlines trimmed.
- `$$`: a literal `$`.

### Request limits

- `maxBodyBytes` (100 MiB): larger bodies get `413`.
- `maxBufferedRequests` (8): body-routed requests buffered at once, further ones get `503`. A buffered body must arrive within a minute, or the request gets `408`.
- `models.*.maxConcurrentRequests` (unlimited): proxied requests per model, further ones get `503`.

`0` disables a limit.

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
  gateway.type = "llmhop";
  gateway.llmhop.listen.default.host = "";
  gateway.llmhop.openFirewall = true;
  llama-cpp.enable = true;
  llama-cpp.models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
};
```

`nixosModules.default` has the gateways and native backends and works without quadlet-nix, for example with [system-manager](https://github.com/numtide/system-manager).
`nixosModules.quadlet` adds the container variants `llama-cpp-quadlet`, `vllm-quadlet`, `sglang-quadlet`, `llmhop-quadlet`, `smg-quadlet` and `bifrost-quadlet`, which can also be [bundled](#hosts-without-nix) for hosts without Nix.
See the [options reference](https://mirkolenz.github.io/llmhop/) for every option and the [module internals](https://mirkolenz.github.io/llmhop/internals.html) for the design rationale.

### Gateways

`services.llmhop.gateway.type` selects at most one gateway, configured by the option set of the same name, which routes every model of every backend by its `name`.

| `type`                           | Gateway                                                          | Unix sockets | Detectors |
| -------------------------------- | ---------------------------------------------------------------- | ------------ | --------- |
| `null`                           | none, clients connect to each model                              |              |           |
| `"llmhop"`                       | llmhop                                                           | yes          | yes       |
| `"llmhop-quadlet"`               | llmhop                                                           | no           | yes       |
| `"smg"`, `"smg-quadlet"`         | the [Shepherd Model Gateway](https://github.com/smg-project/smg) | no           | no        |
| `"bifrost"`, `"bifrost-quadlet"` | [Bifrost](https://github.com/maximhq/bifrost)                    | no           | no        |

Routed models must stay on loopback and leave authentication to the gateway, and gateways without socket support need every model to set a `port`.
Each gateway listens on `127.0.0.1:8080` by default.

- **llmhop** runs as the `llmhop` user with one socket-activated `llmhop-<name>.socket` per entry of `listen`, as in `listen.caddy.socketGroup = "caddy"` for a unix socket, or as a container that loads an image archive of the same build, unless `image` names a registry reference such as `ghcr.io/mirkolenz/llmhop:latest`.
  Its generated config is validated at build time with `llmhop -check`.
  Reference secrets in `settings` as `${cred:name}` and grant them through `credentials`.
- **SMG** reads its workers from a generated discovery file. `settings` takes its CLI flags, where `${cred:name}` resolves to a file path, as in `settings.api-key-file = "\${cred:smg.api-key}"`, which requires an SMG build newer than v1.13.0. The native `package` is a [`mkUvEnv`](#native-vllm-and-sglang-from-prebuilt-wheels) environment.
- **Bifrost** gets every model as a key of its `vllm` provider, or `sgl` for SGLang. `settings` is its `config.json`, with secrets as `env.NAME` references loaded from `environmentFile`. The native `package` comes from Bifrost's own flake.

Without a gateway, each model serves clients on its own socket or `port`, and `socketClients` lists the users, such as a reverse proxy, that may connect to every model socket.

### Inference backends

Each backend serves the entries of its `models` as isolated workers, and all backends can run side by side:

```nix
services.llmhop = {
  llama-cpp = {
    enable = true;
    models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  };
  vllm = {
    enable = true;
    package = inputs.llmhop.legacyPackages.${pkgs.system}.mkUvEnv { workspaceRoot = ./vllm-env; };
    models."qwen3-8b" = {
      model = "Qwen/Qwen3-8B";
      port = 19001;
      settings.reasoning-parser = "qwen3";
    };
  };
  sglang-quadlet = {
    enable = true;
    image = "docker.io/lmsysorg/sglang:latest";
    models."llama-3-8b" = {
      model = "meta-llama/Meta-Llama-3-8B-Instruct";
      port = 19002;
    };
  };
};
```

Each model runs as the unit `<engine>-<name>`.
Native workers are hardened services running as the backend's `user`, while container workers run rootful through [quadlet-nix](https://github.com/mirkolenz/quadlet-nix) with the backend's `image`, managed with `quadletctl`.
A worker stays `activating` until it answers `/health`, and `startupOrdering` starts workers one at a time by `name`, so two never profile GPU memory at once.
Evaluation rejects any port, unit or model name claimed twice.
Customize the generated units directly, as in `systemd.services.vllm-qwen3-8b.serviceConfig.MemoryHigh = "64G"` or `virtualisation.quadlet.containers.vllm-qwen3-8b.containerConfig`.

llama.cpp and vLLM workers default to `port = null`, binding a unix socket below `socketDirectory` that only the backend's workers, llmhop and `socketClients` can reach.
Set `port` to bind `<host>:<port>` instead, which SGLang always needs.

#### Fetching and offline servers

Each model has a fetcher `<engine>-<name>-fetch` that downloads everything into the model's own cache `cache.directory/<name>`, after which the server runs offline from it.
A `model` that is an absolute path has no fetcher.
`extraModels` lists further repositories that `settings` reference, such as a draft model or LoRA adapter, and `revision` pins a branch, tag or commit:

```nix
services.llmhop.vllm.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  revision = "main";
  extraModels = [ "Qwen/Qwen3-0.6B" ];
  settings.speculative-config = {
    model = "Qwen/Qwen3-0.6B";
    num_speculative_tokens = 4;
  };
};
```

Only fetchers get the backend's `fetch.credentials`, `fetch.environment` and the Hugging Face token of gated repositories, which `fetch.tokenCredential = "llmhop.hf-token"` imports for every engine.
`<engine>-update` reruns every fetcher on `fetch.interval`, daily by default, prunes what the model no longer references, and restarts a server whose download changed.
An interrupted download leaves the server on its last complete one.

Servers never download: they get `HF_HUB_OFFLINE`, no DNS, and on a socket no network at all, on a native `port` only loopback.
`offline = false` lifts the network restrictions for features like media URLs in requests.
Tagged container images are labeled `AutoUpdate=registry` for `virtualisation.quadlet.autoUpdate`.

#### Settings rendering

`settings`, over the backend's `modelSettings`, becomes the server's CLI flags, while the listener and the served name always win.
Strings and paths are passed verbatim and everything else as JSON, so attribute sets work for options like `--speculative-config`.

- `true` becomes `--<key>`, while `null` and empty lists are dropped.
- llama.cpp and vLLM render `false` as `--no-<key>`, while SGLang drops it, so write the negated key, as in `disable-radix-cache = true`.
- vLLM and SGLang pass a list to one flag (`--<key> a b`), llama.cpp repeats the flag (`--<key> a --<key> b`).

#### Containers and user namespaces

Every Quadlet backend and gateway runs its containers as root by default, which a user namespace maps to an unprivileged host range.
`containerConfig` adds `[Container]` keys to every container of a backend, servers, fetchers and detectors alike, or of a gateway, and idmapped mounts let the namespace own the cache and read the credentials:

```nix
services.llmhop = {
  vllm-quadlet = {
    containerConfig.UserNS = "auto:size=65536";
    mountOptions = {
      cache = [ "idmap" ];
      credentials = [ "idmap" ];
    };
  };
  gateway.llmhop-quadlet = {
    containerConfig.UserNS = "auto";
    mountOptions.credentials = [ "idmap" ];
  };
};
```

`UIDMap=` and `GIDMap=` work the same way in place of `UserNS=`.
A non-root `User=` inside the namespace takes the mapping `idmap=uids=0-<uid>-1;gids=0-<gid>-1` in both lists, so the cache stays owned by host root.
Only a cache on a filesystem without idmapped mounts, such as NFS, needs `cache.user` and `cache.group` set to the host IDs that an explicit `UIDMap=` and `GIDMap=` give the container user.
Rootful `UserNS=auto` needs subordinate IDs for a `containers` user, which NixOS does not declare.

#### Hosts without Nix

The Quadlet backends and gateways can be rendered into plain files for any host with podman 5, systemd and python3, such as Ubuntu 25.04:

```nix
packages.x86_64-linux.llmhop-bundle = inputs.llmhop.legacyPackages.x86_64-linux.mkQuadletBundle {
  modules = [
    {
      services.llmhop = {
        gateway.type = "llmhop-quadlet";
        vllm-quadlet = {
          enable = true;
          image = "docker.io/vllm/vllm-openai:latest";
          models."qwen3-8b" = {
            model = "Qwen/Qwen3-8B";
            port = 8001;
          };
        };
      };
    }
  ];
};
```

A NixOS system importing `nixosModules.quadlet` exposes the same as `services.llmhop.bundle.package`.
The bundle holds the Quadlet files, update timers and tmpfiles rules below `etc/`, the scripts and generated configs below `bundle.assetDirectory`, `/usr/local/lib/llmhop` by default, and an `install.sh` that copies them into place, starts the servers and restarts every running unit it changed.
Native backends and gateways cannot be bundled, and firewall and user options have no effect there.

### Native vLLM and SGLang from prebuilt wheels

Native vLLM and SGLang run from upstream's wheels, pinned in a small [uv](https://docs.astral.sh/uv/) workspace and built with `mkUvEnv`:

```toml
# vllm-env/pyproject.toml, then run `uv lock`
[project]
name = "vllm-env"
requires-python = "==3.12.*"
dependencies = [ "vllm==0.16.2" ]
```

`mkUvEnv` builds against the lowest admitted Python and bakes the GPU driver runpath into the wheels, while the driver itself comes from `hardware.graphics` and your vendor configuration.
`models.<name>.package` overrides the `package` per model, for example with a nightly.

- **JIT compilers** find `nvcc` through `CUDA_HOME`, which `mkCudaHome { packages = [ ... ]; }` builds from the `cudaPackages_*` set named by the environment's `passthru.cudaPackagesAttr`.
- **AMD and Intel GPUs** work with vLLM's ROCm or XPU wheels, added as an explicit `[[tool.uv.index]]` per vLLM's [installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/).
- **sdists without a build system** need their build dependencies under `[tool.uv.extra-build-dependencies]`, as in `antlr4-python3-runtime = ["setuptools"]`.
- **flashinfer** packages must be pinned to the `flashinfer-python` version vLLM pins, or flashinfer refuses to start.
- **Native libraries** come from `buildInputs` for linked ones, `runtimePaths` for ones loaded by a bare `dlopen`, such as `libsndfile` or `rdma-core`, `venvDriverLibs` for host driver sonames and `venvOptionalLibs` for libraries that load on demand only. The build fails naming every unresolved library.

### Inference server credentials

Credentials are granted per model, so no worker can read another's keys.
`credentials.<name>` maps a name to a file outside the Nix store, or to `null` to import it from the system credential store, and `${cred:name}` in `settings` or `environment` expands to its read-only path:

```nix
services.llmhop.llama-cpp.models."qwen3-8b" = {
  model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  credentials.api-keys = "/run/secrets/qwen-api-keys";
  settings.api-key-file = "\${cred:api-keys}";
};
```

Provision an imported credential as a root-only file or encrypted:

```sh
(umask 077; systemd-ask-password -n > /etc/credstore/llmhop.hf-token)
systemd-ask-password -n | systemd-creds encrypt --name=llmhop.hf-token - /etc/credstore.encrypted/llmhop.hf-token
```

vLLM and SGLang read a YAML file with `api-key` through `settings.config`, as in `credentials."config.yaml"` with `settings.config = "\${cred:config.yaml}"`, while llama.cpp uses `api-key-file`.
Containers see their credentials at `/run/llmhop/credentials`, named by `$CREDENTIALS_DIRECTORY` as natively, and readable through a user namespace with the backend's or gateway's `mountOptions.credentials`, see [user namespaces](#containers-and-user-namespaces).

### vLLM watermarking

Both vLLM backends can watermark a model's output and run detectors serving `POST /detect` beside the workers.
A `watermark` is vLLM's `WatermarkConfig` without the key, plus the `credential` holding the key, and a detector tests every one of its `profiles`:

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

A key is an unsigned 64-bit integer credential, never entering the Nix store or a command line:

```sh
(umask 077; od -An -N8 -tu8 /dev/urandom | tr -d ' \n' > /etc/credstore/vllm.watermark-key.2026-10)
```

A detector reports the most significant profile with its Bonferroni-corrected `p_value`, `score`, `num_scored_tokens` and `is_watermarked`.
To rotate a key, provision it under a new credential name and keep a profile with the old one while old text still needs checking.
llmhop routes detectors as unlisted models, as in `POST /route/production/detect`, while other gateways leave them to direct clients.
Watermarking requires vLLM 0.30.0 or newer.
