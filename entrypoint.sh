#!/bin/bash
set -euo pipefail

# ── SSH setup ─────────────────────────────────────────────────────────────────
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "${SSH_PUBLIC_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "[entrypoint] SSH public key installed for root."
else
    echo "[entrypoint] WARNING: SSH_PUBLIC_KEY is not set. SSH login will not be possible."
fi

# Generate host keys if they are missing (first run)
ssh-keygen -A

# Start sshd in the background; log to stderr so it appears in docker logs
echo "[entrypoint] Starting sshd..."
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# ── llama-server setup ────────────────────────────────────────────────────────
mkdir -p "${CACHE_DIR}"

LLAMA_ARGS=(
    --host "${HOST}"
    --port "${PORT}"
    --ctx-size "${CTX_SIZE}"
    --parallel "${N_PARALLEL}"
    --n-gpu-layers "${N_GPU_LAYERS}"
)

# API key
if [ -n "${LLAMA_API_KEY:-}" ]; then
    LLAMA_ARGS+=(--api-key "${LLAMA_API_KEY}")
else
    echo "[entrypoint] WARNING: LLAMA_API_KEY is not set. The API will be accessible without authentication."
fi

# Model source: auto-download vs local file
if [ "${AUTO_DOWNLOAD}" = "true" ]; then
    if [ -z "${HF_REPO:-}" ] || [ -z "${HF_FILE:-}" ]; then
        echo "[entrypoint] ERROR: AUTO_DOWNLOAD=true but HF_REPO or HF_FILE is not set." >&2
        exit 1
    fi
    echo "[entrypoint] Auto-download enabled: ${HF_REPO} / ${HF_FILE}"
    LLAMA_ARGS+=(--hf-repo "${HF_REPO}" --hf-file "${HF_FILE}")
else
    if [ ! -f "${MODEL_PATH}" ]; then
        echo "[entrypoint] ERROR: Model file not found at ${MODEL_PATH} and AUTO_DOWNLOAD is not enabled." >&2
        exit 1
    fi
    LLAMA_ARGS+=(--model "${MODEL_PATH}")
fi

# Extra user-supplied arguments
if [ -n "${EXTRA_ARGS:-}" ]; then
    # Split EXTRA_ARGS on whitespace safely
    read -ra EXTRA_ARRAY <<< "${EXTRA_ARGS}"
    LLAMA_ARGS+=("${EXTRA_ARRAY[@]}")
fi

echo "[entrypoint] Starting llama-server..."

# Run llama-server in the foreground; its stdout/stderr go to the container log.
llama-server "${LLAMA_ARGS[@]}" &
LLAMA_PID=$!

# ── Wait for either process to exit ──────────────────────────────────────────
wait -n "${SSHD_PID}" "${LLAMA_PID}"
EXIT_CODE=$?

echo "[entrypoint] A child process exited with code ${EXIT_CODE}. Shutting down."
kill "${SSHD_PID}" "${LLAMA_PID}" 2>/dev/null || true
exit "${EXIT_CODE}"
