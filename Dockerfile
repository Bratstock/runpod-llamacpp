# ==========================================
# STAGE 1: Build (Debian Trixie with the native CUDA compiler)
# ==========================================
FROM debian:trixie AS builder
ENV DEBIAN_FRONTEND=noninteractive

# IMPORTANT: enable contrib and non-free for the package repositories of the build stage
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

# Set the path for the native Debian nvcc compiler
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
# STAGE 2: Runtime (lean Debian Trixie)
# ==========================================
FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Berlin

# IMPORTANT: enable contrib and non-free for the runtime stage as well
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

# Register the path of the native Debian NVIDIA libraries
ENV LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/nvidia:${LD_LIBRARY_PATH}"

# Take over the compiled server and libraries from stage 1
COPY --from=builder /app/dist/ /usr/local/
RUN ldconfig

# Entrypoint and SSH configuration
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Nginx was removed because llama-server ships the web UI directly!
RUN mkdir -p /var/run/sshd /root/.ssh && chmod 700 /root/.ssh
RUN sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config

EXPOSE 22 9931

# All configuration defaults live centrally in entrypoint.sh —
# no environment variables are intentionally set here.

ENTRYPOINT ["/entrypoint.sh"]
