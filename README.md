# runpod-llamacpp

A minimal Docker image that runs **llama.cpp** as an OpenAI-compatible API server,
designed for use on [RunPod](https://www.runpod.io/).

## Features

- Multi-stage build based on `nvidia/cuda:13.3.0` (CUDA GPU support out of the box)
- llama.cpp `llama-server` and all companion tools (`llama-cli`, `llama-bench`, etc.) installed to `/usr/local/bin`
- llama.cpp `llama-server` with OpenAI-compatible `/v1/` endpoints
- API key protection via environment variable
- Root SSH access (key-based only) via environment variable
- All service output goes to container stdout/stderr (visible via `docker logs`)
- Optional automatic model download from Hugging Face

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `LLAMA_API_KEY` | *(empty)* | API key required for every request. Leave empty to disable auth (not recommended). |
| `SSH_PUBLIC_KEY` | *(empty)* | SSH public key for root login (e.g. contents of `~/.ssh/id_ed25519.pub`). |
| `MODEL_PATH` | `/opt/models/model.gguf` | Path to the GGUF model file inside the container. |
| `CACHE_DIR` | `/opt/cache` | Directory used by llama.cpp for KV-cache / disk offload. |
| `AUTO_DOWNLOAD` | `false` | Set to `true` to download the model from Hugging Face at startup. Requires `HF_REPO` and `HF_FILE`. |
| `HF_REPO` | *(empty)* | Hugging Face repository (e.g. `TheBloke/Mistral-7B-Instruct-v0.2-GGUF`). |
| `HF_FILE` | *(empty)* | Filename inside the HF repository (e.g. `mistral-7b-instruct-v0.2.Q4_K_M.gguf`). |
| `N_GPU_LAYERS` | `0` | Number of model layers to offload to GPU (0 = CPU only). |
| `CTX_SIZE` | `4096` | Context window size in tokens. |
| `N_PARALLEL` | `1` | Number of parallel request slots. |
| `HOST` | `0.0.0.0` | Bind address for the HTTP server. |
| `PORT` | `8080` | Port for the HTTP server. |
| `EXTRA_ARGS` | *(empty)* | Additional arguments appended to `llama-server` (split on whitespace; quotes not preserved). |

## Exposed Ports

| Port | Service |
|---|---|
| `8080` | llama.cpp HTTP API |
| `22` | SSH |

## Quick Start

### Using a local model file

On RunPod the network storage is automatically mounted into the container. Pass the full path to the model file via `MODEL_PATH`.

```bash
docker run -d \
  -p 8080:8080 -p 2222:22 \
  -e LLAMA_API_KEY="mysecretkey" \
  -e SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e MODEL_PATH="/runpod-volume/models/mistral-7b.Q4_K_M.gguf" \
  -e CTX_SIZE=8192 \
  -e N_GPU_LAYERS=35 \
  bratstock/runpod-llamacpp
```

### Auto-downloading a model from Hugging Face

```bash
docker run -d \
  -p 8080:8080 -p 2222:22 \
  -e LLAMA_API_KEY="mysecretkey" \
  -e SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e AUTO_DOWNLOAD=true \
  -e HF_REPO="TheBloke/Mistral-7B-Instruct-v0.2-GGUF" \
  -e HF_FILE="mistral-7b-instruct-v0.2.Q4_K_M.gguf" \
  bratstock/runpod-llamacpp
```

### Calling the API

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $LLAMA_API_KEY" \
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

## Building

```bash
docker build -t runpod-llamacpp .
```
