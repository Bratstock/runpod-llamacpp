# ==========================================
# STAGE 1: Build (Debian Trixie mit nativem CUDA Compiler)
# ==========================================
FROM debian:trixie AS builder
ENV DEBIAN_FRONTEND=noninteractive

# WICHTIG: contrib und non-free für die Paketquellen der Build-Stage aktivieren
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources

#RUN cat /etc/apt/sources.list.d/debian.sources && false

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    cmake \
    build-essential \
    libcurl4-openssl-dev \
    nvidia-cuda-toolkit \
    && rm -rf /var/lib/apt/lists/*

# Pfad für den nativen Debian-nvcc Compiler setzen
ENV PATH="/usr/lib/nvidia-cuda-toolkit/bin:${PATH}"

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
# STAGE 2: Runtime (Schlankes & Sicheres Debian Trixie)
# ==========================================
FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin

# WICHTIG: contrib und non-free auch für die Runtime-Stage aktivieren
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    libcurl4 \
    libgomp1 \
    openssh-server \
    wget \
    libcuda1 \
    libcublas12 \
    libcudart12 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Pfad für die nativen Debian-NVIDIA-Bibliotheken registrieren
ENV LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/nvidia:${LD_LIBRARY_PATH}"

# Kompilierten Server und Bibliotheken aus Stage 1 übernehmen
COPY --from=builder /app/dist/ /usr/local/
RUN ldconfig

# Entrypoint und SSH-Konfiguration
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Nginx wurde entfernt, da llama-server das Web-UI direkt mitbringt!
RUN mkdir -p /var/run/sshd /root/.ssh && chmod 700 /root/.ssh
RUN sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

EXPOSE 22 8080

ENV LLAMA_API_KEY="" \
    SSH_PUBLIC_KEY="" \
    MODEL_PATH="/opt/models/model.gguf" \
    CACHE_DIR="/opt/cache" \
    AUTO_DOWNLOAD="false" \
    HF_REPO="" \
    HF_FILE="" \
    N_GPU_LAYERS="0" \
    CTX_SIZE="4096" \
    N_PARALLEL="1" \
    HOST="0.0.0.0" \
    PORT="8080" \
    EXTRA_ARGS=""

ENTRYPOINT ["/entrypoint.sh"]
