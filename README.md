# runpod-llamacpp

A minimal Docker image that runs **llama.cpp** as an OpenAI-compatible API server,
designed for use on [RunPod](https://www.runpod.io/).

## Features

- Multi-stage build based on `debian:trixie` with CUDA packages from the official Debian repository
- llama.cpp `llama-server` and all companion tools (`llama-cli`, `llama-bench`, etc.) installed to `/usr/local/bin`
- llama.cpp `llama-server` with OpenAI-compatible `/v1/` endpoints (built-in Web UI included)
- API key protection via environment variable
- Root SSH access (key-based only) via environment variable
- All service output goes to container stdout/stderr (visible via `docker logs`)
- Optional automatic model download from Hugging Face, with DNS wait, resume and retry
- Watch mode: the container keeps running and starts `llama-server` automatically as soon as a model file appears (e.g. after an SSH upload)
- SSH-only mode: run just `sshd` without a model, then upload one and restart or let watch mode pick it up

## Environment Variables

All parameter names use the `LLAMA_*` prefix where possible to avoid clashes
with environment variables that RunPod sets itself.

| Variable | Default | Description |
|---|---|---|
| `LLAMA_API_KEY` | *(empty)* | API key required for every request. Leave empty to disable auth (not recommended). |
| `SSH_PUBLIC_KEY` | *(empty)* | SSH public key for root login (e.g. contents of `~/.ssh/id_ed25519.pub`). If not set, the container runs without SSH access. |
| `LLAMA_MODEL_PATH` | `/workspace/models` | Directory where model files live (RunPod network storage). |
| `LLAMA_MODEL_FILE` | *(empty)* | Filename of the GGUF model inside `LLAMA_MODEL_PATH`. If empty: no download and no `llama-server` — the container runs in SSH-only mode. |
| `LLAMA_CACHE_DIR` | `/workspace/cache` | Directory used by llama.cpp for KV-cache / disk offload. |
| `LLAMA_HOST` | `0.0.0.0` | Bind address for the HTTP server. |
| `LLAMA_PORT` | `9931` | Port for the HTTP server. |
| `LLAMA_CTX_SIZE` | `204800` | Context window size in tokens (`--ctx-size`). |
| `LLAMA_N_PARALLEL` | `1` | Number of parallel request slots (`--parallel`). |
| `LLAMA_N_GPU_LAYERS` | *(empty)* | Number of model layers to offload to the GPU. Empty = not passed to `llama-server` (llama.cpp decides). |
| `BATCH_SIZE` | `4096` | Batch size (`--batch-size`). |
| `CACHE_TYPE_K` | `q8_0` | KV-cache quantization type for K (`--cache-type-k`). Empty disables the flag. |
| `CACHE_TYPE_V` | `q8_0` | KV-cache quantization type for V (`--cache-type-v`). Empty disables the flag. |
| `SPEC_TYPE` | `draft-mtp` | Speculative decoding type (`--spec-type`). Empty disables speculation. |
| `SPEC_DRAFT_N_MAX` | `3` | Maximum number of speculative draft tokens (`--spec-draft-n-max`); only used when `SPEC_TYPE` is set. |
| `SPEC_DRAFT_TYPE_K` | `q8_0` | KV-cache type for the draft model, K component (`--spec-draft-type-k`); only used when `SPEC_TYPE` is set. |
| `SPEC_DRAFT_TYPE_V` | `q8_0` | KV-cache type for the draft model, V component (`--spec-draft-type-v`); only used when `SPEC_TYPE` is set. |
| `FIT_TARGET` | `512` | VRAM size target in MiB to fit the model into (`--fit-target`). |
| `METRICS` | `true` | Pass `--metrics` to enable the `/metrics` endpoint. Set to `false` to disable. |
| `REASONING_EFFORT` | `medium` | Reasoning effort for reasoning models (`--reasoning-effort`). Empty disables the flag. |
| `LOG_LEVEL` | `2` | Log verbosity for `llama-server` (`-lv`). |
| `ALIAS` | *(empty)* | Model alias reported by the server. Defaults to the model filename without extension. |
| `MODEL_AUTO_DOWNLOAD` | `false` | Set to `true` to download the model from Hugging Face at startup. Requires `HF_REPO` and `LLAMA_MODEL_FILE`. |
| `HF_REPO` | *(empty)* | Hugging Face repository (e.g. `TheBloke/Mistral-7B-Instruct-v0.2-GGUF`). |
| `DNS_WAIT_TIMEOUT` | `120` | Seconds to wait for DNS resolution of `huggingface.co` before giving up (on RunPod the network comes up late). |
| `DOWNLOAD_RETRIES` | `3` | Number of download attempts. Each attempt uses `curl -C -` (resume), so partial downloads are continued. |
| `WATCH_MODEL` | `true` | If no model is available at startup, keep the container alive and start `llama-server` automatically as soon as the model file appears (e.g. after an SSH upload). Set to `false` for a pure SSH-only standby. |
| `WATCH_MODEL_INTERVAL` | `10` | Polling interval in seconds for the watch mode. |
| `EXTRA_ARGS` | *(empty)* | Additional arguments appended to `llama-server` (split on whitespace; quotes not preserved). |

## Exposed Ports

| Port | Service |
|---|---|
| `9931` | llama.cpp HTTP API |
| `22` | SSH |

## Quick Start

### Using a local model file

On RunPod the network storage is automatically mounted into the container.
Point `LLAMA_MODEL_PATH` at the mount and set `LLAMA_MODEL_FILE` to the model
filename inside it.

```bash
docker run -d \
  -p 9931:9931 -p 2222:22 \
  -e LLAMA_API_KEY="mysecretkey" \
  -e SSH_PUBLIC_KEY="*** ~/.ssh/id_ed25519.pub)" \
  -e LLAMA_MODEL_PATH="/runpod-volume/models" \
  -e LLAMA_MODEL_FILE="mistral-7b.Q4_K_M.gguf" \
  -e LLAMA_CTX_SIZE=8192 \
  -e LLAMA_N_GPU_LAYERS=35 \
  bratstock/runpod-llamacpp
```

### Auto-downloading a model from Hugging Face

```bash
docker run -d \
  -p 9931:9931 -p 2222:22 \
  -e LLAMA_API_KEY="mysecretkey" \
  -e SSH_PUBLIC_KEY="*** ~/.ssh/id_ed25519.pub)" \
  -e MODEL_AUTO_DOWNLOAD=true \
  -e HF_REPO="TheBloke/Mistral-7B-Instruct-v0.2-GGUF" \
  -e LLAMA_MODEL_FILE="mistral-7b-instruct-v0.2.Q4_K_M.gguf" \
  bratstock/runpod-llamacpp
```

Before downloading, the entrypoint waits (up to `DNS_WAIT_TIMEOUT` seconds)
until DNS resolves `huggingface.co`, since RunPod's network is often not ready
at container start. The download resumes from a partial file and is retried
`DOWNLOAD_RETRIES` times.

### Calling the API

```bash
curl http://localhost:9931/v1/chat/completions \
  -H "Authorization: Bearer ***" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### SSH access

```bash
ssh -p 2222 root@localhost
```

### Watch mode and SSH-only mode

If `LLAMA_MODEL_FILE` is set but the file is not present (and auto download is
off), the container enters watch mode by default: `sshd` keeps running and
`llama-server` starts automatically once the model file appears with a stable
size (upload finished). You can therefore start the container, upload the
model via SSH, and the server starts on its own.

If `LLAMA_MODEL_FILE` is empty, the container runs in SSH-only mode: only
`sshd` is running, no download, no `llama-server`.

## Building

```bash
docker build -t runpod-llamacpp .
```
