# Shared base: debian:trixie-slim with Nvidia CUDA 13.3 apt repository configured
FROM debian:trixie AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget gnupg git cmake build-essential libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Offizielles NVIDIA Repository für Debian 13 (Trixie) einbinden
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && rm cuda-keyring_1.1-1_all.deb

# Das aktuelle CUDA-13 Toolkit für den Compiler installieren
RUN apt-get update && apt-get install -y --no-install-recommends \
    cuda-toolkit-13-3 \
    && rm -rf /var/lib/apt/lists/*

# Pfade für den NVIDIA-Compiler (nvcc) setzen
ENV PATH="/usr/local/cuda-13.3/bin:${PATH}"

WORKDIR /app

ARG LLAMA_CPP_REF="master"
RUN git clone --depth=1 --branch "${LLAMA_CPP_REF}" https://github.com/ggerganov/llama.cpp.git .

RUN mkdir build
WORKDIR /app/build

RUN cmake .. \
    -DGGML_CUDA=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CUDA=ARCHITECTURES=all \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_BUILD_SERVER=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX=/app/dist
RUN cmake --build . --config Release -j$(nproc)
RUN cmake --install . --prefix /app/dist

# ==========================================
# STAGE 2: Runtime (Sicheres Debian Trixie mit HTTPS & SSH)
# ==========================================
FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin

# 1. Systempakete, Nginx (HTTPS-Proxy) und OpenSSH installieren
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget gnupg curl nginx openssh-server libcurl4 \
    && rm -rf /var/lib/apt/lists/*

# 2. NVIDIA Repository auch in der Runtime aktivieren
RUN wget https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i cuda-keyring_1.1-1_all.deb && rm cuda-keyring_1.1-1_all.deb

# 3. Nur die für die Ausführung notwendige CUDA-13-Laufzeitbibliothek installieren
RUN apt-get update && apt-get install -y --no-install-recommends \
    cuda-cudart-13-3 \
    && rm -rf /var/lib/apt/lists/*

# Systempfad für die GPU-Bibliotheken hinterlegen
ENV LD_LIBRARY_PATH="/usr/local/cuda-13.3/lib64:${LD_LIBRARY_PATH}"

# Kompilierten Server aus Stage 1 übernehmen
COPY --from=builder /app/dist/* /usr/local
RUN ldconfig

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

# SSH default port
EXPOSE 22
# nginx
EXPOSE 80 443
# llama.cpp API default port
EXPOSE 8080

# ── Environment variables ──────────────────────────────────────────────────────
# API key for llama.cpp OpenAI-compatible endpoint (required)
ENV LLAMA_API_KEY=""

# SSH public key for root login (required for SSH access)
ENV SSH_PUBLIC_KEY=""

# Path to the GGUF model file inside the container
ENV MODEL_PATH="/opt/models/model.gguf"

# Cache / KV-cache directory used by llama.cpp
ENV CACHE_DIR="/opt/cache"

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

ENTRYPOINT ["/entrypoint.sh"]
