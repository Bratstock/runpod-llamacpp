#!/bin/bash
set -euo pipefail

SSHD_PID=""
LLAMA_PID=""

cleanup() {
    echo "[entrypoint] SIGTERM/SIGINT received. Shutting down cleanly..."
    if [ -n "${SSHD_PID}" ]; then kill -TERM "${SSHD_PID}" 2>/dev/null || true; fi
    if [ -n "${LLAMA_PID}" ]; then kill -TERM "${LLAMA_PID}" 2>/dev/null || true; fi
    exit 0
}
trap cleanup SIGTERM SIGINT

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

# ── Dynamischer HuggingFace Download ──────────────────────────────────────────
if [ "${AUTO_DOWNLOAD}" = "true" ]; then
    if [ -z "${HF_REPO:-}" ] || [ -z "${MODEL_FILE:-}" ]; then
        echo "[entrypoint] ERROR: AUTO_DOWNLOAD=true but HF_REPO or MODEL_FILE is not set." >&2
        exit 1
    fi

    # Zielverzeichnis im persistenten Speicher sicherstellen
    if [ ! -d "${MODEL_PATH}"]; then
        mkdir -p "${MODEL_PATH}"
    fi

    if [ -f "${MODEL_PATH}/${MODEL_FILE}" ]; then
        echo "[entrypoint] Model already exists at ${MODEL_PATH}/${MODEL_FILE}. Skipping download."
    else
        echo "[entrypoint] Preparing download for: ${HF_REPO} / ${MODEL_FILE}"

        # Das mathematische Zusammensetzen der offiziellen HF-Download-URL
        HF_URL="https://huggingface.com/${HF_REPO}/resolve/main/${MODEL_FILE}"

        echo "[entrypoint] Downloading from: ${HF_URL}"
        echo "[entrypoint] Saving to: ${MODEL_PATH}/${MODEL_FILE}"

        # curl Parameter:
        # -L (Folgt Redirects auf die AWS-S3-Server von HF)
        # -C - (Setzt abgebrochene Downloads fort, falls der Pod mal neustartet)
        # -f (Wirft Fehlermeldung bei 404/401 statt HTML zu speichern)
        if curl -L -C - -f --progress-bar -o "${MODEL_PATH}/${MODEL_FILE}" "${HF_URL}"; then
            echo "[entrypoint] ✓ Download successfully completed!"
        else
            echo "[entrypoint] ERROR: Download failed. Please check HF_REPO and MODEL_FILE." >&2
            # Datei bei Fehlschlag löschen, um beim nächsten Boot keinen korrupten Zustand zu haben
            rm -f "${MODEL_PATH}/${MODEL_FILE}"
            exit 1
        fi
    fi
fi

# ── llama-server Start-Check ──────────────────────────────────────────────────
START_LLAMA=true

if [ ! -f "${MODEL_PATH}/${MODEL_FILE}" ]; then
    echo "[entrypoint] NOTICE: No model found at ${MODEL_PATH}/${MODEL_FILE}."
    echo "[entrypoint] Entering SSH-ONLY standby mode. Upload a model or restart with AUTO_DOWNLOAD=true."
    START_LLAMA=false
fi

# ── llama-server execution ────────────────────────────────────────────────────
if [ "${START_LLAMA}" = "true" ]; then
    mkdir -p "${CACHE_DIR}"

    LLAMA_ARGS=(
        --host "${HOST}"
        --port "${PORT}"
        --ctx-size "${CTX_SIZE}"
        --parallel "${N_PARALLEL}"
        --n-gpu-layers "${N_GPU_LAYERS}"
        --model "${MODEL_PATH}/${MODEL_FILE}" # Wir starten IMMER mit dem lokalen Pfad!
    )

    if [ -n "${LLAMA_API_KEY:-}" ]; then
        LLAMA_ARGS+=(--api-key "${LLAMA_API_KEY}")
    else
        echo "[entrypoint] WARNING: LLAMA_API_KEY is not set. The API will be accessible without authentication."
    fi

    if [ -n "${EXTRA_ARGS:-}" ]; then
        read -r -a EXTRA_ARRAY <<< "${EXTRA_ARGS}"
        LLAMA_ARGS+=("${EXTRA_ARRAY[@]}")
    fi

    echo "[entrypoint] Starting llama-server..."
    llama-server "${LLAMA_ARGS[@]}" &
    LLAMA_PID=$!
fi

# ── Prozess-Überwachung ───────────────────────────────────────────────────────
if [ -n "${LLAMA_PID}" ]; then
    wait -n "${SSHD_PID}" "${LLAMA_PID}"
else
    wait "${SSHD_PID}"
fi

EXIT_CODE=$?
echo "[entrypoint] A monitored process exited with code ${EXIT_CODE}. Shutting down."
cleanup
