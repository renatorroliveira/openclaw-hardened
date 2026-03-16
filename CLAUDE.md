# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenClaw is a hardened, self-hosted AI assistant gateway with local LLM inference via Ollama. It is an infrastructure/DevOps project — there is no application source code to build or test. The repo contains Docker configuration, shell scripts, and JSON5 config files.

## Architecture

Two-service Docker Compose stack with strict network isolation:

- **openclaw-gateway** — Node.js 24 container running the `openclaw` npm package. Hardened with read-only root filesystem, iptables firewall (inbound 18789, outbound 443/53/11434), capability drop, non-root execution via `gosu`, and `tini` as PID 1. The Control UI and WebSocket API are served on port 18789 (bind `0.0.0.0` via `gateway.bind: "lan"` in config).
- **ollama** — Local LLM inference server. Runs as a Docker container with NVIDIA GPU passthrough (default, activated via `.env`) or natively on macOS for Apple Metal acceleration.

The default preset is **Windows NVIDIA**, configured in `.env` (`COMPOSE_PROFILES=windows-nvidia`, `OPENCLAW_PRESET=windows-nvidia`). Four presets are available: `windows-nvidia` (default, Docker Desktop + WSL2), `nvidia` (Linux with NVIDIA Container Toolkit), `apple-silicon` (macOS with native Ollama), and `bedrock` (AWS Bedrock cloud inference, no local GPU). The gateway entrypoint auto-deploys the matching config on first boot.

The two services communicate over an internal bridge network (`openclaw-internal`, subnet `172.28.0.0/16`). Ollama port 11434 is never exposed to the host in the NVIDIA preset.

## Common Commands

### Build and Run

```bash
# Windows NVIDIA GPU (Docker Desktop + WSL2) — default, no flags needed
docker compose build
docker compose up -d

# Linux NVIDIA GPU — override .env defaults
COMPOSE_PROFILES=nvidia OPENCLAW_PRESET=nvidia docker compose up -d

# Apple Silicon (macOS) — override .env defaults, requires native Ollama on host
COMPOSE_PROFILES= OPENCLAW_PRESET=apple-silicon docker compose up -d

# AWS Bedrock (cloud inference) — no local GPU needed
COMPOSE_PROFILES= OPENCLAW_PRESET=bedrock docker compose up -d
```

Config is auto-deployed on first boot based on `OPENCLAW_PRESET` (set in `.env`, defaults to `windows-nvidia`).

### Verification

```bash
docker compose exec openclaw-gateway curl -sf http://ollama:11434/api/tags      # NVIDIA
docker compose exec openclaw-gateway curl -sf http://host.docker.internal:11434/api/tags  # Apple Silicon
docker compose exec openclaw-gateway aws sts get-caller-identity                 # Bedrock
docker compose exec openclaw-gateway iptables -L OUTPUT -n -v                    # firewall rules
```

### Logs

```bash
docker compose logs -f openclaw-gateway
docker compose logs -f ollama
docker compose exec openclaw-gateway dmesg | grep IPT-DROP   # firewall drops
```

## Key Files and Config Sync

The `.env` file sets the default preset (`COMPOSE_PROFILES=windows-nvidia`, `OPENCLAW_PRESET=windows-nvidia`). This activates the Ollama Docker service and selects the Windows NVIDIA config on first boot.

Model configuration must be kept in sync across two locations:

1. **`scripts/ollama-entrypoint.sh`** — `MODELS` array controls which models are pulled at container startup (NVIDIA presets only)
2. **`config/openclaw-config.*.json5`** — preset configs deployed to `~/.openclaw/openclaw.json` on first boot

**Important:** The gateway reads its config from `$XDG_CONFIG_HOME/openclaw.json` (NOT `config.json5`). The entrypoint copies the preset file to this location on first boot. `XDG_CONFIG_HOME` is set to `/home/openclaw/.openclaw` in docker-compose.yml.

All four config files set `gateway.bind: "lan"` (bind to `0.0.0.0:18789`, required for Docker bridge networking), `controlUi.allowedOrigins`, and `controlUi.dangerouslyAllowHostHeaderOriginFallback: true`. They differ in `baseUrl`:
- Windows NVIDIA: `http://ollama:11434` (Docker internal DNS)
- NVIDIA (Linux): `http://ollama:11434` (Docker internal DNS — identical to Windows NVIDIA)
- Apple Silicon: `http://host.docker.internal:11434` (Docker-to-host bridge)
- Bedrock: `https://bedrock-runtime.{region}.amazonaws.com` (AWS API endpoint)

