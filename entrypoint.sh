#!/bin/bash
set -euo pipefail

# ── Konfiguration ─────────────────────────────────────────────────────────────
# Alle Parameter haben sinnvolle Defaults und können per ENV-Variablen
# (z. B. im RunPod-Template) überschrieben werden.
# Parameter mit Flag-Default lassen sich durch Leeren deaktivieren
# (z. B. SPEC_TYPE="", METRICS=false, REASONING_EFFORT="").

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-9931}"
LOG_LEVEL="${LOG_LEVEL:-4}"
CTX_SIZE="${CTX_SIZE:-204800}"
N_PARALLEL="${N_PARALLEL:-1}"
N_GPU_LAYERS="${N_GPU_LAYERS:-}"            # leer → Argument wird nicht gesetzt (llama.cpp entscheidet)
BATCH_SIZE="${BATCH_SIZE:-4096}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
SPEC_TYPE="${SPEC_TYPE:-draft-mtp}"
SPEC_DRAFT_N_MAX="${SPEC_DRAFT_N_MAX:-3}"
SPEC_DRAFT_TYPE_K="${SPEC_DRAFT_TYPE_K:-q8_0}"
SPEC_DRAFT_TYPE_V="${SPEC_DRAFT_TYPE_V:-q8_0}"
FIT_TARGET="${FIT_TARGET:-512}"
METRICS="${METRICS:-true}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
LLAMA_API_KEY="${LLAMA_API_KEY:-SuperSecretApiToken123}"

MODEL_PATH="${MODEL_PATH:-/workspace/models}"
MODEL_FILE="${MODEL_FILE:-}"
CACHE_DIR="${CACHE_DIR:-/workspace/cache}"

# Download/Netzwerk
DNS_TARGET_HOST="huggingface.co"
DNS_WAIT_TIMEOUT="${DNS_WAIT_TIMEOUT:-120}"     # Sek. warten, bis DNS auflöst (RunPod: Netz startet spät)
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-3}"       # Äußere Download-Versuche (curl hat zusätzlich --retry)
WATCH_MODEL="${WATCH_MODEL:-true}"              # true → nach manuellem SSH-Upload llama-server automatisch starten
WATCH_MODEL_INTERVAL="${WATCH_MODEL_INTERVAL:-10}"

# Alias: Default = Modell-Dateiname ohne Endung
# (Qwen3.8-27B-UD-Q5_K_XL.gguf → Qwen3.8-27B-UD-Q5_K_XL), per ALIAS überschreibbar.
if [ -n "${MODEL_FILE}" ]; then
    MODEL_BASENAME="$(basename "${MODEL_FILE}")"
    ALIAS="${ALIAS:-${MODEL_BASENAME%.*}}"
else
    ALIAS="${ALIAS:-}"
fi

SSHD_PID=""
LLAMA_PID=""
CLEANUP_EXIT_CODE=0

cleanup() {
    echo "[entrypoint] Shutting down cleanly..."
    if [ -n "${SSHD_PID}" ]; then kill -TERM "${SSHD_PID}" 2>/dev/null || true; fi
    if [ -n "${LLAMA_PID}" ]; then kill -TERM "${LLAMA_PID}" 2>/dev/null || true; fi
    exit "${CLEANUP_EXIT_CODE}"
}
trap cleanup SIGTERM SIGINT

# ── Hilfsfunktionen ───────────────────────────────────────────────────────────
dns_resolved() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts "${DNS_TARGET_HOST}" >/dev/null 2>&1
    elif command -v host >/dev/null 2>&1; then
        host "${DNS_TARGET_HOST}" >/dev/null 2>&1
    elif command -v nslookup >/dev/null 2>&1; then
        nslookup "${DNS_TARGET_HOST}" >/dev/null 2>&1
    else
        curl -sI --max-time 5 "https://${DNS_TARGET_HOST}/" >/dev/null 2>&1
    fi
}

# Wartet, bis der DNS-Resolver den Hostnamen auflöst. Auf RunPod ist beim
# Container-Start oft noch kein DNS verfügbar — daher Timeout-Loop statt
# einmaligem Versuch.
wait_for_dns() {
    local waited=0
    echo "[entrypoint] Waiting for DNS resolution of ${DNS_TARGET_HOST} (max ${DNS_WAIT_TIMEOUT}s)..."
    while ! dns_resolved; do
        if [ "${waited}" -ge "${DNS_WAIT_TIMEOUT}" ]; then
            echo "[entrypoint] ERROR: DNS for ${DNS_TARGET_HOST} not resolvable after ${waited}s." >&2
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
        echo "[entrypoint] DNS not ready yet (${waited}s/${DNS_WAIT_TIMEOUT}s)..."
    done
    echo "[entrypoint] ✓ DNS OK: ${DNS_TARGET_HOST} → $(getent hosts "${DNS_TARGET_HOST}" 2>/dev/null | awk '{print $1}' | head -1)"
    return 0
}

