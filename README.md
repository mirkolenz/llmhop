# LLMhop

One port, many models: A tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop reads the `model` field of an incoming request and reverse-proxies it to the matching backend.
It is built for single-model servers like [vLLM](https://github.com/vllm-project/vllm) and [SGLang](https://github.com/sgl-project/sglang), but works with any OpenAI-compatible backend, self-hosted or remote.

- Pure Go, no CGO, stateless and safe behind any load balancer.
- Body and path routing with aliases and wildcards, a models API served from the config, health, readiness and JSON metrics, graceful draining and reloading.
- Balancing over several servers or data-parallel ranks with stateless prefix-cache affinity under bounded loads, failover, retries, passive and active health checks, queueing and timeouts.
- Clients authenticated by a key or a unix socket, each with a policy deciding its models, concurrency, request rate and share of a saturated model.
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

llmhop reserves the prefix `/llmhop/` for its own routes and answers an unknown path below it with `404`, while every other path passes through unchanged, so the APIs of the engines outside `/v1/`, such as `/tokenize`, keep working.

| Path                              | Key    | Purpose                                                        |
| --------------------------------- | ------ | -------------------------------------------------------------- |
| every path outside `/llmhop/`     | client | requests routed by their `model`, and the models API            |
| `GET /llmhop/health`              | none   | `{ "status": "ok", "models": 3 }`, the listed models and aliases |
| `GET /llmhop/readiness`           | none   | the readiness of the backends                                  |
| `/llmhop/proxy/{model}/{path}`    | client | any path of the backend of a model, with the prefix stripped    |
| `GET /llmhop/metrics`             | none   | the [metrics](#metrics) of llmhop, on metrics listeners only    |

A request under `/llmhop/proxy/{model}/` is routed by its path, with the prefix stripped and the body forwarded verbatim, for requests without a `model` in their body, such as `/generate` of SGLang.
Its body streams unparsed, unless it is JSON that a `body` [affinity](#balancing-and-affinity) source may read for a model with several targets.
The longest configured model name or alias that prefixes the path wins, wildcards do not apply, and a `/` in a model name may be written raw or as `%2F`.
A model marked `"unlisted": true` is routed but left out of the models API, which suits services such as a watermark detector.

Every other request gets an `X-Request-Id`, unless it carries one, which reaches the backend and the response, and is logged once answered.
`/llmhop/readiness` answers `200` only if every model with a `healthPath` has a URL that passed its latest [probe](#balancing-and-affinity), else `503`, so a restarting replica keeps llmhop ready and failed requests, which may be those of one client, never make it unready.
Health, readiness and metrics never require a key and are not logged.
LLMhop sends `READY=1` to systemd once its listeners are bound, reloads its config on `SIGHUP`, keeping the current one if the new one fails, and drains in-flight requests on `SIGTERM` or `SIGINT`.
A reload applies everything but `listen`, while requests in flight finish on the config they started with.

### Balancing and affinity

A model's `urls` are servers of the same model, such as replicas on several GPUs or hosts.
A request without an affinity key goes to the server with the fewest requests in flight.
A request with a key goes to the first server in the [rendezvous hashing](https://en.wikipedia.org/wiki/Rendezvous_hashing) order of its key, so the turns of a conversation reuse the prefix cache of one server and a chain of stored responses of the Responses API that keeps its key stays with the server storing it.
As in [consistent hashing with bounded loads](https://arxiv.org/abs/1608.01350), it skips a server with more requests in flight than 1.25 times the average of the model's servers, rounded up, plus one, and takes the next server in its order within that bound, so a busy conversation cannot overload one server.
A pinned request never leaves its first server, under any load, avoidance or failure, since no other server holds its state: one whose source sets `"pinned": true` or one continuing a stored response with `previous_response_id`.
Every llmhop instance computes the same order without sharing any state, so affinity holds behind any load balancer.
The key comes from the first of the `affinity` sources a request carries, which clients set to name their conversation.
Each source sets exactly one of `header`, the name of a header, or `body`, the path of member names to a string in the JSON body, and optionally `pinned`, by default:

1. `{"header": "X-Session-Id"}`, where Open WebUI's `X-OpenWebUI-Chat-Id` also fits,
2. `{"body": ["prompt_cache_key"]}`, the body's member meant for this by OpenAI,
3. `{"body": ["session_params", "id"], "pinned": true}`, the session of SGLang, whose state lives on one server.

`"affinity": []` disables affinity.

`dataParallelSize`, at most 256, hashes keyed requests over the ranks of every URL and pins them through the `X-Data-Parallel-Rank` header of vLLM and SGLang, which llmhop never takes from a client, so affinity also works across the data-parallel ranks of one server, which balances keyless requests itself.
A request whose body can be resent, one that llmhop buffered or one without a body, moves on to the next server in its order when a server refuses the connection, resets it before responding, or answers `502`, `503` or `504`, trying each server once, while a response that reached the client is never retried.
A server is avoided for `failoverSeconds`, by default 5, once it refuses a connection or fails three requests in a row with a `502`, `503`, `504`, a reset or a response timeout, while a `429` or another `5xx`, which may concern the request alone, never counts and any other response resets the count.
llmhop probes the `healthPath` of a model on each of its servers every second in the background, each on its own, avoiding a server from a failed probe until one passes, which also ends an avoidance after failed requests.
An avoided server serves only once every other one is avoided or tried.

### Errors

Every error is JSON in the shape of OpenAI, as in `{"error": {"message": "...", "type": "not_found_error", "code": "model_not_found"}}`.

| Status | Meaning                                                           |
| ------ | ----------------------------------------------------------------- |
| `400`  | an invalid body, a missing `model`, an unreadable body, or a multipart body to an alias rewriting the `model` |
| `401`  | missing, invalid or expired key, with `WWW-Authenticate: Bearer`   |
| `403`  | a model the client may not use, or a cross-site request or foreign host on the listener of a client |
| `404`  | unknown model, or an unknown path below `/llmhop/`                 |
| `408`  | the body did not arrive within a minute                            |
| `413`  | the body exceeds `maxBodyBytes`                                    |
| `429`  | the model or client reached `maxConcurrentRequests`, with `Retry-After: 1`, or a rate limit of the client, with `Retry-After` |
| `502`  | the backend is unreachable                                         |
| `503`  | the `maxBufferedBytes` budget is exhausted, with `Retry-After: 1`  |
| `504`  | the backend exceeded `responseTimeoutSeconds`                      |

## Configuration

```json
{
  "listen": {
    "default": { "host": "127.0.0.1", "port": 8080 },
    "ssh": { "socket": "/run/llmhop/ssh.sock" },
    "admin": { "socket": "/run/llmhop/admin.sock", "metrics": true }
  },
  "clients": { "alice": { "keyHash": "3f9a...e1" } },
  "models": {
    "llama-3-8b": { "urls": ["http://localhost:30000"], "healthPath": "/health" },
    "meta-llama/Llama-3.1-8B": {
      "urls": ["http://localhost:30001", "http://gpu-2:30001"],
      "metadata": { "max_model_len": 131072 }
    },
    "qwen3-8b": {
      "urls": ["unix:///run/llmhop/vllm-qwen3-8b/http.sock"],
      "healthPath": "/health",
      "metricsPath": "/metrics",
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

`listen` holds the listeners by name, each binding exactly one of a TCP `port` on its `host`, an IP address that is every interface if empty or left out, or the unix `socket` at an absolute path.
Under systemd socket activation, each passed socket serves the listener named by its `FileDescriptorName=`, which llmhop never rebinds and which must have the port or socket of the listener if it sets one, compared as one normalized address with an empty or unspecified host as every interface, else llmhop fails to start.
A listener without `port` and `socket` takes the socket of its name, which must be passed, while a passed socket without a listener serves with the defaults, unless it has the address of a listener, which fails the start as a misnamed socket.
A client of a `listener` requires its passed sockets to be unix sockets.
A reload that would bind a listener elsewhere fails, since only a restart rebinds.
A listener with `metrics` serves the [metrics](#metrics) without a key, so it should be a loopback port or a unix socket.
Without any listener or passed socket, `serve` fails, while `check` does not require one.
Each of `urls` is an absolute `http(s)` URL or `unix:///<socket path>`.
`corsOrigins` lists the origins, as in `https://chat.example`, whose pages may call the API with a bearer key, or `*` for every origin, which is safe since browsers never send a key on their own.
llmhop answers the preflights, allows the methods of REST APIs and every request and response header but no credentials, and drops the CORS headers of backends whenever keys are required, so only `corsOrigins` decides which pages read a response.
It requires clients, and CORS never applies to the listener of a client.
A model's `headers` are applied last, so a configured `Authorization` replaces the client's.
Unknown keys are rejected, and `llmhop check` validates a config without binding a port or expanding secrets.

### Clients and policies

With any entry of `clients` or with `clientCredentials`, every route but health, readiness and metrics requires a client, while the backend learns its name from `X-Llmhop-Client`.
A client sets exactly one of `keyHash`, the hash of a bearer token stripped before forwarding, or `listener`, the name of a unix socket listener of `listen` whose requests count as the client's without a key, so the socket's permissions decide who may connect, such as an admin forwarding it over SSH.
A listener belongs to at most one client.
Browsers must name a loopback host there, so web pages cannot rebind a domain to a forwarded port, and get `403` for cross-site requests with unsafe methods such as `POST`, while they cannot read the answers of the others.
A client may also set `expiresAt`, an RFC 3339 time after which its key gets `401`, and `policy`, the name of an entry of `policies`.

A token reads `llmhop_<secret><checksum>`, a prefix that secret scanners recognize, 256 random bits as 52 base32 characters, and their CRC32 as 7 more, which lets scanners discard random matches offline.
llmhop stores only its SHA-256 hash in hex as `keyHash`, so a leaked config or credential reveals no usable token.
`llmhop key create` stores a new key for `clientCredentials` under systemd, while `llmhop key generate` prints a token and its `credential`, whose fields go into a declared client or, as they are, into a credential file, such as one of `/run/secrets` in a container, which `SIGHUP` reloads:

```sh
llmhop key generate --policy guest --expires 30d > out.json
jq .credential out.json > secrets/llmhop.api-key.alice
jq -r .token out.json
docker kill -s HUP llmhop
```

```json
{
  "defaults": { "models": ["qwen3-8b"], "maxConcurrentRequests": 2, "requestsPerMinute": 30 },
  "policies": {
    "research": {
      "models": ["qwen3-*", "embed"],
      "maxConcurrentRequests": 16,
      "weight": 2
    },
    "guest": { "maxConcurrentRequests": 2, "requestsPerMinute": 10 }
  },
  "clients": {
    "alice": { "keyHash": "3f9a...e1", "policy": "research", "maxConcurrentRequests": 32 },
    "admin": { "listener": "ssh" }
  },
  "clientCredentials": true
}
```

The effective policy of a client resolves field by field from the client's own fields, its `policy`, `defaults` and the built-in defaults, which impose no limit.
A field set on a layer, even to `0` or `[]`, replaces it entirely, so a client can be granted more than the defaults.
Without any client, every request belongs to the anonymous client `""`, which `defaults` limit.

| Field                   | Meaning                                                                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `models`                | allowlist of model names, aliases and detectors, also for `/llmhop/proxy/`, wildcards such as `qwen3-*` included, others get `403` and are not listed |
| `maxConcurrentRequests` | requests of the client in flight, beyond which it waits in the model's queue                                                   |
| `requestsPerMinute`     | token bucket of requests, `429` with `Retry-After` once empty                                                                  |
| `weight`                | share of the client among those waiting for a saturated model, which admits them round-robin, one by default                   |

`0`, `[]` or an absent field means no limit.
A request must pass the limits of its client beside the `maxConcurrentRequests` of its model.
Responses of a client with `requestsPerMinute` carry OpenAI's `x-ratelimit-limit-requests`, `x-ratelimit-remaining-requests` and `x-ratelimit-reset-requests`, while those of a backend, which describe llmhop's own upstream credential, are dropped.
Every limit is exact and needs nothing from a request body or a response.
The limiters live in the memory of each instance, survive a reload and reset on a restart, so N instances behind a load balancer each enforce their own share, and a limit should be divided by N.

`"clientCredentials": true` imports every credential named `llmhop.api-key.<client>` as the client `<client>`, read at startup and on every reload, which keeps keys required while there is none.
A credential named like a declared client is skipped, so every key can follow `llmhop.api-key.<client>`.
An invalid credential, such as one naming a policy the config no longer has, is logged and skipped, so its client gets `401` while the gateway still starts.
A credential holds a JSON object with the `keyHash` and optionally its `policy` and `expiresAt`, such as `{"keyHash": "3f9a...e1", "policy": "guest", "expiresAt": "2027-01-01T00:00:00Z"}`, so a key and its metadata rotate together, while a client without a `policy` gets the `defaults`.
Any other member is an error, so limits belong to policies.
Every credential llmhop defines is named `llmhop.<kind>[.<instance>]`, as the API key `llmhop.api-key.<client>`, since `/etc/credstore` is shared by the whole host.

### Metrics

A listener with `metrics` serves `GET /llmhop/metrics` in the Prometheus text format, which Prometheus or VictoriaMetrics scrape and `llmhop top` reads:

| Series                                         | Labels                     | What                                                                       |
| ---------------------------------------------- | -------------------------- | -------------------------------------------------------------------------- |
| `llmhop_requests_total`                        | `client`, `model`, `status` | answered requests, where a rate limit shows as `429`                      |
| `llmhop_request_duration_seconds`              | `model`                    | histogram of the durations of the successful requests sent in full                    |
| `llmhop_request_first_token_seconds`           | `model`                    | histogram of the times to the first byte of the event streams among them, their first token |
| `llmhop_queued_requests`                       | `model`                    | requests waiting for a slot                                                |
| `llmhop_running_requests`                      | `model`, `client`          | requests holding a slot                                                    |
| `llmhop_max_running_requests`                  | `model`                    | the slots of the model, absent without `maxConcurrentRequests`             |
| `llmhop_client_max_running_requests`           | `client`                   | the slots of the client, absent without a limit                            |
| `llmhop_client_max_requests_per_minute`        | `client`                   | the requests per minute of the client, absent without a limit              |
| `llmhop_client_remaining_requests`             | `client`                   | the requests that remain to the client in its minute                       |
| `llmhop_server_up`                             | `model`, `server`          | whether the server passed its latest probe, absent without a `healthPath` |
| `llmhop_engine_*`                              | `model`, `server`          | what the engine of the server reports, absent without a `metricsPath`     |
| `process_*`, `go_*`                            |                            | the process of llmhop                                                      |

With a `metricsPath`, llmhop scrapes the Prometheus metrics of every server of a model when its metrics are requested, within two seconds, sharing a scrape with every request of the following second, so any number of viewers and scrapers costs an engine one scrape per second at most, and maps those of vLLM, SGLang and llama.cpp onto the same series, summed over the data-parallel ranks of a server: `running_requests`, `waiting_requests`, `kv_cache_usage_ratio` of its fullest rank, the counters `prompt_tokens_total`, `cached_prompt_tokens_total` and `generation_tokens_total`, and the sum and count of the times to the first token as `first_token_seconds`, each only if the engine reports it, beside `llmhop_engine_up`, which tells whether the server reported its metrics at all.
So one scrape covers the engines on unix sockets, which Prometheus cannot reach, and one dashboard every engine, while a remote backend such as OpenAI reports only what llmhop measures itself.
The counts survive a reload and reset on a restart.

llmhop logs JSON lines, among them one per answered request with `msg` `request`, its `id`, `method`, `path`, `status`, `bytes`, `duration` in seconds, `client`, `policy`, the requested `model` and `server`, and whether it was `aborted` after its status, such as a stream whose client left or that idled too long, which the latency histograms leave out.
Prompts and responses are never logged.

### Secret references

Strings in `models.*.headers` are expanded at startup, and an unresolved reference is a startup error:

- `${cred:name}`: the file `name` in `$CREDENTIALS_DIRECTORY` with trailing newlines trimmed, a systemd credential, or a secret of Docker, Compose or Podman, since the image sets `/run/secrets`. Its name starts with an ASCII letter, digit or `_` and continues with those, `.` and `-`, up to 255 characters, as the NixOS module requires.
- `${env:NAME}`: an environment variable, for platforms that pass secrets only that way.
- `$$`: a literal `$`.

### Request limits

- `maxBodyBytes` (100 MiB): larger bodies get `413`.
- `maxBufferedBytes` (1 GiB): bytes of body-routed requests buffered at once, further ones get `503` with `Retry-After: 1`. A body is buffered until the backend starts its response, and must arrive within a minute, or the request gets `408`.
- `models.*.maxConcurrentRequests` (unlimited): proxied requests per model over all its URLs, further ones get `429` with `Retry-After: 1`, see [clients and policies](#clients-and-policies) for those of a client.
- `models.*.queueTimeoutSeconds` (`0`): how long a request waits in line for a free slot before its `429`, holding its buffered body meanwhile.
- `models.*.responseTimeoutSeconds` (unlimited): how long a backend may take from receiving the whole request until its response headers, after which the request gets `504`. A streamed response may take longer after that.
- `models.*.streamIdleTimeoutSeconds` (unlimited): how long an event stream may send nothing before llmhop aborts it and frees its slot.

`0` disables a limit.

## Running

```sh
llmhop serve --config config.json
nix run github:mirkolenz/llmhop -- serve --config config.json
docker run --rm -p 8080:8080 -v ./config.json:/etc/llmhop/config.json ghcr.io/mirkolenz/llmhop
```

| Command                                   | Purpose                                                                  |
| ----------------------------------------- | ------------------------------------------------------------------------ |
| `serve`                                   | serve the gateway, reloading the config on `SIGHUP`                      |
| `check`                                   | validate the config without serving or reading secrets                   |
| `key list`                                | list the clients of `clientCredentials` with their policy and expiry     |
| `key create <client>`                     | store a key for a new client and print its token                         |
| `key update <client>`                     | change the policy or expiry of a client, keeping its key                 |
| `key rotate <client>`                     | replace the key of a client and print its token                          |
| `key revoke <client>`                     | delete the key of a client                                               |
| `key generate`                            | print a new token and its credential, storing nothing                    |
| `top`                                     | monitor the models, servers, clients, GPUs and host live                 |
| `usage [--by client\|model\|policy]`      | print the requests and errors of the log on stdin by group               |

Every command reads the config at `--config`, `$LLMHOP_CONFIG` or `/etc/llmhop/config.json`, `--help` explains each, and `--version` prints the version.
The image runs `serve`, so the mounted config must set `"listen": {"default": {"port": 8080}}`.

## NixOS and system-manager modules

Add the flake input `github:mirkolenz/llmhop` and import `llmhop.nixosModules.default` on NixOS or `llmhop.systemManagerModules.default` on other distributions with [system-manager](https://github.com/numtide/system-manager):

```nix
services.llmhop = {
  gateway.enable = true;
  gateway.listen.default = {
    host = "";
    port = 8080;
    openFirewall = true;
  };
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

The gateway runs as the `llmhop` user with one socket-activated `llmhop-<name>.socket` per enabled entry of `listen`, as in `listen.caddy.socketGroup = "caddy"` for a unix socket, or as a container on the host network receiving the same sockets, which loads an image archive of the same build, unless `container.image` names a registry reference such as `ghcr.io/mirkolenz/llmhop:latest`.
Each listener renders into `settings.listen.<name>` its `host` and `port`, or its `socket` without a `port`, which its socket must have, and `metrics`, and reaches llmhop by its name through `FileDescriptorName=`.
`settings.clients.<name>.listener = "ssh"` makes the requests on the unix socket of `listen.ssh` count as a client's without a key.
The gateway has no implicit listener and requires at least one, while a listener without `port` is a unix socket `/run/llmhop/<name>.sock`, as in `listen.admin = { socketGroup = "wheel"; metrics = true; }` for `llmhop top`.
`environment` and `environmentFile` are forwarded to the service.
Its generated config is validated at build time with `llmhop check`, routes every LoRA adapter as an alias and pins requests to the ranks of a model with `dataParallelSize`, see [balancing](#balancing-and-affinity).
Natively, a changed config reloads the gateway in place, without dropping a request.
Reference secrets in `settings` as `${cred:name}` and grant them through `credentials`.
`settings` declares a typed option for every field of the config, checked at evaluation time, which stays out of the config while `null`, and every workload merges into `models`:

```nix
services.llmhop.gateway.settings = {
  policies.guest = {
    models = [ "qwen3-*" ];
    requestsPerMinute = 10;
  };
  clientCredentials = true;
  models."openai/*".urls = [ "https://api.openai.com" ];
};
```

`clientCredentials = true` imports the keys of `/etc/credstore/llmhop.api-key.<client>`, or encrypted ones of `/etc/credstore.encrypted`, so clients come and go without a rebuild by adding or deleting their file.
Natively, `systemctl reload llmhop` then re-imports the credentials and reloads the config without a restart, while a container needs `systemctl restart llmhop`, whose sockets hold new connections meanwhile.
A reload keeps the in-memory limiters of the clients, while the restart of a container resets them.
The gateway installs `llmhop`, whose `key` commands do both as root.
`create` and `update` take `--policy <name>`, which must name an entry of `policies`, and `--expires` with a date, an RFC 3339 time or a validity such as `12h`, `30d` or `2w`, while `update` clears them with `--policy ''` and `--no-expires`.
It stores JSON credentials named `llmhop.api-key.<client>`, prints new tokens, keeps the key on `update`, and the policy, expiry and store on `rotate`.
`list` marks an unreadable credential and reports it after listing the others, while `update` and `rotate` refuse one, so revoke and create its key instead.

`llmhop top` monitors the gateway live, without root for the group of the metrics socket and remotely as `ssh -t <host> llmhop top`, which allocates the terminal it needs, until `q` quits.
It polls the metrics of llmhop on the first unix socket listener with `metrics` every two seconds and shows on one screen, as rates since the previous poll, with meters for shares, dots for servers and sparklines for the recent trend:

- the requests and tokens of the gateway over all models, and the CPUs, load, memory and swap of the host
- the GPUs with their utilization, memory, temperature, power, clock and throttling, as far as their drivers report them: those of NVIDIA through `nvidia-smi`, with the systemd units using their memory, those of AMD and Intel through sysfs, and those of Apple silicon through the I/O registry
- the models, with their ready servers, queued and running requests, the share of their slots in use, requests per second with the shares of them that its limits rejected with `429` or that failed with another client or a server error, the mean latency and time to the first token of their streams as clients see it, and from their engines the tokens per second, KV cache usage and prefix cache hits
- the clients, with whether they are active, their running requests, the shares of their slots and of their requests per minute in use, their share of the requests, and their requests per second with the shares of them rejected or failed

Its sections stack below each other, the gateway, the host, the GPUs, the models and the clients, whose tables group the columns of the requests that llmhop answers apart from those of the tokens that the engines process, which they report per model and server but not per client, each with columns whose widths follow from the fixed widths of their values, so they keep their place between polls.
Columns of less weight leave a narrow terminal first, while a short one loses the blank lines between the sections and then the clients.
It costs little to run for good: it keeps one `nvidia-smi` per query running in its loop mode rather than starting it for every poll, and redraws the terminal at most ten times a second, writing only what changed.
On macOS, the CPU usage, GPU temperature and power stay unknown, since only cgo or root reads them.

`llmhop usage` totals the requests and errors of the request lines of the log on stdin, so `top` shows the present and `usage` the past, while the log tool selects the source and the period:

```sh
journalctl -u llmhop -o cat --since -7d | llmhop usage --by model
docker logs --since 7d llmhop 2>&1 | llmhop usage
```

The gateway logs to the journal of `llmhop.service` natively and in a container alike.
The `key` commands, all but `generate`, manage the credentials of that service and need systemd.
An error is a response with a status from `400`, including the `429` of a rate limit.

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

Workloads sharing a `name` are replicas, which the gateway [balances](#balancing-and-affinity) as one model with the URL of each, while each keeps its own unit, port or socket and cache.
Unit names, caches, state directories, sockets and Podman volumes derive from a workload's attribute key rather than its `name`, so a model whose `name` differs from its key moves to new paths and downloads its repositories again.
Replicas restart without downtime, since the gateway avoids the one restarting, scale out llama.cpp, which has no data-parallel ranks, over several GPUs, and may mix engines:

```nix
services.llmhop.llama-cpp.models = lib.genAttrs [ "gpu0" "gpu1" ] (gpu: {
  name = "qwen3-8b";
  model = "unsloth/Qwen3-8B-GGUF:UD-Q4_K_XL";
  environment.CUDA_VISIBLE_DEVICES = lib.removePrefix "gpu" gpu;
});
```

Replicas must agree on what the gateway routes, their adapters, `dataParallelSize` and whether they are listed, which an assertion checks.

Each workload runs as the unit `<engine>-<key>`, named by its attribute rather than its `name`.
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

Evaluation rejects any port or unit claimed twice.
Customize the generated units directly, as in `systemd.services.vllm-qwen3-8b.serviceConfig.MemoryHigh = "64G"` or `virtualisation.quadlet.containers.vllm-qwen3-8b.containerConfig`.

Native llama.cpp and vLLM workers default to `port = null`, binding a unix socket below `socketDirectory` that only the backend's workers, the gateway and `socketClients` can reach.
Set `port` to bind `<host>:<port>` instead, which SGLang and every container always need.

#### Fetching and offline servers

Natively, each model has a fetcher `<engine>-<key>-fetch` that downloads everything into the model's own cache `cache.directory/<key>`, after which the server runs offline from it.
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

With `runtime = "container"`, every workload runs the backend's `container.image` on its published loopback `port` and downloads what it serves into the Podman volume `<engine>-<key>` when it starts, so a restart picks up a moved `revision`.
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

A path is loaded with `LoadCredential=`, which does not decrypt, so it must be plaintext, while an encrypted credential belongs in `/etc/credstore.encrypted`, imported by its name.
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
      credential = "llmhop.watermark-key.vllm.2026-10";
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
(umask 077; od -An -N8 -tu8 /dev/urandom | tr -d ' \n' > /etc/credstore/llmhop.watermark-key.vllm.2026-10)
```

vLLM reads the key through `key_file` of its `WatermarkConfig`, which requires a vLLM newer than 0.34.0.
SGLang reads its keys from its config file, which the watermark script writes into the server's private `/tmp`, and takes a second key for dual-key watermarking as `secondaryCredential`, such as `llmhop.watermark-key-b.sglang.2026-10`.
The keys default to `llmhop.watermark-key.<engine>`.
Its `settings` are SGLang's watermark config without `key` and `key_b`, such as `context_window` and `enforce_all`, which keeps clients from opting out.
The engines differ in their algorithms, so each detector only detects the watermarks of its own backend.
A detector reports the most significant profile with its Bonferroni-corrected `p_value`, `score`, `num_scored_tokens` and `is_watermarked`.
To rotate a key, provision it under a new credential name and keep a profile with the old one while old text still needs checking.
The gateway routes detectors as unlisted models by the `model` of the body, as in `POST /detect` with `{"model": "production", "text": "..."}`, since a detector ignores the `model`, or else by path, as in `POST /llmhop/proxy/production/detect`.
