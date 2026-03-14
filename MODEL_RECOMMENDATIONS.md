# Model Recommendations & GPU Tier Performance Guide

This guide helps you pick the right LLM model and configuration for your GPU hardware when running OpenClaw. All recommendations are optimized for **agentic task automation** — tool calling, multi-step reasoning, code generation, and instruction following.

## Quick-Pick Table

| VRAM | Primary Model | Quantization | Expected Speed | Thinking Mode |
|------|---------------|--------------|----------------|---------------|
| 8 GB | Qwen3.5-4B | Q4_K_M | 30--45 tok/s | No |
| 12 GB | Qwen3.5-9B | Q4_K_M | 35--55 tok/s | No |
| 16 GB | Qwen3.5-9B | Q5_K_M | 40--65 tok/s | Optional |
| 24 GB | Qwen3.5-9B | Q8_0 | 50--100 tok/s | Yes |
| 36+ GB | Qwen3.5-27B | Q5_K_M | 35--70 tok/s | Yes |

Pick your VRAM tier, use the recommended model and quantization, and follow the detailed configuration below.

---

## Finding Your VRAM

If you are unsure how much VRAM (or unified memory) your system has:

- **Windows (NVIDIA):** Open a terminal and run `nvidia-smi`, or check Task Manager > Performance > GPU
- **Linux (NVIDIA):** Run `nvidia-smi` on the host
- **Linux (AMD):** Run `rocm-smi` or `lspci -v | grep -i memory`
- **macOS (Apple Silicon):** Apple menu > About This Mac — the total unified memory is listed. Approximately 75% is available for GPU use (e.g., 36 GB total ≈ 27 GB usable for models).

---

## Hardware Reference

One representative GPU per vendor for each VRAM tier. Memory bandwidth is the primary bottleneck for LLM token generation speed — higher is better.

| VRAM | NVIDIA | AMD | Apple Silicon |
|------|--------|-----|---------------|
| 8 GB | RTX 4060 (3,072 CUDA cores) | RX 7600 (2,048 stream processors) | M4 base 8GB (10-core GPU, 120 GB/s) |
| 12 GB | RTX 4070 (5,888 CUDA cores) | RX 7700 XT (3,456 stream processors) | M4 base 16GB\* (10-core GPU, 120 GB/s) |
| 16 GB | RTX 4060 Ti 16GB (4,352 CUDA cores) | RX 7800 XT (3,840 stream processors) | M3 Pro 18GB (18-core GPU, 150 GB/s) |
| 24 GB | RTX 4090 (16,384 CUDA cores) | RX 7900 XTX (6,144 stream processors) | M4 Pro 24GB (20-core GPU, 273 GB/s) |
| 36+ GB | RTX A6000 Ada (18,176 CUDA cores) | Radeon Pro W7900 (6,144 stream processors) | M3 Max 36GB (30-core GPU, 300 GB/s) / M4 Max 64GB (40-core GPU, 546 GB/s) |

\*Apple Silicon has no native 12 GB configuration. The M4 base with 16 GB unified memory is the closest practical option and will perform as Tier 3.

> **Apple Silicon:** Docker on macOS cannot access Metal GPUs. Ollama must run natively on the host. Use the `apple-silicon` preset. See [README.md](README.md) for setup details.

> **AMD GPUs:** OpenClaw's presets currently cover NVIDIA (Docker with CUDA) and Apple Silicon (native Ollama). AMD GPUs require [ROCm](https://rocm.docs.amd.com/) and a custom Docker configuration. The AMD hardware listed above is for VRAM reference — a dedicated AMD preset is not yet available.

---

## Performance Tuning Reference

### Quantization Levels

Quantization reduces model precision to save memory and increase speed. Quality impact depends on the task — tool calling degrades more than general chat at lower quantization levels.