# Download mit Resume (-C -) und Retry. Teil-Dateien bleiben bei
# Zwischenfehlern erhalten, damit der nächste Versuch fortgesetzt wird.
download_model() {
    local dest="${MODEL_PATH}/${MODEL_FILE}"
    local attempt
    for (( attempt=1; attempt<=DOWNLOAD_RETRIES; attempt++ )); do
        echo "[entrypoint] Download attempt ${attempt}/${DOWNLOAD_RETRIES}: ${HF_URL}"

        if command -v curl >/dev/null 2>&1; then
            # -L Redirects (HF → CDN), -C - Resume, -f Fehler bei 404/401,
            # --retry 3: automatische Retries bei transienten Fehlern
            if curl -L -C -f --progress-bar --connect-timeout 10 --retry 3 --retry-delay 10 \
                -o "${dest}" "${HF_URL}"; then
                echo "[entrypoint] ✓ Download successfully completed!"
                return 0
            fi
        fi
        if command -v wget >/dev/null 2>&1; then
            if wget -c -O "${dest}" "${HF_URL}"; then
                echo "[entrypoint] ✓ Download successfully completed!"
                return 0
            fi
        fi

        echo "[entrypoint] Download attempt ${attempt}/${DOWNLOAD_RETRIES} failed." >&2
        if [ "${attempt}" -lt "${DOWNLOAD_RETRIES}" ]; then
            sleep 10
        fi
    done
    return 1
}

# Wartet, bis die Datei vorhanden UND ihre Größe stabil ist (Upload fertig).
wait_for_stable_file() {
    local file="$1"
    local last_size=""
    while true; do
        local size
        size=$(stat -c%s "${file}" 2>/dev/null || echo "")
        if [ -n "${size}" ] && [ "${size}" = "${last_size}" ]; then
            return 0
        fi
        last_size="${size}"
        sleep 10
    done
}

# Watch-Mode: Der Container bleibt am Leben (sshd läuft weiter) und der
# llama-server startet automatisch, sobald das Modell auftaucht — z. B.
# nach einem manuellen Upload per SSH.
watch_for_model() {
    echo "[entrypoint] Watch mode: waiting for ${MODEL_PATH}/${MODEL_FILE} ..."
    while true; do
        if [ -f "${MODEL_PATH}/${MODEL_FILE}" ]; then
            echo "[entrypoint] Model file detected. Waiting for stable size (upload complete)..."
            wait_for_stable_file "${MODEL_PATH}/${MODEL_FILE}"
            echo "[entrypoint] ✓ Model ready: ${MODEL_PATH}/${MODEL_FILE} ($(stat -c%s "${MODEL_PATH}/${MODEL_FILE}") bytes)"
            return 0
        fi
        sleep "${WATCH_MODEL_INTERVAL}"
    done
}

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

# ── Modell: Download, falls angefordert ───────────────────────────────────────
# MODEL_FILE leer → weder Download noch llama-server; der Container läuft
# nur mit sshd weiter (SSH-Only-Modus).
START_LLAMA=false

if [ -z "${MODEL_FILE}" ]; then
    echo "[entrypoint] NOTICE: MODEL_FILE is not set. Skipping model download and llama-server."
    echo "[entrypoint] Entering SSH-ONLY mode."
elif [ -f "${MODEL_PATH}/${MODEL_FILE}" ]; then
    START_LLAMA=true
elif [ "${AUTO_DOWNLOAD:-false}" = "true" ]; then
    if [ -z "${HF_REPO:-}" ]; then
        echo "[entrypoint] ERROR: AUTO_DOWNLOAD=true but HF_REPO is not set." >&2
        exit 1
    fi

    # Zielverzeichnis im persistenten Speicher sicherstellen
    mkdir -p "${MODEL_PATH}"

    # Die offizielle HF-Download-URL (huggingface.co, nicht .com)
    HF_URL="https://huggingface.co/${HF_REPO}/resolve/main/${MODEL_FILE}"
    echo "[entrypoint] Preparing download for: ${HF_REPO} / ${MODEL_FILE}"

    # Zuerst DNS warten — auf RunPod ist der Resolver beim Container-Start
    # häufig noch nicht betriebsbereit.
    if wait_for_dns; then
        if ! download_model; then
            echo "[entrypoint] ERROR: All ${DOWNLOAD_RETRIES} download attempts failed." >&2
            # Teil-Datei löschen, damit der Watch-Mode keine korrupte Datei annimmt
            rm -f "${MODEL_PATH}/${MODEL_FILE}"
        else
            START_LLAMA=true
        fi
    else
        rm -f "${MODEL_PATH}/${MODEL_FILE}"
    fi
fi

