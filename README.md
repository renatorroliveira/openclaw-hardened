# OpenClaw

A hardened, self-hosted AI assistant gateway with local LLM inference via [Ollama](https://ollama.com) or cloud inference via [AWS Bedrock](https://aws.amazon.com/bedrock/). Ships as a Docker Compose stack with strict network isolation, read-only filesystems, and four deployment presets.

## Architecture

```
                  +---------------------+
                  |   openclaw-gateway   |
                  |   (Node.js 24)      |
                  |   read-only root    |
                  |   iptables firewall |
                  +----------+----------+
                             |
                   openclaw-internal
                     (bridge network)
                             |
     +-----------------------+------------------------+---------------------+
     |                       |                        |                     |
+----+----------------+ +----+----------------+ +-----+--------------+ +---+-------------------+
| ollama (Docker)     | | ollama (Docker)     | | host.docker.internal| | bedrock-runtime       |
| Windows NVIDIA      | | Linux NVIDIA        | | Apple Silicon       | | AWS Bedrock           |
| GPU-PV via WSL2     | | Container Toolkit   | | native Ollama       | | HTTPS/443             |
| (default preset)    | |                     | |                     | |                       |
+---------------------+ +---------------------+ +--------------------+ +-----------------------+
```

**OpenClaw Gateway** runs in a locked-down container with an iptables firewall that only permits inbound traffic on port 18789 (Control UI / WebSocket) and outbound traffic on ports 443 (HTTPS), 53 (DNS), and 11434 (Ollama). All other traffic is dropped and logged.

**Ollama** provides local LLM inference. Depending on your hardware, it runs either as a Docker container with NVIDIA CUDA acceleration or natively on macOS for Apple Metal GPU access.

## Default Models

### Ollama Presets (Windows NVIDIA, Linux NVIDIA, Apple Silicon)

| Model | Ollama Tag | Size (Q4) | Context | Capabilities |
|-------|-----------|-----------|---------|--------------|
| Qwen3.5 9B | `qwen3.5:9b` | 6.6 GB | 262K tokens | Multimodal (text + vision), tool use, thinking mode, 201 languages |

### Bedrock Preset (AWS)

| Model | Model ID | Role | Context | Cost (per 1M tokens) |
|-------|----------|------|---------|---------------------|
| Claude Haiku 4.5 | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Primary | 200K | $0.80 in / $4.00 out |
| Claude Sonnet 4.6 | `global.anthropic.claude-sonnet-4-6` | Fallback | 1M | $3.00 in / $15.00 out |
| Claude Opus 4.6 | `global.anthropic.claude-opus-4-6-v1` | Fallback | 1M | $15.00 in / $75.00 out |

Models use **global inference profiles** (`global.*` prefix) for cross-region routing, maximum throughput, and ~10% cost savings.

## Prerequisites

- [Docker Engine](https://docs.docker.com/engine/install/) 24.0+ with Compose V2
- **Windows NVIDIA preset** (default): Windows 11+ with [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) (WSL2 backend) and NVIDIA GPU with up-to-date drivers
- **Linux NVIDIA preset**: Linux host with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) installed
- **Apple Silicon preset**: macOS with Apple M-series chip and [Ollama](https://ollama.com/download) installed natively
- **Bedrock preset**: AWS account with [Bedrock model access enabled](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) and configured AWS credentials (`~/.aws/credentials` or environment variables)

## Quick Start

### Windows NVIDIA GPU (Docker Desktop) — Default

Windows NVIDIA is the default preset. No flags or profile arguments needed. Requires Docker Desktop with the WSL2 backend enabled.

```bash
# 1. Build and start both containers
docker compose build
docker compose up -d

# 2. Watch model download on first start (~6.6 GB)
docker compose logs -f ollama
```

The gateway entrypoint auto-deploys the Windows NVIDIA config on first boot (from `.env`: `OPENCLAW_PRESET=windows-nvidia`).

### Linux NVIDIA GPU

Override the defaults from `.env` to use the Linux NVIDIA preset with the NVIDIA Container Toolkit:

```bash
# 1. Build and start both containers
COMPOSE_PROFILES=nvidia OPENCLAW_PRESET=nvidia docker compose build
COMPOSE_PROFILES=nvidia OPENCLAW_PRESET=nvidia docker compose up -d

# 2. Watch model download on first start (~6.6 GB)
docker compose logs -f ollama
```

### Apple Silicon (macOS)

Docker Desktop on macOS **cannot** pass Apple Metal GPUs to containers. Running Ollama natively gives full Metal GPU acceleration. Override the defaults from `.env`:

```bash
# 1. Install and start Ollama natively
brew install ollama
ollama serve &

# 2. Pull the model (~6.6 GB)
ollama pull qwen3.5:9b

# 3. Start OpenClaw only (skip the Ollama container)
COMPOSE_PROFILES= OPENCLAW_PRESET=apple-silicon docker compose up -d
```

### AWS Bedrock (Cloud Inference)

AWS Bedrock provides cloud-based inference with Claude models — no local GPU required. Bedrock is pay-per-use; monitor costs in the [AWS Console](https://console.aws.amazon.com/billing/).

**Prerequisite:** Enable model access for Anthropic Claude models in the [AWS Bedrock Console](https://console.aws.amazon.com/bedrock/home#/modelaccess) for your chosen region.

**Method A: Static access keys** (simplest, for quick testing)

```bash
# 1. Set credentials in .env
#    AWS_BEDROCK_REGION=us-west-2
#    AWS_ACCESS_KEY_ID=AKIA...
#    AWS_SECRET_ACCESS_KEY=...

# 2. Build and start (no Ollama container)
COMPOSE_PROFILES= OPENCLAW_PRESET=bedrock docker compose up -d
```

**Method B: AWS CLI profile** (recommended for development)

```bash
# 1. Configure credentials on your host
aws configure --profile openclaw

# 2. Set profile in .env
#    AWS_BEDROCK_REGION=us-west-2
#    AWS_PROFILE=openclaw

# 3. Build and start
COMPOSE_PROFILES= OPENCLAW_PRESET=bedrock docker compose up -d
```

**Method C: SSO** (enterprise)

```bash
# 1. Configure and login on your host
aws configure sso
aws sso login --profile your-sso-profile

# 2. Set profile in .env
#    AWS_BEDROCK_REGION=us-west-2
#    AWS_PROFILE=your-sso-profile

# 3. Build and start
COMPOSE_PROFILES= OPENCLAW_PRESET=bedrock docker compose up -d
```

> **Note:** SSO tokens expire after 8-12 hours. Re-run `aws sso login` on the host and restart the container to re-stage credentials.

> **Windows WSL2 note:** `$HOME/.aws` resolves to the WSL2 home directory, not the Windows home. Either copy your credentials to `~/.aws` inside WSL2 or use environment variables (Method A).

## Project Structure

```
.
├── .env                                       # Default preset (Windows NVIDIA) and Compose profile
├── Dockerfile                                 # OpenClaw gateway (hardened)
├── Dockerfile.ollama                          # Ollama with model preloading
├── docker-compose.yml                         # Both services + profiles
├── config/
│   ├── openclaw-config.windows-nvidia.json5   # Config: Ollama in Docker (Windows, default)
│   ├── openclaw-config.nvidia.json5           # Config: Ollama in Docker (Linux)
│   ├── openclaw-config.apple-silicon.json5    # Config: Ollama on host
│   └── openclaw-config.bedrock.json5          # Config: AWS Bedrock (cloud)
└── scripts/
    └── ollama-entrypoint.sh                   # Ollama startup + model pull
```

## Configuration

### Changing Models

Models are defined in two places that must be kept in sync:

**1. `scripts/ollama-entrypoint.sh`** --- controls which models are pulled at container startup (NVIDIA preset only):

```bash
MODELS=(
    "qwen3.5:9b"
    # "qwen2.5:14b"        # Uncomment to add more models
    # "mistral-nemo:12b"
)
```

**2. `config/openclaw-config.*.json5`** --- controls which models OpenClaw uses:

```json5
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/qwen3.5:9b",
        "fallbacks": []    // e.g. ["ollama/qwen2.5:14b", "ollama/mistral-nemo:12b"]
      }
    }
  }
}
```

After changing models, rebuild and restart:

```bash
# NVIDIA (default) — rebuild Ollama image (entrypoint change), then restart
docker compose build ollama
docker compose up -d

# Apple Silicon — pull new models natively, then re-deploy config
ollama pull <new-model-tag>
docker compose cp config/openclaw-config.apple-silicon.json5 \
  openclaw-gateway:/home/openclaw/.openclaw/config.json5
docker compose restart openclaw-gateway

# Bedrock — edit model IDs in config, then re-deploy
# Delete the config volume to force re-deployment on next start:
docker compose down
docker volume rm openclaw_openclaw-config
COMPOSE_PROFILES= OPENCLAW_PRESET=bedrock docker compose up -d
```

### Ollama Environment Variables

These are set in `docker-compose.yml` under the `ollama` service:

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `0.0.0.0:11434` | Listen address |
| `OLLAMA_NUM_PARALLEL` | `2` | Max concurrent inference requests |
| `OLLAMA_MAX_LOADED_MODELS` | `2` | Max models kept in GPU memory |
| `NVIDIA_VISIBLE_DEVICES` | `all` | Which GPUs to expose |

### Gateway Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `XDG_CONFIG_HOME` | `/home/openclaw/.openclaw` | Config directory (gateway reads `openclaw.json` from here) |
| `OPENCLAW_PRESET` | `windows-nvidia` | Config preset deployed on first boot (`windows-nvidia`, `nvidia`, `apple-silicon`, or `bedrock`) |
| `OPENCLAW_GATEWAY_BIND` | `lan` | Network bind mode (`lan` = `0.0.0.0`, `loopback` = `127.0.0.1`) |
| `OPENCLAW_GATEWAY_TOKEN` | `changeme` | Auth token for Control UI access (change in `.env`) |
| `NODE_ENV` | `production` | Node.js environment |
| `TZ` | `America/Los_Angeles` | Container timezone |
| `AWS_BEDROCK_REGION` | `us-west-2` | AWS region for Bedrock API endpoint (Bedrock preset only) |
| `AWS_PROFILE` | *(unset)* | AWS CLI profile name (Bedrock preset only) |
| `AWS_ACCESS_KEY_ID` | *(unset)* | AWS static access key (Bedrock preset only) |
| `AWS_SECRET_ACCESS_KEY` | *(unset)* | AWS static secret key (Bedrock preset only) |
| `AWS_SESSION_TOKEN` | *(unset)* | AWS session token for temporary credentials (Bedrock preset only) |

## Security

The stack applies defense-in-depth at every layer:

### OpenClaw Gateway

| Control | Detail |
|---------|--------|
| **Read-only root filesystem** | All writes go to tmpfs or named volumes |
| **Non-root execution** | Runs as `openclaw` (UID 1100) after entrypoint |
| **Capability drop** | `cap_drop: ALL`, adds `NET_ADMIN` (iptables), `SETUID` and `SETGID` (gosu de-escalation) |
| **no-new-privileges** | Prevents setuid escalation after entrypoint |
| **iptables firewall** | INPUT: 18789 (Control UI). OUTPUT whitelist: 443 (HTTPS), 53 (DNS), 11434 (Ollama) |
| **Resource limits** | 2 GB RAM, 2 CPUs, 256 PIDs, 2048 open files |
| **PID 1 init** | `tini` handles zombie reaping and signal forwarding |
| **Privilege de-escalation** | `gosu` drops from root to `openclaw` after firewall setup |
| **AWS credential staging** | Host `~/.aws` bind-mounted read-only, copied to tmpfs at `/home/openclaw/.aws` (Bedrock preset) — credentials exist only in memory, never on persistent storage |

### Ollama (NVIDIA Preset)

| Control | Detail |
|---------|--------|
| **No published ports** | Only reachable on the internal bridge network |
| **Capability drop** | `cap_drop: ALL`, only `SYS_RESOURCE` added (GPU memory) |
| **no-new-privileges** | Prevents privilege escalation |
| **Resource limits** | 24 GB RAM, 8 CPUs, 512 PIDs, 65536 open files |
| **Unlimited memlock** | Required for GPU memory pinning |
| **Default seccomp** | Standard Docker seccomp profile applied |

### Network Isolation

```
Internet  <--18789-->  openclaw-gateway  <--11434-->  ollama
                             |
                        all other egress DROPPED
```

The gateway Control UI is accessible on port 18789. Port 11434 is never exposed to the host (NVIDIA preset). For Apple Silicon, traffic to `host.docker.internal:11434` traverses Docker's internal gateway.

## Verification

### Windows NVIDIA (Default)

```bash
# Containers are running
docker compose ps

# Models are loaded
docker compose exec openclaw-ollama curl -s http://localhost:11434/api/tags

# Inter-container connectivity
docker compose exec openclaw-gateway curl -sf http://ollama:11434/api/tags

# Firewall rules are applied
docker compose exec openclaw-gateway iptables -L OUTPUT -n -v

# GPU access (nvidia-smi may not be available on Windows GPU-PV; use ollama list instead)
docker compose exec openclaw-ollama ollama list

# Run a quick inference test
docker compose exec openclaw-ollama ollama run qwen3.5:9b "Hello, one word."

# Model persistence across restarts
docker compose down
docker compose up -d
docker compose logs ollama  # Should show "already present — skipping pull"
```

### Linux NVIDIA

```bash
# Containers are running
COMPOSE_PROFILES=nvidia docker compose ps

# GPU access (nvidia-smi available with NVIDIA Container Toolkit)
docker compose exec openclaw-ollama nvidia-smi

# Inter-container connectivity
docker compose exec openclaw-gateway curl -sf http://ollama:11434/api/tags

# Firewall rules are applied
docker compose exec openclaw-gateway iptables -L OUTPUT -n -v
```

### Apple Silicon

```bash
# Ollama is running on host
curl -s http://localhost:11434/api/tags

# OpenClaw can reach host Ollama
docker compose exec openclaw-gateway curl -sf http://host.docker.internal:11434/api/tags

# Firewall rules are applied
docker compose exec openclaw-gateway iptables -L OUTPUT -n -v
```

### AWS Bedrock

```bash
# Verify AWS credentials are working inside the container
docker compose exec openclaw-gateway aws sts get-caller-identity

# Verify Bedrock model access
docker compose exec openclaw-gateway aws bedrock list-foundation-models \
  --region us-west-2 --query "modelSummaries[?contains(modelId,'claude')]" --output table

# Firewall rules are applied (port 443 must be ACCEPT)
docker compose exec openclaw-gateway iptables -L OUTPUT -n -v

# Check deployed config has correct region
docker compose exec openclaw-gateway cat /home/openclaw/.openclaw/openclaw.json | head -5
```

**Required IAM permissions** for the Bedrock preset:

- `bedrock:InvokeModel`
- `bedrock:InvokeModelWithResponseStream`

## Verifying GPU Acceleration

Ollama silently falls back to CPU if GPU acceleration is unavailable. CPU inference is 3--10x slower, so verifying GPU usage is critical after any setup change. The checks below work for humans and AI assistants alike.

### Quick Check (All Platforms)

The single most reliable command is `ollama ps` (run while a model is loaded):

```bash
# NVIDIA presets (run inside the Ollama container)
docker compose exec openclaw-ollama ollama ps

# Apple Silicon (run on host)
ollama ps
```

Look at the **PROCESSOR** column:

| PROCESSOR | Meaning |
|-----------|---------|
| `100% GPU` | Full GPU acceleration (ideal) |
| `48%/52% CPU/GPU` | Partial offload — model too large for VRAM |
| `100% CPU` | No GPU acceleration — investigate |

### Inference Speed Benchmark (All Platforms)

Run a timed inference via the Ollama API and calculate tokens per second. This works identically on all platforms — just adjust the host and port for your preset.

```bash
# NVIDIA presets (from inside the gateway container, or use localhost:11434 on the host)
docker compose exec openclaw-gateway curl -s http://ollama:11434/api/generate \
  -d '{"model":"qwen3.5:9b","prompt":"Write a 100-word essay about AI","stream":false,"options":{"num_predict":200}}' \
  | python3 -c "
import json,sys; d=json.load(sys.stdin)
eval_tok=d['eval_count']; eval_ns=d['eval_duration']
prompt_tok=d.get('prompt_eval_count',0); prompt_ns=d.get('prompt_eval_duration',1)
print(f'Prompt: {prompt_tok/(prompt_ns/1e9):.1f} tok/s')
print(f'Generation: {eval_tok/(eval_ns/1e9):.1f} tok/s  ({eval_tok} tokens)')
print(f'Total: {d[\"total_duration\"]/1e9:.1f}s')
"

# Apple Silicon (Ollama runs on host)
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen3.5:9b","prompt":"Write a 100-word essay about AI","stream":false,"options":{"num_predict":200}}' \
  | python3 -c "
import json,sys; d=json.load(sys.stdin)
eval_tok=d['eval_count']; eval_ns=d['eval_duration']
prompt_tok=d.get('prompt_eval_count',0); prompt_ns=d.get('prompt_eval_duration',1)
print(f'Prompt: {prompt_tok/(prompt_ns/1e9):.1f} tok/s')
print(f'Generation: {eval_tok/(eval_ns/1e9):.1f} tok/s  ({eval_tok} tokens)')
print(f'Total: {d[\"total_duration\"]/1e9:.1f}s')
"
```

**Expected generation speeds for qwen3.5:9b (Q4_K_M):**

| Hardware | Expected tok/s | Red flag (likely CPU) |
|----------|---------------|----------------------|
| NVIDIA RTX 3060 (12 GB) | 30--60 | < 5 |
| NVIDIA RTX 4090 (24 GB) | 60--100 | < 10 |
| Apple M1 (8 GB) | 8--15 | < 2 |
| Apple M3 Pro (36 GB) | 15--25 | < 3 |
| Apple M4 Max (128 GB) | 30--50 | < 5 |

If your numbers are in the "red flag" range, GPU acceleration is probably not active.

### Windows NVIDIA (Docker Desktop + WSL2)

```bash
# 1. Check GPU detection inside the Ollama container
#    nvidia-smi may not be available with GPU-PV (Windows GPU paravirtualization).
#    Use ollama ps as the primary check instead.
docker compose exec openclaw-ollama ollama ps

# 2. If nvidia-smi is available, check for Ollama's VRAM usage
docker compose exec openclaw-ollama nvidia-smi
#    Look for "ollama_llama_server" or "ollama" in the Processes section
#    with VRAM allocated (e.g., 6000MiB for a 9B Q4 model)

# 3. Check server logs for CUDA GPU detection and layer offloading
docker compose logs ollama 2>&1 | grep -iE "cuda|offload|gpu|layers"
#    Good signs:
#      "offloaded 33/33 layers to GPU"
#      "library=cuda"
#      "CUDA" in system info line
#    Bad signs:
#      "no GPU detected"
#      "offloaded 0/33 layers to GPU"
#      "library=cpu"

# 4. Check from Windows host: open Task Manager > Performance > GPU
#    Look for "Dedicated GPU memory" usage increasing when a model is loaded.
#    Or use PowerShell:
#    nvidia-smi -l 1    (if NVIDIA drivers expose nvidia-smi on Windows)
```

### Linux NVIDIA (NVIDIA Container Toolkit)

```bash
# 1. Verify GPU is visible inside the container
COMPOSE_PROFILES=nvidia docker compose exec openclaw-ollama nvidia-smi
#    Should show your GPU model, driver version, and CUDA version

# 2. Check Ollama's GPU usage while a model is loaded
COMPOSE_PROFILES=nvidia docker compose exec openclaw-ollama ollama ps
#    PROCESSOR column should show "100% GPU" or a GPU percentage

# 3. Monitor real-time GPU utilization from the host during inference
watch -n 1 nvidia-smi
#    Look for "ollama" process with VRAM allocated and GPU-Util > 0%

# 4. Inspect container logs for CUDA layer offloading
COMPOSE_PROFILES=nvidia docker compose logs ollama 2>&1 | grep -iE "cuda|offload|gpu|layers"
#    Expected: "offloaded 33/33 layers to GPU", "library=cuda"

# 5. Debug GPU detection issues
COMPOSE_PROFILES=nvidia docker compose exec openclaw-ollama bash -c \
  "OLLAMA_DEBUG=1 CUDA_ERROR_LEVEL=50 ollama ps"
#    Or check host-level CUDA availability:
#    nvidia-smi && docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

### Apple Silicon (macOS, Native Ollama)

Docker Desktop on macOS **cannot** pass Apple Metal GPUs to containers. Ollama must run natively on the host for GPU acceleration. If Ollama runs inside Docker on a Mac, it will always use CPU only.

```bash
# 1. Check that Ollama reports 100% GPU
ollama ps
#    PROCESSOR column must show "100% GPU"

# 2. Inspect server logs for Metal GPU initialization
#    Log location depends on how Ollama was started:
#      - Homebrew manual:   check the terminal output, or redirect with
#                           ollama serve 2>&1 | tee /tmp/ollama-serve.log
#      - Ollama.app:        ~/Library/Logs/Ollama/server.log
#      - Homebrew service:  /opt/homebrew/var/log/ollama.log
#
#    Search for Metal initialization and layer offloading:
cat /tmp/ollama-serve.log 2>/dev/null | grep -iE "metal|offload|gpu"
#    Expected output:
#      ggml_metal_device_init: GPU name:   Apple M3 Pro
#      ggml_metal_device_init: GPU family: MTLGPUFamilyMetal4
#      ggml_metal_device_init: has unified memory = true
#      offloaded 33/33 layers to GPU
#      model weights device=Metal size="5.6 GiB"
#
#    Bad signs:
#      "no GPU detected" or missing Metal lines entirely
#      "offloaded 0/33 layers to GPU"

# 3. Verify Metal framework is loaded in the Ollama runner process
lsof -p $(pgrep -f "ollama runner") 2>/dev/null | grep -i metal
#    Should show AGXMetal*.bundle, Metal.framework, and MetalPerformanceShaders

# 4. Check GPU utilization via macOS system tools
ioreg -l 2>/dev/null | grep "PerformanceStatistics" | head -1
#    Look for "Device Utilization %" > 0 while inference is running

# 5. Verify Metal support is available on your hardware
system_profiler SPDisplaysDataType | grep Metal
#    Should show "Metal Support: Metal 3" (or Metal 4, etc.)
```

**Apple Silicon troubleshooting:**

- **Homebrew installs (pre-v0.15)** sometimes missed Metal dependencies. If `ollama ps` shows `100% CPU`, reinstall from the [official Ollama installer](https://ollama.com/download) or update to a recent Homebrew version.
- **After macOS updates**, restart your Mac (not just sleep/wake) — Metal drivers can change behavior.
- **Close memory-heavy apps** (Chrome, etc.) before running large models. About 75% of total RAM is available for GPU use on Apple Silicon.

## Volumes

| Volume | Purpose | Used By |
|--------|---------|---------|
| `openclaw-config` | Config, credentials, logs | Gateway |
| `openclaw-workspace` | Agent workspace files | Gateway |
| `ollama-models` | Downloaded model weights | Ollama (NVIDIA) |

To reset model storage (re-download all models):

```bash
docker compose down
docker volume rm openclaw_ollama-models
docker compose up -d
```

## Logs

```bash
# Gateway logs
docker compose logs -f openclaw-gateway

# Ollama logs (NVIDIA)
docker compose logs -f ollama

# Firewall drop logs (inside gateway)
docker compose exec openclaw-gateway dmesg | grep IPT-DROP
```

## Troubleshooting

### Ollama container exits immediately (Windows NVIDIA)

Ensure Docker Desktop is using the WSL2 backend (Settings > General > "Use the WSL 2 based engine"). Verify your NVIDIA GPU driver supports WSL2 GPU-PV by running `wsl --update` and checking that GPU access works: `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi`.

### Ollama container exits immediately (Linux NVIDIA)

Ensure the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) is installed and `nvidia-smi` works on the host.

### "Connection refused" to Ollama from gateway

- **Windows/Linux NVIDIA**: Check both containers are on `openclaw-internal` network: `docker network inspect openclaw_openclaw-internal`
- **Apple Silicon**: Ensure Ollama is running on the host (`ollama serve`) and listening on `localhost:11434`

### Model pull is slow or stalls

The default model (`qwen3.5:9b`) is ~6.6 GB. On first start, the Ollama container may take several minutes to pull. Monitor progress with `docker compose logs -f ollama`. Models are persisted in the `ollama-models` volume and won't re-download on restart.

### AWS credentials not found (Bedrock)

The entrypoint copies host `~/.aws` to a tmpfs inside the container. If `aws sts get-caller-identity` fails:

- **Using profile-based auth:** Verify `~/.aws/credentials` and `~/.aws/config` exist on your host. Check that `AWS_PROFILE` is set in `.env`.
- **Using environment variables:** Verify `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are set in `.env` (uncommented, non-empty).
- **Check staging logs:** `docker compose logs openclaw-gateway | grep -i aws`

### Bedrock model access denied

If inference fails with `AccessDeniedException`, enable model access in the [AWS Bedrock Console](https://console.aws.amazon.com/bedrock/home#/modelaccess) for your region. Model access must be explicitly granted even for pay-per-use models.

### SSO token expired (Bedrock)

SSO tokens expire after 8-12 hours. Re-run `aws sso login --profile <your-profile>` on the host, then restart the container to re-stage credentials:

```bash
docker compose restart openclaw-gateway
```

### Switching from Ollama to Bedrock (or vice versa)

Config is deployed once on first boot. To switch presets, delete the config volume:

```bash
docker compose down
docker volume rm openclaw_openclaw-config
# Then update .env and restart with the new preset
```

### Gateway firewall blocks unexpected traffic

Check the drop logs:

```bash
docker compose exec openclaw-gateway dmesg | grep IPT-DROP-OUT
```

If OpenClaw needs to reach an additional service, add an iptables rule in the `apply-firewall.sh` section of the `Dockerfile`.

## Cost Comparison

| Backend | Cost | Notes |
|---------|------|-------|
| Ollama (local) | Free | Requires GPU hardware (NVIDIA or Apple Silicon) |
| Bedrock Haiku 4.5 | ~$0.01--0.05/session | Fast, cost-effective for most tasks |
| Bedrock Sonnet 4.6 | ~$0.05--0.25/session | Balanced quality and cost |
| Bedrock Opus 4.6 | ~$0.25--1.50/session | Highest quality, highest cost |

*Session cost estimates assume ~2K input + ~1K output tokens per interaction. Actual costs vary by usage.*

## References

### Qwen3.5-9B (Default Model)

- [Qwen3.5-9B on Ollama](https://ollama.com/library/qwen3.5:9b) --- Ollama model page with tags, sizes, and quantization options
- [Qwen3.5-9B on Hugging Face](https://huggingface.co/Qwen/Qwen3.5-9B) --- Model card with architecture details, benchmark scores, and recommended inference parameters
- [Qwen3.5 Small Models Analysis (Artificial Analysis)](https://artificialanalysis.ai/articles/qwen3-5-small-models) --- Independent Intelligence Index benchmarks; Qwen3.5-9B scores 32, double the next-best sub-10B model
- [Alibaba Releases Qwen 3.5 Small Model Series (OfficeChai)](https://officechai.com/ai/alibaba-qwen-3-5-0-8b-2b-4b-9b-benchmarks/) --- GPQA Diamond (81.7), MMMU-Pro (70.1), MMMLU (81.2), and comparisons vs GPT-OSS-120B
- [Qwen 3.5 Benchmark Comparisons (Geeky Gadgets)](https://www.geeky-gadgets.com/qwen-3-5-benchmark-scores/) --- Qwen 3.5 family vs Claude Opus 4.5 and Gemini 3 Pro
- [Qwen3.5 Overview (ai.rs)](https://ai.rs/ai-for-business/qwen-3-5-35b-knowledge-4b-speed-better-than-gpt-5) --- Full Qwen 3.5 family overview: eight models (0.8B--397B), all Apache 2.0
- [Qwen3.5-9B Local Setup Guide (oflight.co.jp)](https://www.oflight.co.jp/en/columns/qwen35-9b-local-setup-guide) --- Hardware requirements, VRAM usage by quantization level, and Apple Silicon performance (~40--60 tok/s on M4)

### Qwen2.5-Coder-7B (Previous Default, Replaced)

- [Qwen2.5-Coder-7B-Instruct on Hugging Face](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct) --- Model card for the previous compact slot model
- [Qwen2.5-Coder Technical Report (arXiv)](https://arxiv.org/html/2409.12186v3) --- Full benchmark data: HumanEval 88.4%, MBPP 83.5%, LiveCodeBench 18.2, MultiPL-E 76.5% avg
- [Qwen2.5-Coder Family Blog Post](https://qwenlm.github.io/blog/qwen2.5-coder-family/) --- Official announcement and evaluation methodology

### Ollama

- [Ollama](https://ollama.com) --- Local LLM runtime
- [Ollama Docker Image](https://hub.docker.com/r/ollama/ollama) --- Official Docker image used as base for `Dockerfile.ollama`
- [How to Use Qwen 3.5 with Ollama (Apidog)](https://apidog.com/blog/use-qwen-3-5-with-ollama/) --- Step-by-step guide for running Qwen 3.5 models locally with Ollama

### AWS Bedrock

- [AWS Bedrock Documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/) --- Service overview, model access, and API reference
- [AWS Bedrock Pricing](https://aws.amazon.com/bedrock/pricing/) --- Pay-per-use pricing for Claude and other models
- [Cross-Region Inference (Global Inference Profiles)](https://docs.aws.amazon.com/bedrock/latest/userguide/cross-region-inference.html) --- `global.*` prefix for max throughput and ~10% cost savings
- [AWS Bedrock Model Access](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html) --- How to enable model access in the AWS Console

### Docker Security

- [NVIDIA Container Toolkit Installation Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) --- Required for NVIDIA GPU passthrough to Docker
- [Docker Compose Profiles](https://docs.docker.com/compose/profiles/) --- Used to support NVIDIA and Apple Silicon presets in a single compose file

### Qwen Official Documentation

- [Qwen Documentation (ReadTheDocs)](https://qwen.readthedocs.io/en/latest/) --- Deployment guides, speed benchmarks, and YaRN context scaling
- [Qwen3.5 Agentic AI Benchmarks (BuildMVPFast)](https://www.buildmvpfast.com/blog/alibaba-qwen-3-5-agentic-ai-benchmark-2026) --- Agentic capabilities and throughput benchmarks (8.6x faster than Qwen3-Max at 32K context)

## License

Apache 2.0
