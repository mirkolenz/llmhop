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

LLMhop is deliberately auth-agnostic: headers (including `Authorization`, `api-key`, etc.) are forwarded verbatim, and the router never inspects, injects or rewrites API tokens.
This makes it compatible with protected endpoints, but it also means your client is responsible for supplying the correct credentials per model — either by sending the right token for each request or by sharing a single token across all configured backends.
Per-backend credential injection may be added to LLMhop in the future.

## Configuration

Create a `config.json`:

```json
{
  "listen": ":8080",
  "models": {
    "llama-3-8b": { "url": "http://localhost:30000" },
    "qwen-2.5-7b": { "url": "http://localhost:30001" }
  }
}
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
Import the flake's NixOS module and enable the service:

```nix
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
```

The unit runs under `DynamicUser` with aggressive sandboxing (`ProtectSystem`, `PrivateTmp`, restricted syscalls and address families, no new privileges, ...) and restarts on failure.
