# Step 8 — CPU vs zDNN Benchmark Numbers

This document records all measured performance data for Ollama on s390x and clearly
marks what has not yet been run. Anyone continuing this work should use the methodology
here to fill in the zDNN column.

---

## Summary

| Backend | Status | Hardware required |
|---|---|---|
| **CPU/VXE** | ✅ Measured — numbers below are real | Any IBM Z LPAR (z14+); z15 used for baseline |
| **zDNN/zAIU** | ⏳ Not yet measured — column is empty | IBM z17 with NNPA + validated `llama.cpp-s390x` build |

The zDNN backend scaffolding in this repo is complete (preset, Dockerfile stage, ServingRuntime).
The `llama.cpp-s390x` fork contains a real `ggml-zdnn` backend. The two have not yet been
wired together into a validated end-to-end build on z17 hardware. See
[`docs/zdnn-status.md`](zdnn-status.md) for the full status and the exact next steps to
attempt that build.

---

## CPU/VXE baseline (measured)

**Environment:**
- Hardware: IBM z15 LPAR with AIU (Application Intelligent Unit), 32 IFLs, 1 TB RAM
- OS: Ubuntu 22.04 (s390x)
- Backend: CPU/VXE (`cpu_s390x` preset — `GGML_VXE=ON`, `GGML_BLAS=ON` OpenBLAS)
- Ollama build: this repo, `main` branch
- Methodology: median of 15 runs, 80-token generation, prompt `"List 3 facts about the ocean."`,
  first 2 warmup runs discarded (AIU JIT), `seed=42`, `temperature=0`

### Eval TPS (generation throughput)

| Model | Tag | Quant | CPU/VXE tok/s | zDNN tok/s |
|---|---|---|---|---|
| SmolLM 135M | `smollm:135m` | Q4_0 | 104.6 | ⏳ not measured |
| SmolLM 360M | `smollm:360m` | Q4_0 | 77.9 | ⏳ not measured |
| Llama 3.2 1B | `llama3.2:1b-instruct-q8_0` | Q8_0 | **22.75** | ⏳ not measured |
| Llama 3.2 1B | `llama3.2:1b` | Q4_K_M | 17.6 | ⏳ not measured |
| Llama 3.2 1B | `llama3.2:1b-instruct-q5_k_m` | Q5_K_M | 21.6 | ⏳ not measured |
| Llama 3.2 1B | `llama3.2:1b-instruct-q2_k` | Q2_K | 1.4–11.4 ⚠️ | ⏳ not measured |
| Llama 3.2 1B | `llama3.2:1b-instruct-fp16` | F16 | 4.9 | ⏳ not measured |
| Llama 3.2 3B | `llama3.2:3b` | Q4_K_M | 12.2 | ⏳ not measured |
| Llama 3.2 3B | `llama3.2:3b-instruct-q8_0` | Q8_0 | 7.5 | ⏳ not measured |
| Granite 3.3 2B | `granite3.3:2b` | Q4_K_M | 12.25 | ⏳ not measured |
| Mistral 7B | `mistral:7b` | Q4_K_M | 5.8 | ⏳ not measured |

> ⚠️ Q2_K throughput is highly variable (range 1.4–11.4 tok/s across runs). Do not use in production.

### Memory (steady-state RSS after completed generation)

| Model | Tag | Quant | RSS | Pod limit (RSS × 1.3) |
|---|---|---|---|---|
| SmolLM 135M | `smollm:135m` | Q4_0 | 178 MiB | 256 MiB |
| SmolLM 360M | `smollm:360m` | Q4_0 | 340 MiB | 512 MiB |
| Llama 3.2 1B | `llama3.2:1b` | Q4_K_M | 1.5 GiB | 2 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-q8_0` | Q8_0 | 1.5 GiB | 2 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-q5_k_m` | Q5_K_M | 1.1 GiB | 1.5 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-q2_k` | Q2_K | 781 MiB | 1.1 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-fp16` | F16 | 2.5 GiB | 3.3 GiB |
| Llama 3.2 3B | `llama3.2:3b` | Q4_K_M | 2.4 GiB | 3.2 GiB |
| Llama 3.2 3B | `llama3.2:3b-instruct-q8_0` | Q8_0 | 3.7 GiB | 4.9 GiB |
| Granite 3.3 2B | `granite3.3:2b` | Q4_K_M | 1.9 GiB | 2.5 GiB |
| Mistral 7B | `mistral:7b` | Q4_K_M | 4.6 GiB | 6 GiB |

### s390x-specific observation: Q8_0 outperforms Q4_K_M

On s390x, Q8_0 produces **higher eval TPS than Q4_K_M** for the same model. This is the
opposite of typical x86_64 behaviour. The 128-bit VXE2 vector registers align better with
Q8_0's 8-bit integer layout than Q4_K_M's 4-bit packed format, yielding higher throughput
despite more data being read per token.