| Quantization | Size (9B) | VRAM Required | Quality vs FP16 | Speed Impact | Best For |
|--------------|-----------|---------------|------------------|--------------|----------|
| Q4_K_M | ~6.6 GB | ~8 GB | ~95% | Fastest | Speed-critical, 8--12 GB VRAM |
| Q5_K_M | ~7.5 GB | ~9 GB | ~98% | Fast | **Balanced (recommended for tool calling)** |
| Q6_K | ~8.5 GB | ~10 GB | ~99% | Moderate | High-accuracy tool calling |
| Q8_0 | ~9.5 GB | ~11 GB | ~99.5% | Slower | Near-lossless, 24+ GB VRAM |
| FP16/BF16 | ~17.9 GB | ~20 GB | 100% | Slowest | Research, maximum fidelity |

**Key insight:** Tool calling accuracy degrades more than general chat at aggressive quantization. For reliable agentic workflows, use **Q5_K_M or higher**. Q4_K_M is acceptable for 8--12 GB tiers where VRAM is the constraint.

### Ollama Environment Variables

These variables go in the `environment` section of the `ollama` service in `docker-compose.yml` (NVIDIA presets). For Apple Silicon, set them as host environment variables (e.g., `export OLLAMA_KV_CACHE_TYPE=q8_0`) before starting Ollama.

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_HOST` | `0.0.0.0:11434` | Listen address. Do not change in Docker. |
| `OLLAMA_NUM_PARALLEL` | `2` | Max concurrent inference requests. Higher values need more VRAM for KV cache. |
| `OLLAMA_MAX_LOADED_MODELS` | `2` | Max models held in GPU memory simultaneously. |
| `OLLAMA_KV_CACHE_TYPE` | `f16` | Set to `q8_0` for +12--38% throughput and lower VRAM usage. Recommended. |
| `OLLAMA_FLASH_ATTENTION` | `1` | Flash attention for 10--20% speedup. Enabled by default since Ollama 0.17. |
| `NVIDIA_VISIBLE_DEVICES` | `all` | Which GPUs to expose (NVIDIA presets only). |

**Recommended for all tiers:** Add `OLLAMA_KV_CACHE_TYPE=q8_0` to your Ollama environment. This is a free performance win with negligible quality impact.

### Model Parameters for Agentic Tasks

These parameters affect generation quality and are set per-request by the OpenClaw gateway or in Ollama's model configuration.

| Parameter | Tool Calling | General Chat | Description |
|-----------|--------------|--------------|-------------|
| `temperature` | 0.3--0.6 | 0.6--1.0 | Lower = more reliable JSON output for tool calls |
| `top_p` | 0.8--0.95 | 0.95 | Nucleus sampling threshold |
| `top_k` | 20 | 40 | Vocabulary sampling cutoff |
| `num_ctx` | 32768--131072 | 16384--65536 | Context window in tokens. Larger = more VRAM for KV cache |
| `repeat_penalty` | 1.2 | 1.5 | Reduces repetitive output |

### Thinking Mode (Qwen3.5)

Qwen3.5 models support a reasoning/thinking mode that wraps chain-of-thought in `<think>...</think>` tags before the final answer. In the OpenClaw config, set `"reasoning": true` on the model object to enable thinking mode.

- **Disabled by default** on models ≤ 9B parameters
- **Enable:** Set `"reasoning": true` in the model config. Use `/think` in prompts or start Ollama with `--think=true`.
- **With thinking:** 81.7% on GPQA Diamond (beats Qwen3-30B at 73.7%), adds 5--30s latency
- **Without thinking:** Fast responses, sufficient for most tool-calling workflows
- **Recommendation:** Disable for tool-calling heavy workflows (faster, more reliable JSON). Enable for complex multi-step reasoning tasks where accuracy matters more than speed.

When thinking mode is enabled, ensure `num_ctx` is at least 32768 to give the model room for its reasoning chain.

---

## GPU Tier Performance Matrix

### Primary Recommendations

| VRAM | Primary Model | Ollama Tag | Quant | Agentic Quality | Gen Speed | Max Context | Thinking | Concurrent |
|------|---------------|------------|-------|-----------------|-----------|-------------|----------|------------|
| 8 GB | Qwen3.5 4B | `qwen3.5:4b` | Q4_K_M | ★★☆☆☆ | 30--45 tok/s | 16K | No | 1 |
| 12 GB | Qwen3.5 9B | `qwen3.5:9b` | Q4_K_M | ★★★★☆ | 35--55 tok/s | 32K | No | 1 |
| 16 GB | Qwen3.5 9B | `qwen3.5:9b-q5_K_M` | Q5_K_M | ★★★★☆ | 40--65 tok/s | 64K | Optional | 2 |
| 24 GB | Qwen3.5 9B | `qwen3.5:9b-q8_0` | Q8_0 | ★★★★☆ | 50--100 tok/s | 128K | Yes | 2 |
| 36+ GB | Qwen3.5 27B | `qwen3.5:27b-q5_K_M` | Q5_K_M | ★★★★★ | 35--70 tok/s | 128K | Yes | 2--4 |

### Alternative Models

Each alternative is chosen for a specific strength relevant to agentic tasks.

| VRAM | Alt 1 (Reasoning) | Alt 2 (Tool Calling) | Alt 3 (Versatile) |
|------|--------------------|----------------------|--------------------|
| 8 GB | Phi-4-mini 3.8B | Gemma 3 4B | Llama 3.2 3B |
| 12 GB | DeepSeek-R1 8B (distill) | Mistral-NeMo 12B Q4_K_M | Gemma 3 12B Q4_K_M |
| 16 GB | DeepSeek-R1 8B Q8_0 | Mistral-NeMo 12B Q5_K_M | Gemma 3 12B Q5_K_M |
| 24 GB | DeepSeek-R1 32B Q4_K_M | Command-R 35B Q4_K_M | Qwen3.5 27B Q4_K_M |
| 36+ GB | DeepSeek-R1 70B Q4_K_M | Llama 3.3 70B Q4_K_M | Multi-model (9B + 27B) |

**Why these alternatives:**
- **DeepSeek-R1** — Superior multi-step planning and complex reasoning. Distilled variants use Qwen2.5 architecture. Best for tasks requiring deep analysis.
- **Mistral-NeMo 12B** — Purpose-built for function calling. Excels at knowing *when* to call tools (fewer false positives). 128K context.
- **Gemma 3** — Google's balanced models. Strong function calling with good multimodal support.
- **Command-R 35B** — Cohere's tool-use optimized model. Excellent for enterprise RAG + agentic workflows.
- **Llama 3.3 70B** — Meta's best dense model. Strong general-purpose tool calling at scale.
- **Phi-4-mini 3.8B** — Best reasoning capability under 4B parameters. Outperforms many 7B models.

---

## Detailed Tier Guides

> **Config snippet placement:** The model object snippets below go inside the `models.providers.ollama.models` array in your preset config file (`config/openclaw-config.*.json5`). Do not remove the surrounding `baseUrl`, `apiKey`, or `api` fields from the provider block. See [OpenClaw Configuration Reference](#openclaw-configuration-reference) for the full file structure.

> **Apple Silicon users:** The `docker-compose.yml` adjustments in each tier apply to the Docker Ollama service (NVIDIA presets only). Apple Silicon users run Ollama natively on the host and should instead set Ollama environment variables in their shell (e.g., `export OLLAMA_NUM_PARALLEL=1`).

> **Agent defaults:** Every tier uses the same agent defaults pattern. Set `"primary": "ollama/<model-tag>"` in the `agents.defaults.model` section of your config, matching the model `id` in the model object. See Tier 1 for the full snippet.

### Tier 1: 8 GB VRAM

**Hardware:** NVIDIA RTX 4060 | AMD RX 7600 | Apple M4 8GB (10-core GPU, 120 GB/s)

**Primary: Qwen3.5 4B — Q4_K_M**

Best tool-calling reliability at this size class. Qwen3.5's hybrid DeltaNet architecture delivers disproportionately strong reasoning for a 4B model. Supports 262K native context, though practical context is limited to 16K at this VRAM tier.

- Model size: ~3.4 GB
- VRAM with 16K context: ~5 GB
- Speed: 30--45 tok/s
- Limitations: Basic multi-step reasoning. Single concurrent request. No thinking mode.

**Alternatives:**
- `phi4-mini:3.8b` — Best reasoning under 4B. Strong instruction following. 128K context support.
- `gemma3:4b` — Google's edge model with function calling support. Good for lightweight agents.
- `llama3.2:3b` — Smallest Llama with native tool calling. Meta's ecosystem compatibility.

**OpenClaw Configuration:**

`scripts/ollama-entrypoint.sh`:
```bash
MODELS=(
    "qwen3.5:4b"
)
```

Model object for `config/openclaw-config.*.json5`:
```json5
{
  "id": "qwen3.5:4b",
  "name": "Qwen3.5 4B",
  "reasoning": false,
  "input": ["text"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 16384,
  "maxTokens": 4096
}
```

Agent defaults:
```json5
"agents": {
  "defaults": {
    "model": {
      "primary": "ollama/qwen3.5:4b",
      "fallbacks": []
    }
  }
}
```

`docker-compose.yml` adjustments (Ollama service, NVIDIA presets only):
```yaml
mem_limit: 10g
memswap_limit: 12g
cpus: 4
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=1
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KV_CACHE_TYPE=q8_0
  - NVIDIA_VISIBLE_DEVICES=all
```

---

### Tier 2: 12 GB VRAM

**Hardware:** NVIDIA RTX 4070 | AMD RX 7700 XT | Apple M4 16GB\* (10-core GPU, 120 GB/s)

\*Apple Silicon has no native 12 GB config. The M4 base with 16 GB is the closest option and will perform as Tier 3 in practice.

**Primary: Qwen3.5 9B — Q4_K_M**

The jump from 4B to 9B is transformative for agentic tasks. Qwen3.5-9B delivers industry-leading tool-calling accuracy, beats models 3x its size on reasoning benchmarks (GPQA 81.7%), and supports multimodal inputs natively.

- Model size: ~6.6 GB
- VRAM with 32K context: ~9 GB
- Speed: 35--55 tok/s
- Limitations: No headroom for thinking mode. Single concurrent request recommended.

**Benchmarks (Qwen3.5-9B):**

| Benchmark | Score | Notes |
|-----------|-------|-------|
| MMLU-Pro | 82.5% | Strong general knowledge |
| GPQA Diamond | 81.7% | Beats Qwen3-30B (73.7%) |
| HumanEval | 84.8% | Strong code generation |
| IFEval | 91.5% | Excellent instruction following |
| HMMT 2025 | 83.2% | Math reasoning |

**Alternatives:**
- `deepseek-r1:8b` — DeepSeek-R1 distilled into Qwen2.5-8B. Strong reasoning, thinking mode enabled by default.
- `mistral-nemo:12b` — Purpose-built for function calling. Best at avoiding unnecessary tool calls. 128K context.
- `gemma3:12b` — Balanced multimodal + tool calling. Google's mid-tier model.

**OpenClaw Configuration:**

`scripts/ollama-entrypoint.sh`:
```bash
MODELS=(
    "qwen3.5:9b"
)
```

Model object for `config/openclaw-config.*.json5`:
```json5
{
  "id": "qwen3.5:9b",
  "name": "Qwen3.5 9B",
  "reasoning": false,
  "input": ["text"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 32768,
  "maxTokens": 8192
}
```

`docker-compose.yml` adjustments (Ollama service, NVIDIA presets only):
```yaml
mem_limit: 14g
memswap_limit: 18g
cpus: 4
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=1
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KV_CACHE_TYPE=q8_0
  - NVIDIA_VISIBLE_DEVICES=all
```

---

### Tier 3: 16 GB VRAM

**Hardware:** NVIDIA RTX 4060 Ti 16GB | AMD RX 7800 XT | Apple M3 Pro 18GB (18-core GPU, 150 GB/s)

**Primary: Qwen3.5 9B — Q5_K_M**

Same model as Tier 2 but with higher-quality quantization. Q5_K_M retains ~98% of FP16 quality versus ~95% for Q4_K_M — a meaningful improvement for tool-calling reliability. The extra VRAM also enables 64K context and optional thinking mode.

- Model size: ~7.5 GB
- VRAM with 64K context: ~11 GB
- Speed: 40--65 tok/s
- Thinking mode: Available if context is reduced to 32K

**Alternatives:**
- `deepseek-r1:8b` at Q8_0 — Near-lossless reasoning model. Thinking mode always active.
- `mistral-nemo:12b` at Q5_K_M — Higher-quality function calling. 128K context. ~8 GB VRAM.
- `gemma3:12b` at Q5_K_M — Higher-quality multimodal. ~8 GB VRAM.

**OpenClaw Configuration:**

`scripts/ollama-entrypoint.sh`:
```bash
MODELS=(
    "qwen3.5:9b-q5_K_M"
)
```

Model object for `config/openclaw-config.*.json5`:
```json5
{
  "id": "qwen3.5:9b-q5_K_M",
  "name": "Qwen3.5 9B (Q5)",
  "reasoning": false,
  "input": ["text"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 65536,
  "maxTokens": 16384
}
```

`docker-compose.yml` adjustments (Ollama service, NVIDIA presets only):
```yaml
mem_limit: 18g
memswap_limit: 22g
cpus: 4
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=2
  - OLLAMA_MAX_LOADED_MODELS=1
  - OLLAMA_KV_CACHE_TYPE=q8_0
  - NVIDIA_VISIBLE_DEVICES=all
```

> **Tip:** To enable thinking mode at 16 GB, reduce `contextWindow` to 32768, set `"reasoning": true` in the model config, and add `/think` to your prompts. This frees ~2 GB for the thinking token overhead.

---

### Tier 4: 24 GB VRAM — Current OpenClaw Default

**Hardware:** NVIDIA RTX 4090 | AMD RX 7900 XTX | Apple M4 Pro 24GB (20-core GPU, 273 GB/s)

**Primary: Qwen3.5 9B — Q8_0**

This is the current OpenClaw default tier. Q8_0 quantization is near-lossless (~99.5% of FP16 quality) and costs only ~3 GB more than Q5_K_M. At 24 GB you have generous headroom for 128K+ context, full thinking mode, and KV cache without compromise.

- Model size: ~9.5 GB
- VRAM with 128K context: ~15 GB
- Speed: 50--100 tok/s (hardware dependent)
- Full thinking mode with ample headroom

**Alternatives:**
- `qwen3.5:27b` at Q4_K_M (~17 GB) — Significant intelligence upgrade. Best for complex agentic chains.
- `command-r:35b` at Q4_K_M (~22 GB) — Cohere's model optimized for tool use and RAG. Strong enterprise workflows.
- `deepseek-r1:32b` at Q4_K_M (~20 GB) — Superior multi-step planning. Thinking mode always active.

**OpenClaw Configuration (recommended):**

> **Note:** The current default `docker-compose.yml` does not include `OLLAMA_KV_CACHE_TYPE`. The configuration below adds this recommended optimization. Verify your `.env` file matches your intended preset before first boot.

`scripts/ollama-entrypoint.sh`:
```bash
MODELS=(
    "qwen3.5:9b-q8_0"
)
```

Model object for `config/openclaw-config.*.json5`:
```json5
{
  "id": "qwen3.5:9b-q8_0",
  "name": "Qwen3.5 9B (Q8)",
  "reasoning": false,
  "input": ["text"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 131072,
  "maxTokens": 32768
}
```

`docker-compose.yml` adjustments (Ollama service, NVIDIA presets only):
```yaml
mem_limit: 24g
memswap_limit: 32g
cpus: 8
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=2
  - OLLAMA_MAX_LOADED_MODELS=2
  - OLLAMA_KV_CACHE_TYPE=q8_0
  - NVIDIA_VISIBLE_DEVICES=all
```

> **Upgrade option:** To run Qwen3.5-27B instead, change the Ollama tag to `qwen3.5:27b`, update the model `id` and `name` accordingly, and increase `mem_limit` to `26g`. The 27B model at Q4_K_M (~17 GB) delivers a noticeable intelligence improvement for complex agentic tasks. With KV cache quantization enabled, 128K context fits comfortably at 24 GB.

---

### Tier 5: 36+ GB VRAM

**Hardware:** NVIDIA RTX A6000 Ada 48GB | AMD Radeon Pro W7900 48GB | Apple M3 Max 36GB (30-core GPU, 300 GB/s) / M4 Max 64GB (40-core GPU, 546 GB/s)

**Primary: Qwen3.5 27B — Q5_K_M**

At 36+ GB, you can run the 27B model at Q5_K_M — the quality sweet spot for agentic tasks. Qwen3.5-27B delivers top-tier tool calling reliability, strong multi-step reasoning, and excellent code generation. Thinking mode is highly effective at this parameter count.

- Model size: ~19 GB
- VRAM with 128K context: ~27 GB
- Speed: 35--70 tok/s
- Full thinking mode, multi-model serving feasible at 48+ GB

**Alternatives:**
- `deepseek-r1:70b` at Q4_K_M (~43 GB) — Frontier reasoning model. Requires 48+ GB VRAM.
- `llama3.3:70b` at Q4_K_M (~43 GB) — Meta's best dense model. Strong general-purpose tool calling. Requires 48+ GB.
- Multi-model: `qwen3.5:9b` (fast, simple tasks) + `qwen3.5:27b` (complex reasoning) with fallback routing.

**OpenClaw Configuration:**

`scripts/ollama-entrypoint.sh`:
```bash
MODELS=(
    "qwen3.5:27b-q5_K_M"
)
```

Model object for `config/openclaw-config.*.json5`:
```json5
{
  "id": "qwen3.5:27b-q5_K_M",
  "name": "Qwen3.5 27B",
  "reasoning": true,
  "input": ["text"],
  "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
  "contextWindow": 131072,
  "maxTokens": 32768
}
```

`docker-compose.yml` adjustments (Ollama service, NVIDIA presets only):
```yaml
mem_limit: 48g
memswap_limit: 56g
cpus: 8
environment:
  - OLLAMA_HOST=0.0.0.0:11434
  - OLLAMA_NUM_PARALLEL=4
  - OLLAMA_MAX_LOADED_MODELS=2
  - OLLAMA_KV_CACHE_TYPE=q8_0
  - NVIDIA_VISIBLE_DEVICES=all
```

**Multi-Model Configuration (48+ GB):**

For users with 48+ GB, running two models simultaneously enables fast responses for simple queries and deep reasoning for complex ones. With `OLLAMA_MAX_LOADED_MODELS=2`, both models stay in GPU memory — no cold-start latency when switching.

`scripts/ollama-entrypoint.sh`:
```bash
MODELS=(
    "qwen3.5:9b"
    "qwen3.5:27b-q5_K_M"
)
```

Model objects (inside the `models.providers.ollama.models` array):
```json5
[
  {
    "id": "qwen3.5:27b-q5_K_M",
    "name": "Qwen3.5 27B",
    "reasoning": true,
    "input": ["text"],
    "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
    "contextWindow": 131072,
    "maxTokens": 32768
  },
  {
    "id": "qwen3.5:9b",
    "name": "Qwen3.5 9B (Fast)",
    "reasoning": false,
    "input": ["text"],
    "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
    "contextWindow": 131072,
    "maxTokens": 32768
  }
]
```

Agent defaults with fallback:
```json5
"agents": {
  "defaults": {
    "model": {
      "primary": "ollama/qwen3.5:27b-q5_K_M",
      "fallbacks": ["ollama/qwen3.5:9b"]
    }
  }
}
```

> **Experimenting with models on smaller tiers:** On tiers with `OLLAMA_MAX_LOADED_MODELS=1`, you can still pull and try multiple models. Ollama will swap models in and out of GPU memory as needed, though switching incurs a cold-start delay (5--30 seconds depending on model size). This is fine for experimentation but not recommended for production.

---

## Agentic Task Optimization

### Tool Calling Best Practices

1. **Lower temperature (0.3--0.6)** for tool-calling workflows. This produces more reliable JSON output and reduces hallucinated parameters.
2. **Use Q5_K_M or higher** quantization. Tool calling accuracy drops 5--10% at Q4_K_M compared to Q5_K_M.
3. **Set `num_ctx` to at least 32K** for agentic workflows. Multi-step tool chains require context for previous tool results.
4. **Disable thinking mode for tool-heavy workflows.** Thinking adds latency without improving tool-call accuracy on most tasks.

### Model Strengths by Task Type

| Task | Best Model | Why |
|------|-----------|-----|
| Tool calling (JSON output) | Qwen3.5 | Industry-leading on Berkeley Function Calling Leaderboard (BFCL) |
| Knowing when NOT to call tools | Mistral-NeMo 12B | Fewest false positive tool invocations |
| Multi-step planning | DeepSeek-R1 | Superior chain-of-thought reasoning with built-in thinking mode |
| Code generation | Qwen3.5 / Gemma 3 | Both strong on HumanEval and LiveCodeBench |
| RAG + retrieval | Command-R 35B | Purpose-built for retrieval-augmented generation |
| Edge / resource-constrained | Phi-4-mini 3.8B | Best reasoning under 4B parameters |

### Multi-Model Fallback Strategy

OpenClaw supports primary + fallback model chains. A common pattern for agentic automation:

```json5
"agents": {
  "defaults": {
    "model": {
      "primary": "ollama/qwen3.5:27b-q5_K_M",  // Complex tasks: deep reasoning
      "fallbacks": ["ollama/qwen3.5:9b"]          // Fallback: fast, reliable tool calling
    }
  }
}
```

This ensures complex tasks get the full 27B model, while the 9B model serves as a fast fallback if the primary is busy or unresponsive.

---

## OpenClaw Configuration Reference

### Full Config File Structure

Each model object goes inside the `models.providers.ollama.models` array. Here is the complete file structure for reference:

```json5
{
  "gateway": {
    "bind": "lan",
    "auth": { "mode": "token" },
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true,
      "allowedOrigins": ["http://localhost:18789"],
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  },
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://ollama:11434",          // NVIDIA presets
        // "baseUrl": "http://host.docker.internal:11434",  // Apple Silicon
        "apiKey": "ollama-local",
        "api": "ollama",
        "models": [
          // <-- model objects go here -->
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "ollama/<model-id>",
        "fallbacks": []
      }
    }
  }
}
```

### Required Model Object Fields

Every model in the `models` array must include these fields:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Ollama model tag. Must match `ollama pull <tag>` exactly. |
| `name` | string | Display name in the Control UI. |
| `reasoning` | boolean | Set `true` if thinking mode is enabled for this model. |
| `input` | array | Supported input types: `["text"]` or `["text", "image"]` for multimodal. |
| `cost` | object | Token costs: `{ "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }` (all zero for local Ollama). |
| `contextWindow` | number | Max context tokens. Reduce per tier to save VRAM. |
| `maxTokens` | number | Max output tokens per response. |

### Environment Variable Quick Reference

| Variable | 8 GB | 12 GB | 16 GB | 24 GB | 36+ GB |
|----------|------|-------|-------|-------|--------|
| `OLLAMA_NUM_PARALLEL` | 1 | 1 | 2 | 2 | 4 |
| `OLLAMA_MAX_LOADED_MODELS` | 1 | 1 | 1 | 2 | 2 |
| `OLLAMA_KV_CACHE_TYPE` | q8_0 | q8_0 | q8_0 | q8_0 | q8_0 |
| `mem_limit` | 10g | 14g | 18g | 24g | 48g+ |
| `cpus` | 4 | 4 | 4 | 8 | 8 |

### Switching Between Tiers

To change your model configuration:

1. **Update `scripts/ollama-entrypoint.sh`** — change the `MODELS` array to include your target model tag (with quantization suffix if not using the default)
2. **Update `config/openclaw-config.*.json5`** — update the model object (`id` must match the Ollama tag exactly, plus `name`, `contextWindow`, `maxTokens`, `reasoning`)
3. **Update `docker-compose.yml`** — adjust `mem_limit`, `cpus`, and Ollama environment variables per the table above
4. **Rebuild and restart:**
   ```bash
   docker compose build ollama
   docker compose up -d
   ```
5. **Verify GPU acceleration** — see [Verifying GPU Acceleration](README.md#verifying-gpu-acceleration) in the README

### Ollama Model Tags Reference

| Model | Ollama Tag | Default Quant | Size |
|-------|-----------|---------------|------|
| Qwen3.5 4B | `qwen3.5:4b` | Q4_K_M | ~3.4 GB |
| Qwen3.5 9B | `qwen3.5:9b` | Q4_K_M | ~6.6 GB |
| Qwen3.5 27B | `qwen3.5:27b` | Q4_K_M | ~17 GB |
| Mistral-NeMo 12B | `mistral-nemo:12b` | Q4_K_M | ~7.1 GB |
| Gemma 3 4B | `gemma3:4b` | Q4_K_M | ~3.3 GB |
| Gemma 3 12B | `gemma3:12b` | Q4_K_M | ~8.1 GB |
| DeepSeek-R1 8B | `deepseek-r1:8b` | Q4_K_M | ~5.0 GB |
| DeepSeek-R1 32B | `deepseek-r1:32b` | Q4_K_M | ~20 GB |
| DeepSeek-R1 70B | `deepseek-r1:70b` | Q4_K_M | ~43 GB |
| Llama 3.3 70B | `llama3.3:70b` | Q4_K_M | ~43 GB |
| Command-R 35B | `command-r:35b` | Q4_K_M | ~22 GB |
| Phi-4-mini 3.8B | `phi4-mini:3.8b` | Q4_K_M | ~2.4 GB |

To pull a specific quantization, append the quantization suffix:
```bash
ollama pull qwen3.5:9b-q8_0      # Q8_0 quantization
ollama pull qwen3.5:9b-q5_K_M    # Q5_K_M quantization
ollama pull qwen3.5:27b-q5_K_M   # 27B at Q5_K_M
```

---

## Qwen3.5-9B Deep Dive (Default Model)

### Architecture

Qwen3.5-9B uses a **hybrid Gated DeltaNet + Full Attention** architecture:
- **60 layers** in a 3:1 pattern: 3 Gated DeltaNet blocks (linear attention) followed by 1 full quadratic attention block
- **9 billion dense parameters** (not a mixture-of-experts model)
- **262K native context** window, extensible to ~1M tokens with YaRN
- **Multimodal:** natively supports text, image, and video from the same weights (add `"image"` to the `input` array in the config to enable vision)
- **201 languages** supported

The DeltaNet layers provide constant-memory complexity for context processing, meaning long contexts use significantly less VRAM than traditional transformer models. This makes Qwen3.5-9B particularly efficient at large context windows on consumer hardware.

### Benchmark Highlights

| Benchmark | Qwen3.5-9B | Qwen3-30B (3x larger) | Notes |
|-----------|------------|------------------------|-------|
| MMLU-Pro | 82.5% | — | Strong general knowledge |
| GPQA Diamond | 81.7% | 73.7% | 9B beats 30B by 8 points |
| HMMT 2025 | 83.2% | — | Excellent math reasoning |
| IFEval | 91.5% | 88.9% | Superior instruction following |
| HumanEval | 84.8% | — | Strong code generation |
| LongBench v2 | 55.2% | — | Long context performance |

The key takeaway: Qwen3.5-9B achieves performance comparable to or exceeding models 3x its size, making it the optimal choice for agentic task automation on consumer hardware.