if [ "${START_LLAMA}" = "false" ] && [ -n "${MODEL_FILE}" ]; then
    echo "[entrypoint] NOTICE: No model available at ${MODEL_PATH}/${MODEL_FILE}."
    if [ "${WATCH_MODEL}" = "true" ]; then
        echo "[entrypoint] Entering watch mode: upload the model (e.g. via SSH) and"
        echo "[entrypoint] the server will start automatically once it appears."
        watch_for_model
        START_LLAMA=true
    else
        echo "[entrypoint] Entering SSH-ONLY standby mode. Upload a model or restart with AUTO_DOWNLOAD=true."
    fi
fi

# ── llama-server execution ────────────────────────────────────────────────────
if [ "${START_LLAMA}" = "true" ]; then
    mkdir -p "${CACHE_DIR}"

    LLAMA_ARGS=(
        --host "${HOST}"
        --port "${PORT}"
        -lv "${LOG_LEVEL}"
        --ctx-size "${CTX_SIZE}"
        --parallel "${N_PARALLEL}"
        --model "${MODEL_PATH}/${MODEL_FILE}"   # Wir starten IMMER mit dem lokalen Pfad!
    )

    if [ -n "${ALIAS}" ]; then
        LLAMA_ARGS+=(--alias "${ALIAS}")
    fi

    if [ -n "${N_GPU_LAYERS}" ]; then
        LLAMA_ARGS+=(--n-gpu-layers "${N_GPU_LAYERS}")
    fi
    if [ -n "${BATCH_SIZE}" ]; then
        LLAMA_ARGS+=(--batch-size "${BATCH_SIZE}")
    fi
    if [ -n "${CACHE_TYPE_K}" ]; then
        LLAMA_ARGS+=(--cache-type-k "${CACHE_TYPE_K}")
    fi
    if [ -n "${CACHE_TYPE_V}" ]; then
        LLAMA_ARGS+=(--cache-type-v "${CACHE_TYPE_V}")
    fi
    if [ -n "${SPEC_TYPE}" ]; then
        LLAMA_ARGS+=(--spec-type "${SPEC_TYPE}")
        if [ -n "${SPEC_DRAFT_N_MAX}" ]; then
            LLAMA_ARGS+=(--spec-draft-n-max "${SPEC_DRAFT_N_MAX}")
        fi
        if [ -n "${SPEC_DRAFT_TYPE_K}" ]; then
            LLAMA_ARGS+=(--spec-draft-type-k "${SPEC_DRAFT_TYPE_K}")
        fi
        if [ -n "${SPEC_DRAFT_TYPE_V}" ]; then
            LLAMA_ARGS+=(--spec-draft-type-v "${SPEC_DRAFT_TYPE_V}")
        fi
    fi
    if [ -n "${FIT_TARGET}" ]; then
        LLAMA_ARGS+=(--fit-target "${FIT_TARGET}")
    fi
    if [ "${METRICS}" = "true" ]; then
        LLAMA_ARGS+=(--metrics)
    fi
    if [ -n "${REASONING_EFFORT}" ]; then
        LLAMA_ARGS+=(--reasoning-effort "${REASONING_EFFORT}")
    fi
    if [ -n "${LLAMA_API_KEY}" ]; then
        LLAMA_ARGS+=(--api-key "${LLAMA_API_KEY}")
    else
        echo "[entrypoint] WARNING: LLAMA_API_KEY is not set. The API will be accessible without authentication."
    fi

    if [ -n "${EXTRA_ARGS:-}" ]; then
        read -r -a EXTRA_ARRAY <<< "${EXTRA_ARGS}"
        LLAMA_ARGS+=("${EXTRA_ARRAY[@]}")
    fi

    # API-Key in den Logs maskieren
    if [ -n "${LLAMA_API_KEY}" ]; then
        echo "[entrypoint] Starting llama-server: ${LLAMA_ARGS[*]//${LLAMA_API_KEY}/<api-key>}"
    else
        echo "[entrypoint] Starting llama-server: ${LLAMA_ARGS[*]}"
    fi

    llama-server "${LLAMA_ARGS[@]}" &
    LLAMA_PID=$!
fi

# ── Prozess-Überwachung ───────────────────────────────────────────────────────
if [ -n "${LLAMA_PID}" ]; then
    set +e
    wait -n "${SSHD_PID}" "${LLAMA_PID}"
    EXIT_CODE=$?
    set -e
    echo "[entrypoint] A monitored process exited with code ${EXIT_CODE}. Shutting down."
    CLEANUP_EXIT_CODE="${EXIT_CODE}"
else
    set +e
    wait "${SSHD_PID}"
    EXIT_CODE=$?
    set -e
    echo "[entrypoint] sshd exited with code ${EXIT_CODE}. Shutting down."
    CLEANUP_EXIT_CODE="${EXIT_CODE}"
fi
cleanup