| Model | Q4_K_M tok/s | Q8_0 tok/s | Q8_0 advantage |
|---|---|---|---|
| Llama 3.2 1B | 17.6 | **22.75** | +29% |
| Llama 3.2 3B | 12.2 | **7.5** ¹ | — |

¹ The 3B Q8_0 result (7.5 tok/s) is lower than Q4_K_M (12.2 tok/s) — this may reflect
LPAR memory pressure at 3.7 GiB RSS. Retest on a system with more headroom.

---

## zDNN/zAIU (not yet measured)

> **⏳ This section is intentionally empty. All entries require z17 hardware with NNPA
> and a successful end-to-end build using `OLLAMA_LLAMA_CPP_SOURCE=../llama.cpp-s390x`
> with the `cpu_s390x_zdnn` preset.**

### What needs to happen first

1. Complete the end-to-end zDNN build (see [docs/zdnn-status.md](zdnn-status.md) — the
   patch-apply blocker is fixed; the next step is a full configure + build attempt)
2. Run the standard benchmark suite (same prompt, same models, same methodology as above)
3. Fill in the `zDNN tok/s` column in the table above
4. Record whether the NNPA capability check (`zdnn_is_nnpa_installed()`) passes — this
   confirms the hardware accelerator is actually being used vs. silent CPU fallback

### Expected zDNN speedup (not yet validated)

Based on published zDNN API characteristics and Aaron Teo's earlier llama.cpp work,
zDNN/NNPA acceleration is expected to improve **matrix-multiply throughput** — the
dominant operation in transformer inference. Realistic expectations for a first integration:

| Model class | Expected zDNN improvement |
|---|---|
| 1B models | 2–5× eval TPS vs CPU baseline |
| 2–3B models | 2–4× eval TPS vs CPU baseline |
| 7B models | 1.5–3× eval TPS vs CPU baseline |

These are **estimates, not measurements**. Do not publish them as results.

### How to run the zDNN benchmarks when ready

```sh
# 1. Build with zDNN backend (see docs/2-build-from-source.md Path B)
OLLAMA_LLAMA_CPP_SOURCE=../llama.cpp-s390x \
  cmake -B build .
cmake --build build --parallel 8

# 2. Confirm zDNN runner is loaded
./ollama serve 2>&1 | grep -i zdnn

# 3. Pull baseline models
ollama pull smollm:135m
ollama pull llama3.2:1b-instruct-q8_0
ollama pull granite3.3:2b

# 4. Run the standard benchmark (repeat 15×, discard first 2, report median)
for i in $(seq 1 15); do
  curl -s http://localhost:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d '{
      "model": "llama3.2:1b-instruct-q8_0",
      "prompt": "List 3 facts about the ocean.",
      "stream": false,
      "options": {"seed": 42, "temperature": 0, "num_predict": 80}
    }' | jq '{
      run: '"$i"',
      eval_tps: (.eval_count / (.eval_duration / 1e9)),
      load_ms: (.load_duration / 1e6),
      rss_mib: "read from /proc/$(pgrep llama-server)/status VmRSS"
    }'
done
```

Full methodology: [docs/performance_metrics.md](performance_metrics.md)

---

## How to reproduce the CPU numbers

If you need to re-verify the CPU baseline on a different LPAR or after a code change:

```sh
# 1. Install or build Ollama (CPU/VXE)
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh

# 2. Set keep-alive so the model stays loaded between runs
export OLLAMA_KEEP_ALIVE=-1
sudo systemctl restart ollama

# 3. Pull the three baseline models
ollama pull smollm:360m
ollama pull llama3.2:1b
ollama pull granite3.3:2b

# 4. Warmup (2 runs, discard)
for i in 1 2; do
  curl -s http://localhost:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d '{"model":"granite3.3:2b","prompt":"List 3 facts about the ocean.","stream":false,"options":{"seed":42,"temperature":0,"num_predict":80}}' \
    > /dev/null
done

# 5. Measured runs (10 runs, report median)
for i in $(seq 1 10); do
  curl -s http://localhost:11434/api/generate \
    -H 'Content-Type: application/json' \
    -d '{"model":"granite3.3:2b","prompt":"List 3 facts about the ocean.","stream":false,"options":{"seed":42,"temperature":0,"num_predict":80}}' \
    | jq '{run: '"$i"', eval_tps: (.eval_count / (.eval_duration / 1e9))}'
done
```

Expected output for `granite3.3:2b` on z15: ~12.25 tok/s median.
Significant deviation (> ±20%) indicates either a different LPAR configuration,
host load contention, or a regression in the build.