## GPU Acceleration Validation

Ollama silently falls back to CPU if GPU is unavailable (3--10x slower). After any setup change, validate GPU usage. These commands work across platforms:

### Universal Quick Check

```bash
ollama ps   # or: docker compose exec openclaw-ollama ollama ps
```

The **PROCESSOR** column must show `100% GPU` (or a GPU percentage). `100% CPU` means no acceleration.

### Inference Benchmark (all platforms)

```bash
curl -s http://HOST:11434/api/generate \
  -d '{"model":"qwen3.5:9b","prompt":"test","stream":false,"options":{"num_predict":100}}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"eval_count\"]/(d[\"eval_duration\"]/1e9):.1f} tok/s')"
```

Expected: NVIDIA ~30--100 tok/s, Apple Silicon ~10--50 tok/s. Below ~5 tok/s likely means CPU-only.

### Windows NVIDIA (Docker Desktop + WSL2)

```bash
docker compose exec openclaw-ollama ollama ps                          # primary check
docker compose exec openclaw-ollama nvidia-smi                         # VRAM usage (if available)
docker compose logs ollama 2>&1 | grep -iE "cuda|offload|gpu|layers"   # "offloaded N/N layers to GPU"
```

nvidia-smi may not be available with GPU-PV. `ollama ps` is the most reliable check. On the Windows host, Task Manager > Performance > GPU shows VRAM usage.

### Linux NVIDIA (NVIDIA Container Toolkit)

```bash
COMPOSE_PROFILES=nvidia docker compose exec openclaw-ollama nvidia-smi   # GPU visible + VRAM used
COMPOSE_PROFILES=nvidia docker compose exec openclaw-ollama ollama ps    # "100% GPU"
COMPOSE_PROFILES=nvidia docker compose logs ollama 2>&1 | grep -iE "cuda|offload|gpu|layers"
watch -n 1 nvidia-smi                                                    # real-time host monitoring
```

Server logs should show `library=cuda`, `offloaded 33/33 layers to GPU`. If not: check `nvidia-smi` on host, ensure NVIDIA Container Toolkit is installed, try `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`.

### Apple Silicon (macOS, Native Ollama)

Docker on macOS **cannot** use Metal GPUs. Ollama must run natively on the host.

```bash
ollama ps                                                                  # must show "100% GPU"
cat /tmp/ollama-serve.log 2>/dev/null | grep -iE "metal|offload|gpu"       # Metal init + layer offload
lsof -p $(pgrep -f "ollama runner") 2>/dev/null | grep -i metal           # Metal framework loaded
system_profiler SPDisplaysDataType | grep Metal                            # Metal hardware support
ioreg -l 2>/dev/null | grep "PerformanceStatistics" | head -1             # GPU utilization %
```

Server log locations vary by install method:
- Homebrew manual: terminal output or redirect (`ollama serve 2>&1 | tee /tmp/ollama-serve.log`)
- Ollama.app: `~/Library/Logs/Ollama/server.log`
- Homebrew service: `/opt/homebrew/var/log/ollama.log`

Expected log output: `ggml_metal_device_init: GPU name: Apple M*`, `offloaded 33/33 layers to GPU`, `model weights device=Metal`.

Troubleshooting: Old Homebrew installs (pre-v0.15) sometimes missed Metal dependencies — reinstall from ollama.com or update brew. After macOS updates, reboot (not just sleep/wake). Close memory-heavy apps; ~75% of total RAM is available for GPU on Apple Silicon.

## Reference Documentation

- Model recommendations and GPU tier guide: `MODEL_RECOMMENDATIONS.md`

## Security Constraints

When modifying the Dockerfile or compose file, preserve these hardening controls:
- Gateway runs read-only root filesystem; writable paths are only tmpfs and named volumes
- Gateway drops ALL capabilities, adds `NET_ADMIN` (iptables), `SETUID` and `SETGID` (gosu privilege de-escalation)
- `no-new-privileges` is set on both containers
- Firewall rules are in the `apply-firewall.sh` heredoc inside `Dockerfile` (lines 97-139)
- Ollama container drops ALL capabilities, adds only `SYS_RESOURCE` (GPU memory)
- Resource limits are set in `docker-compose.yml` (gateway: 2GB/2CPU, ollama: 24GB/8CPU)
- AWS credentials (Bedrock preset) are passed via environment variables only — never written to disk, no bind mounts, not present in the image
