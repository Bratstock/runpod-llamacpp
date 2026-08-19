# Stage 1: Build llama.cpp
FROM debian:trixie-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG LLAMA_CPP_REF="master"
RUN git clone --depth=1 --branch "${LLAMA_CPP_REF}" https://github.com/ggerganov/llama.cpp.git && \
    cd llama.cpp && \
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF && \
    cmake --build build --config Release -j$(nproc) --target llama-server

# Stage 2: Runtime image
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    ca-certificates \
    curl \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Copy llama-server binary
COPY --from=builder /build/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Prepare SSH directory
RUN mkdir -p /var/run/sshd /root/.ssh && \
    chmod 700 /root/.ssh

# Disable password authentication; only key-based auth allowed
RUN sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

# llama.cpp API default port
EXPOSE 8080
# SSH default port
EXPOSE 22

# ── Environment variables ──────────────────────────────────────────────────────
# API key for llama.cpp OpenAI-compatible endpoint (required)
ENV LLAMA_API_KEY=""

# SSH public key for root login (required for SSH access)
ENV SSH_PUBLIC_KEY=""

# Path to the GGUF model file inside the container
ENV MODEL_PATH="/models/model.gguf"

# Cache / KV-cache directory used by llama.cpp
ENV CACHE_DIR="/cache"

# Set to "true" to allow llama.cpp to download models from Hugging Face at startup
# (maps to --hf-repo / --hf-file or similar flags; see entrypoint.sh)
ENV AUTO_DOWNLOAD="false"

# Hugging Face repo and file to download when AUTO_DOWNLOAD=true
ENV HF_REPO=""
ENV HF_FILE=""

# Number of GPU layers to offload (0 = CPU only)
ENV N_GPU_LAYERS="0"

# Context size
ENV CTX_SIZE="4096"

# Number of parallel request slots
ENV N_PARALLEL="1"

# Bind host for the HTTP server
ENV HOST="0.0.0.0"

# Port for the HTTP server
ENV PORT="8080"

# Any extra arguments appended to llama-server (whitespace-split; quotes not preserved)
ENV EXTRA_ARGS=""

VOLUME ["/models", "/cache"]

ENTRYPOINT ["/entrypoint.sh"]
