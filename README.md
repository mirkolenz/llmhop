# LLMhop

One port, many models — a tiny, stateless HTTP router for OpenAI-compatible LLM inference backends.

LLMhop peeks at the `model` field of an incoming OpenAI-compatible request and reverse-proxies it to the matching backend.
It is primarily designed for single-model inference servers like [vLLM](https://github.com/vllm-project/vllm) and [sglang](https://github.com/sgl-project/sglang) that serve one model per process and need a thin model-aware gateway in front of them, but it works with any OpenAI-compatible backend — including multi-model servers and hosted providers — whenever you want to consolidate several upstreams behind a single endpoint.

## Features

- OpenAI-compatible reverse proxy, model router and request dispatcher for self-hosted LLM inference.
- Stateless single-binary HTTP service — no database, no cache, no background workers, safe behind any load balancer.
- Zero external dependencies: pure Go, no third-party packages, no CGO.
- Works with any OpenAI API-compatible backend, self-hosted or remote: vLLM, sglang, TabbyAPI, Aphrodite, Ollama, LocalAI, OpenRouter, together.ai, DeepInfra, etc.
- Ships as a static binary, a minimal Docker image and a hardened NixOS module.

## How it works

1. Client sends a request with a JSON body containing `{"model": "..."}`.
2. LLMhop reads the `model` field and looks it up in its config.
3. The request is forwarded verbatim to the configured backend URL.
4. Unknown models return `404`.

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

- `${env:NAME}` — read from the `NAME` environment variable.
- `${file:path}` — read from a file. Relative paths are resolved against `$CREDENTIALS_DIRECTORY` when set (e.g. when launched by systemd with `LoadCredential=`), otherwise against the current working directory. A single trailing newline is trimmed.
- `$NAME` — shorthand for `${env:NAME}`.

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
