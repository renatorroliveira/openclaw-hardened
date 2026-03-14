#!/bin/bash
# ==============================================================================
# ollama-entrypoint.sh — Start Ollama server and preload models
# ==============================================================================
set -euo pipefail

# Add or remove Ollama model tags here to change which models are pulled on
# startup. The pull loop below skips models already present in the volume.
# Examples: "qwen2.5:14b", "mistral-nemo:12b", "qwen3.5:9b-q8_0"
MODELS=(
    "qwen3.5:9b"
)

# --------------------------------------------------------------------------
# 1. Start Ollama server in background
# --------------------------------------------------------------------------
echo "[entrypoint] Starting Ollama server..."
ollama serve &
OLLAMA_PID=$!

# Trap signals for graceful shutdown
trap 'kill "$OLLAMA_PID" 2>/dev/null; wait "$OLLAMA_PID"' SIGTERM SIGINT

# --------------------------------------------------------------------------
# 2. Wait for Ollama to become ready (60s timeout)
# --------------------------------------------------------------------------
echo "[entrypoint] Waiting for Ollama API to be ready..."
TIMEOUT=60
ELAPSED=0
until curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; do
    if ! kill -0 "$OLLAMA_PID" 2>/dev/null; then
        echo "[entrypoint] ERROR: ollama serve crashed"
        exit 1
    fi
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "[entrypoint] ERROR: Ollama failed to start within ${TIMEOUT}s"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo "[entrypoint] Ollama API is ready (took ~${ELAPSED}s)"

# --------------------------------------------------------------------------
# 3. Pull models (skip if already present)
# --------------------------------------------------------------------------
for MODEL in "${MODELS[@]}"; do
    if ollama list | grep -q "^${MODEL}"; then
        echo "[entrypoint] Model '${MODEL}' already present — skipping pull"
    else
        echo "[entrypoint] Pulling model '${MODEL}'..."
        ollama pull "$MODEL"
        echo "[entrypoint] Model '${MODEL}' pulled successfully"
    fi
done

echo "[entrypoint] All models ready. Ollama is serving on ${OLLAMA_HOST:-0.0.0.0:11434}"

# --------------------------------------------------------------------------
# 4. Keep container alive — forward signals to Ollama process
# --------------------------------------------------------------------------
wait "$OLLAMA_PID"
