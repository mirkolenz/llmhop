# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop reads the `model` field of an incoming request and reverse-proxies it to the matching backend.
It is built for single-model servers like [vLLM](https://github.com/vllm-project/vllm) and [SGLang](https://github.com/sgl-project/sglang), but works with any OpenAI-compatible backend, self-hosted or remote.

- Pure Go, no CGO, stateless and safe behind any load balancer.
- Body and path routing with aliases and wildcards, a models API served from the config, health and readiness endpoints, graceful draining and reloading.
- Balancing over several servers or data-parallel ranks with stateless prefix-cache affinity, failover, queueing and timeouts.
- Ships as a static binary, a Docker image and a hardened NixOS module running llama.cpp, SGLang or vLLM behind llmhop or no gateway, natively or in containers.

## How it works

LLMhop looks up the request's `model` in its config and forwards the request verbatim.
The `model` is read from a JSON body or a `multipart/form-data` one, as `/v1/audio/transcriptions` sends.
Unknown models return `404`, an invalid body or a missing `model` return `400`.
`GET /v1/models` and `GET /v1/models/{model}` are answered from the config and never proxied, with every model's `metadata` as further members, such as `max_model_len`, or replacing `created`, which is `0`, and `owned_by`, which is `llmhop`.
Model names may contain `/`, as in Hugging Face names such as `org/name`.
A model's `aliases` are further names routed to it and listed beside it, each forwarded verbatim, as vLLM serves LoRA adapters, or with the `model` of a JSON body replaced by the alias's `model`, as SGLang serves an adapter as `<served>:<adapter>`.
A multipart body sent to such an alias gets `400`.
A name ending in `*`, such as `openai/*`, is a wildcard routing every name it prefixes, the longest one winning over shorter ones but never over an exact name, and is not listed.

A request under `/route/{model}/` is routed by path instead, with the prefix stripped and the body left unparsed, so `POST /route/production/detect` reaches `production` as `POST /detect`.
The longest configured model name or alias that prefixes the path wins, wildcards do not apply, and a `/` in a model name may be written raw or as `%2F`.
A model marked `"unlisted": true` is routed but left out of the models API, which suits services such as a watermark detector.

Every other request gets an `X-Request-Id`, unless it carries one, which reaches the backend and the response, and is logged once answered with its model, server, status, size, duration and the name of its auth token.
`GET /health` returns `{ "status": "ok", "models": 3 }` with the number of listed models and aliases.
`GET /readiness` probes the `healthPath` on every URL of every model that sets one and answers `200` only if every such model has a URL responding `2xx`, else `503`, so a restarting replica keeps llmhop ready.
Both never require a token and are not logged.
LLMhop sends `READY=1` to systemd once its listeners are bound, reloads its config on `SIGHUP`, keeping the current one if the new one fails, and drains in-flight requests on `SIGTERM` or `SIGINT`.
A reload applies everything but `listen`, while requests in flight finish on the config they started with.

### Balancing and affinity

A model's `urls` are servers of the same model, such as replicas on several GPUs or hosts.
A request without an affinity key goes to the server with the fewest requests in flight.
A request with a key always goes to the first server in the [rendezvous hashing](https://en.wikipedia.org/wiki/Rendezvous_hashing) order of its key, so the turns of a conversation reuse the prefix cache of one server and a chain of stored responses of the Responses API that keeps its key stays with the server storing it.
Every llmhop instance computes the same order without sharing any state, so affinity holds behind any load balancer.
The key comes from the first of the `affinity` sources a request carries, which clients set to name their conversation, by default:

1. `header:X-Session-Id`, a header, where Open WebUI's `X-OpenWebUI-Chat-Id` also fits,
2. `prompt_cache_key`, the body's member meant for this by OpenAI.

`"affinity": []` disables affinity.

`dataParallelSize`, at most 256, hashes keyed requests over the ranks of every URL and pins them through the `X-Data-Parallel-Rank` header of vLLM and SGLang, which llmhop never takes from a client, so affinity also works across the data-parallel ranks of one server, which balances keyless requests itself.
A server refusing a connection is avoided for `failoverSeconds`, by default 5, and a request with a body routed by its `model` moves on to the next server.

### Errors

Every error is JSON in the shape of OpenAI, as in `{"error": {"message": "...", "type": "not_found_error", "code": "model_not_found"}}`.

| Status | Meaning                                                           |
| ------ | ----------------------------------------------------------------- |
| `400`  | an invalid body, a missing `model`, an unreadable body, or a multipart body to an alias rewriting the `model` |
| `401`  | missing or invalid bearer token, with `WWW-Authenticate: Bearer`   |
| `403`  | a cross-site request or foreign host on a trusted socket          |
| `404`  | unknown model                                                      |
| `408`  | the body did not arrive within a minute                            |
| `413`  | the body exceeds `maxBodyBytes`                                    |
| `429`  | the model reached `maxConcurrentRequests`, with `Retry-After: 1`   |
| `502`  | the backend is unreachable                                         |
| `503`  | the `maxBufferedBytes` budget is exhausted, with `Retry-After: 1`  |
| `504`  | the backend exceeded `responseTimeoutSeconds`                      |

## Configuration

```json
{
  "listen": ["127.0.0.1:8080", "unix:///run/llmhop/http.sock"],
  "authTokens": { "client": "${cred:llmhop.client-token}" },
  "models": {
    "llama-3-8b": { "urls": ["http://localhost:30000"], "healthPath": "/health" },
    "meta-llama/Llama-3.1-8B": {
      "urls": ["http://localhost:30001", "http://gpu-2:30001"],
      "metadata": { "max_model_len": 131072 }
    },
    "qwen3-8b": {
      "urls": ["unix:///run/llmhop/vllm-qwen3-8b/http.sock"],
      "aliases": { "qwen3-8b-sql": {} },
      "dataParallelSize": 4,
      "maxConcurrentRequests": 64,
      "queueTimeoutSeconds": 30
    },
    "openai/*": {
      "urls": ["https://api.openai.com"],
      "headers": { "Authorization": "Bearer ${cred:openai-key}" },
      "responseTimeoutSeconds": 120
    }
  }
}
```

`listen` holds `host:port` addresses, with `[::1]:8080` for IPv6 and `:8080` for every interface, or `unix:///<socket path>`.
It has no default, and `serve` uses the sockets of systemd socket activation when present, else `listen`.
Setting both or neither is an error, and `check` does not require `listen`.
Each of `urls` is an absolute `http(s)` URL or `unix:///<socket path>`.
With `authTokens`, a map of names to tokens, set, every route but `/health` and `/readiness` requires a matching bearer token, which is stripped before forwarding, while the backend learns the token's name from `X-Llmhop-Client`.
`authTokenCredentials`, a systemd credential glob with a single trailing `*` as in `ImportCredential=`, adds every matching credential as a token named by the part the `*` matched, read at startup, and keeps tokens required while none matches.
`trustedSockets`, a map of client names to unix socket paths, serves the requests arriving on such a socket without a token as that client, so the socket's permissions decide who may connect, such as an admin forwarding it over SSH.
Browsers must name a loopback host there, so web pages cannot rebind a domain to a forwarded port, and get `403` for cross-site requests with unsafe methods such as `POST`, while they cannot read the answers of the others.
`corsOrigins` lists the origins, as in `https://chat.example`, whose pages may call the API with a bearer token, or `*` for every origin, which is safe since browsers never send a token on their own.
llmhop answers the preflights, allows the methods of REST APIs and every request and response header but no credentials, and drops the CORS headers of backends whenever tokens are required, so only `corsOrigins` decides which pages read a response.
Both require auth tokens, and CORS never applies to trusted sockets.
A model's `headers` are applied last, so a configured `Authorization` replaces the client's.
Unknown keys are rejected, and `llmhop check config.json` validates a config without binding a port or expanding secrets.

### Secret references

Token values in `authTokens` and strings in `models.*.headers` are expanded at startup, and an unresolved reference is a startup error:

- `${cred:name}`: the systemd credential `name` from `$CREDENTIALS_DIRECTORY`.
- `${env:NAME}`: an environment variable.
- `${file:/absolute/path}`: a file, with trailing newlines trimmed.
- `$$`: a literal `$`.

### Request limits

- `maxBodyBytes` (100 MiB): larger bodies get `413`.
- `maxBufferedBytes` (1 GiB): bytes of body-routed requests buffered at once, further ones get `503` with `Retry-After: 1`. A body is buffered until the backend starts its response, and must arrive within a minute, or the request gets `408`.
- `models.*.maxConcurrentRequests` (unlimited): proxied requests per model over all its URLs, further ones get `429` with `Retry-After: 1`.
- `models.*.queueTimeoutSeconds` (`0`): how long a request waits in line for a free slot before its `429`, holding its buffered body meanwhile.
- `models.*.responseTimeoutSeconds` (unlimited): how long a backend may take from receiving the whole request until its response headers, after which the request gets `504`. A streamed response may take longer after that.

`0` disables a limit.

## Running

```sh
llmhop serve config.json
nix run github:mirkolenz/llmhop -- serve config.json
docker run --rm -p 8080:8080 -v ./config.json:/config.json ghcr.io/mirkolenz/llmhop
```

`llmhop version` prints the version.
The image runs `serve /config.json`, so the mounted config must set `"listen": [":8080"]`.

## NixOS and system-manager modules

Add the flake input `github:mirkolenz/llmhop` and import `llmhop.nixosModules.default` on NixOS or `llmhop.systemManagerModules.default` on other distributions with [system-manager](https://github.com/numtide/system-manager):

```nix
services.llmhop = {
  gateway.enable = true;
  gateway.listen.default.host = "";
  gateway.listen.default.openFirewall = true;
  llama-cpp.enable = true;
  llama-cpp.models."qwen3-8b".model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
};
```

`services.llmhop.runtime` decides how every backend and the gateway run:

| `runtime`     | Units                                    | Downloads           | Clients reach a model through | Bundles |
| ------------- | ---------------------------------------- | ------------------- | ----------------------------- | ------- |
| `"native"`    | hardened system services                 | fetchers, offline servers | a unix socket or a port  | no      |
| `"container"` | rootful Quadlet containers in user namespaces | each server itself | a published port          | yes     |

Both include [quadlet-nix](https://github.com/mirkolenz/quadlet-nix) for containers, and container setups can be [bundled](#hosts-without-nix) for hosts without Nix.
With system-manager, the host provides the configuration of podman in `/etc/containers`.
See the [options reference](https://mirkolenz.github.io/llmhop/) for every option and the [module internals](https://mirkolenz.github.io/llmhop/internals.html) for the design rationale.

### Gateway

`services.llmhop.gateway.enable` puts llmhop in front of every backend, routing every model and detector by its `name`.
It runs only while some backend serves a workload, which the read-only `services.llmhop.gateway.active` reports.
Routed workloads must stay on loopback and leave authentication to the gateway.

The gateway runs as the `llmhop` user with one socket-activated `llmhop-<name>.socket` per entry of `listen`, as in `listen.caddy.socketGroup = "caddy"` for a unix socket, or as a container on the host network receiving the same sockets, which loads an image archive of the same build, unless `container.image` names a registry reference such as `ghcr.io/mirkolenz/llmhop:latest`.
A listener with `trusted` is added to `trustedSockets` as the client named after it.
The `default` listener serves `127.0.0.1:8080` and `environment` and `environmentFile` are forwarded to the service.
Its generated config is validated at build time with `llmhop check`, routes every LoRA adapter as an alias and pins requests to the ranks of a model with `dataParallelSize`, see [balancing](#balancing-and-affinity).
Natively, a changed config reloads the gateway in place, without dropping a request.
Reference secrets in `settings` as `${cred:name}` and grant them through `credentials`.
`settings.authTokenCredentials = "llmhop.token.*"` imports the tokens of `/etc/credstore/llmhop.token.<client>`, or encrypted ones of `/etc/credstore.encrypted`, so clients come and go without a rebuild by adding or deleting their file.
Natively, `systemctl reload llmhop` then re-imports the credentials and reloads the config without a restart, while a container needs `systemctl restart llmhop`, whose sockets hold new connections meanwhile.
`llmhopctl`, installed unless `ctl.enable` is false, does both as root with `llmhopctl token list`, `create <client>`, `rotate <client>` and `revoke <client>`, printing new tokens, and keeps a rotated token in the store holding it.

Without the gateway, each model serves clients on its own socket or `port`, and `socketClients` lists the users, such as a reverse proxy, that may connect to every native model socket.

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
    package = inputs.llmhop.legacyPackages.${pkgs.stdenv.hostPlatform.system}.mkUvEnv { workspaceRoot = ./vllm-env; };
    models."qwen3-8b" = {
      model = "Qwen/Qwen3-8B";
      port = 19001;
      settings.reasoning-parser = "qwen3";
    };
  };
  sglang = {
    enable = true;
    package = inputs.llmhop.legacyPackages.${pkgs.stdenv.hostPlatform.system}.mkUvEnv { workspaceRoot = ./sglang-env; };
    models."llama-3-8b" = {
      model = "meta-llama/Meta-Llama-3-8B-Instruct";
      port = 19002;
    };
  };
};
```

A vLLM or SGLang model serves `loras`, LoRA adapters by the name clients request them under, which its fetcher downloads like `model`:

```nix
services.llmhop.vllm.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  loras."qwen3-8b-sql" = "org/qwen3-8b-sql-lora";
  settings.max-lora-rank = 64;
};
```

vLLM serves an adapter under its own name, while SGLang serves it as `<model>:<adapter>`, so the gateway rewrites the `model` of requests to the adapter's name, and clients without the gateway send the latter.

Several GPUs serve one model faster as data-parallel ranks of one server, set by `dataParallelSize = 2` on a vLLM or SGLang model, than as separate models, since the server balances requests by its own load and cache state.
vLLM then runs several API frontends by default, each storing the responses of the Responses API on its own, so stored responses need `settings.api-server-count = 1`.

Each workload runs as the unit `<engine>-<name>`.
Native workers are hardened services running as the backend's `user`, which defaults to the engine name, while containers run rootful in user namespaces, see [containers](#containers-and-user-namespaces).
A worker stays `activating` until it answers its health endpoint, and `startupOrdering`, enabled by default for every backend, starts models one at a time by `name`, so two never profile or size their GPU memory at once.
On a stop, such as the restart after a fetch, a server drains its in-flight requests for the backend's `shutdownTimeoutSeconds`, 10 by default, before it is killed: vLLM through `--shutdown-timeout`, SGLang and llama.cpp on SIGTERM.

Ordering does not split a GPU between models, since every engine sizes itself from the memory free when it starts.
vLLM gives its KV cache everything free after warmup, SGLang its static pool a fraction of what was free at its start, and llama.cpp fits its context and offloaded layers to free memory.
Models sharing a GPU therefore need explicit budgets in their `settings`, which together fit the GPU:

| Engine    | Budget                                                                                               |
| --------- | ---------------------------------------------------------------------------------------------------- |
| vLLM      | `gpu-memory-utilization`, a fraction of the GPU, and `kv-cache-memory`, which skips sizing the cache |
| SGLang    | `mem-fraction-static`, a fraction of the memory free at its start, and `max-total-tokens` as a cap   |
| llama.cpp | `fit = "off"` with `n-gpu-layers` and `ctx-size`                                                     |

Evaluation rejects any port, unit or model name claimed twice.
Customize the generated units directly, as in `systemd.services.vllm-qwen3-8b.serviceConfig.MemoryHigh = "64G"` or `virtualisation.quadlet.containers.vllm-qwen3-8b.containerConfig`.

Native llama.cpp and vLLM workers default to `port = null`, binding a unix socket below `socketDirectory` that only the backend's workers, the gateway and `socketClients` can reach.
Set `port` to bind `<host>:<port>` instead, which SGLang and every container always need.

#### Fetching and offline servers

Natively, each model has a fetcher `<engine>-<name>-fetch` that downloads everything into the model's own cache `cache.directory/<name>`, after which the server runs offline from it.
A `model` that is an absolute path has no fetcher.
`extraRepositories` lists further repositories that `settings` reference, such as a draft model, and `revision` pins a branch, tag or commit:

```nix
services.llmhop.vllm.models."qwen3-8b" = {
  model = "Qwen/Qwen3-8B";
  revision = "main";
  extraRepositories = [ "Qwen/Qwen3-0.6B" ];
  settings.speculative-config = {
    model = "Qwen/Qwen3-0.6B";
    num_speculative_tokens = 4;
  };
};
```

Only fetchers get the backend's `fetch.credentials`, `fetch.environment` and the Hugging Face token of gated repositories, which `fetch.hfTokenCredential = "llmhop.hf-token"` imports for every engine.
`<backend>-update`, such as `vllm-update`, reruns every fetcher on the `fetch.schedule` (`OnCalendar=`), weekly by default, prunes what the model no longer references, and restarts each running server after a successful fetch, even if its model did not change.
An interrupted download leaves a running server alone, and a successful retry refreshes it.
An explicitly stopped server stays stopped.
`fetch.enable = false` drops the fetchers, refresh and update units, so each server downloads its repositories itself when it starts, which needs `offline = false`, its default then.

With fetchers, servers never download from the hub: they get `HF_HUB_OFFLINE` and `LLAMA_ARG_OFFLINE`, and with `offline = true`, the default, no network.
A server on a socket gets no network at all and on a `port` only loopback.
Only a socket or a loopback `host` can be isolated like this, so any other workload defaults to `offline = false` and rejects `offline = true`.
`offline = false` lifts the network restrictions for features like media URLs in requests.

#### Settings rendering

`settings`, over the backend's `modelSettings`, becomes the server's CLI flags beside those llmhop derives from the other options, such as the listener, the served name, `revision`, `loras` and `dataParallelSize`, which `settings` must not set.
Strings and paths are passed verbatim and everything else as JSON, so attribute sets work for options like `--speculative-config`.

- `true` becomes `--<key>`, while `null` and empty lists are dropped.
- llama.cpp and vLLM render `false` as `--no-<key>`, while SGLang drops it, so write the negated key, as in `disable-radix-cache = true`.
- vLLM and SGLang pass a list to one flag (`--<key> a b`), llama.cpp joins it by commas (`--<key> a,b`), since repeating some of its flags, such as `--tensor-split`, keeps only the last.

#### Containers and user namespaces

With `runtime = "container"`, every workload runs the backend's `container.image` on its published loopback `port` and downloads what it serves into the Podman volume `<engine>-<name>` when it starts, so a restart picks up a moved `revision`.
A gated repository needs `HF_TOKEN` from the backend's `environmentFile`, since the server itself downloads.
`container.devices` exposes the GPUs through CDI, such as `nvidia.com/gpu=all`, which `hardware.nvidia-container-toolkit` provides.
Tagged registry images are labeled `AutoUpdate=registry` for `virtualisation.quadlet.autoUpdate`, and are otherwise only pulled while missing, so a start needs no registry.

Every container runs rootful in its own user namespace, `services.llmhop.container.userNS = "auto:size=65536"` by default, which maps its root onto a range of the subordinate IDs of the `containers` user that quadlet-nix declares.
Podman may pick another range whenever it recreates a container, so llmhop mounts every volume and the credentials with `idmap`, which needs a filesystem supporting idmapped mounts below `/var/lib/containers`, such as ext4, xfs, btrfs or ZFS 2.2.
`services.llmhop.container.config` adds `[Container]` keys to every container, such as the render group of AMD and Intel GPUs, whose device nodes the namespace otherwise cannot open:

```nix
services.llmhop.container = {
  userNS = "auto:size=65536,gidmapping=303:303:1";
  config.GroupAdd = [ "303" ];
};
```

`userNS = null` runs the containers as host root, or leaves explicit `UIDMap=` and `GIDMap=` to `container.config`.

#### Hosts without Nix

Container setups can be rendered into plain files for any host with podman 5 and systemd, such as Ubuntu 25.04:

```nix
packages.x86_64-linux.llmhop-bundle = inputs.llmhop.legacyPackages.x86_64-linux.mkQuadletBundle {
  modules = [
    {
      services.llmhop = {
        gateway.enable = true;
        vllm = {
          enable = true;
          container.image = "docker.io/vllm/vllm-openai:latest";
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

It is the [bundle of quadlet-nix](https://github.com/mirkolenz/quadlet-nix#bundles-for-hosts-without-nix) named `llmhop`, which every system importing llmhop's modules exposes as `virtualisation.quadlet.bundle.package`, with every rootful Quadlet unit of that system.
It sets `services.llmhop.runtime` to `"container"`, so a native configuration fails to build.
The bundle holds the Quadlet files, the gateway's socket units and the auto-update units below `etc/`, the generated configs and the gateway's image archive below `/usr/local/lib/llmhop`, and an `install.sh` that copies them into place, starts the servers, restarts every running unit it changed and retires those a previous bundle had but this one lacks.
The `uninstall.sh` installed beside the assets removes the bundle again, keeping the volumes.
The host needs the `containers` entry in `/etc/subuid` and `/etc/subgid` for the user namespaces, as in `useradd --system --no-create-home containers && usermod --add-subuids 2147483647-4294967294 --add-subgids 2147483647-4294967294 containers`.
Firewall and user options have no effect there.

### Native vLLM and SGLang from prebuilt wheels

Native vLLM and SGLang run from upstream's wheels, pinned in a small [uv](https://docs.astral.sh/uv/) workspace and built with `mkUvEnv`:

```toml
# vllm-env/pyproject.toml, then run `uv lock`
[project]
name = "vllm-env"
requires-python = "==3.12.*"
dependencies = ["vllm==0.16.2"]
```

`mkUvEnv` builds against the lowest admitted Python and bakes the GPU driver runpath into the wheels, while the driver itself comes from `hardware.graphics` and your vendor configuration.
`models.<name>.package` overrides the `package` per model, for example with a nightly.

- **JIT compilers** find `nvcc` through `CUDA_HOME`, which `mkCudaHome { packages = [ ... ]; }` builds from the `cudaPackages_*` set named by the environment's `passthru.cudaPackagesAttr`.
- **AMD and Intel GPUs** work with vLLM's ROCm or XPU wheels, added as an explicit `[[tool.uv.index]]` per vLLM's [installation docs](https://docs.vllm.ai/en/latest/getting_started/installation/).
- **sdists without a build system** need their build dependencies under `[tool.uv.extra-build-dependencies]`, as in `antlr4-python3-runtime = ["setuptools"]`.
- **flashinfer** packages must be pinned to the `flashinfer-python` version vLLM pins, or flashinfer refuses to start.
- **Native libraries** come from `buildInputs` for linked ones, `runtimePaths` for ones loaded by a bare `dlopen`, such as `libsndfile` or `rdma-core`, `driverLibs` for host driver sonames and `optionalLibs` for libraries that load on demand only. The build fails naming every unresolved library.

### Inference server credentials

Credentials are granted per workload, so no worker can read another's keys.
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
Containers see their credentials at `/run/llmhop/credentials`, named by `$CREDENTIALS_DIRECTORY` as natively.

### Watermarking

vLLM and SGLang can watermark a model's output and run detectors serving `POST /detect` beside the workers.
A `watermark` holds the engine's watermark config without its key as `settings`, plus the `credential` holding the key, and a detector tests every one of its `profiles`:

```nix
services.llmhop.vllm = {
  models.qwen = {
    model = "Qwen/Qwen3-8B";
    revision = "main";
    watermark = {
      credential = "vllm.watermark-key.2026-10";
      settings.algorithm = "dual_key_gumbel";
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

vLLM reads the key through `key_file` of its `WatermarkConfig`, which requires a vLLM newer than 0.34.0.
SGLang reads its keys from its config file, which the watermark script writes into the server's private `/tmp`, and takes a second key for dual-key watermarking as `secondaryCredential`.
Its `settings` are SGLang's watermark config without `key` and `key_b`, such as `context_window` and `enforce_all`, which keeps clients from opting out.
The engines differ in their algorithms, so each detector only detects the watermarks of its own backend.
A detector reports the most significant profile with its Bonferroni-corrected `p_value`, `score`, `num_scored_tokens` and `is_watermarked`.
To rotate a key, provision it under a new credential name and keep a profile with the old one while old text still needs checking.
The gateway routes detectors as unlisted models, as in `POST /route/production/detect`.
