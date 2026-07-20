# Performance Metrics — Ollama s390x Port

> **Authoritative reference for benchmarking Ollama on IBM Z (s390x) / LinuxONE.**  
> All metric definitions, formulas, measurement procedures, and s390x-specific caveats are
> captured here. When in doubt about a number, follow the methodology in Section 3 before
> drawing conclusions.

**Related documents:**
- [`docs/bottleneck_analysis.md`](bottleneck_analysis.md) — hypotheses and investigation angles for observed regressions
- [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) — per-model status, tok/s, and RAM figures
- [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md) — root-cause analysis of big-endian tensor handling
- [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) — VXE2 vector facility background

---

## Table of Contents

1. [Overview](#1-overview)
2. [Metric Definitions](#2-metric-definitions)
   - 2.1 [Server Startup Time](#21-server-startup-time)
   - 2.2 [Model Load Time](#22-model-load-time)
   - 2.3 [Time to First Token (TTFT)](#23-time-to-first-token-ttft)
   - 2.4 [Prompt Eval Latency (Prompt TPS)](#24-prompt-eval-latency-prompt-tps)
   - 2.5 [Generation Throughput (Eval TPS)](#25-generation-throughput-eval-tps)
   - 2.6 [Memory Usage](#26-memory-usage)
3. [Measurement Methodology](#3-measurement-methodology)
   - 3.1 [Environment Requirements](#31-environment-requirements)
   - 3.2 [Warmup Protocol](#32-warmup-protocol)
   - 3.3 [Standard Test Prompt](#33-standard-test-prompt)
   - 3.4 [Baseline Models](#34-baseline-models)
   - 3.5 [Cold vs Warm Measurement](#35-cold-vs-warm-measurement)
4. [Metric Summary Table](#4-metric-summary-table)
5. [Interpretation Notes](#5-interpretation-notes)

---

## 1. Overview

### Purpose

This document defines every performance metric used when evaluating the Ollama s390x port,
specifies how each metric is measured, and documents the s390x-specific factors that cause
measured values to differ from x86_64 or ARM64 reference runs.

Anyone running benchmarks against this port — whether reproducing results, tracking a
regression, or evaluating a new model — should treat this document as the single source of
truth for what the numbers mean and how they were obtained.

### Scope

The metrics defined here apply to CPU-only inference on IBM Z (s390x) with AIU
(Application Intelligent Unit) acceleration. Where a measurement concern is
architecture-neutral, it is noted as such; where it is specific to s390x (big-endian
byte-swapping, AIU JIT compilation, VXE2 vector alignment, LPAR scheduling) that context
is called out explicitly in each section.

---

## 2. Metric Definitions

### 2.1 Server Startup Time

| Field | Value |
|---|---|
| **Definition** | Wall-clock time from `ollama serve` process start to receipt of the first `HTTP 200 OK` from `GET /api/version` |
| **Unit** | milliseconds (ms) |
| **Measured by** | External timer wrapping `curl -s http://localhost:11434/api/version` in a polling loop |

**How to measure:**

```bash
time_start=$(date +%s%3N)
until curl -sf http://localhost:11434/api/version > /dev/null 2>&1; do sleep 0.05; done
time_end=$(date +%s%3N)
echo "$((time_end - time_start)) ms"
```

**s390x note:** Startup time on s390x is elevated relative to x86_64 because the runtime
binary discovery routine searches over 50 candidate paths before locating the correct
`libllama` / `llama-server` binary. This overhead adds a measurable tail to cold-start
timing and should be expected in all s390x startup measurements. It is not a model-load
cost; it is a fixed per-process overhead.

---

### 2.2 Model Load Time

| Field | Value |
|---|---|
| **Definition** | `load_duration` field from a `/api/generate` or `/api/ps` response — time spent loading the model weights into memory before generation begins |
| **Unit** | milliseconds (ms) — divide the raw nanosecond value by `1e6` |
| **API field** | `load_duration` (nanoseconds, `omitempty`) |
| **Cold load** | Model not previously in memory; full disk-to-RAM path including byte-swap |
| **Warm load** | Model already resident in memory; `load_duration` is near zero |

**Source field in [`api/types.go`](../api/types.go:572):**

```go
type Metrics struct {
    LoadDuration       time.Duration `json:"load_duration,omitempty"`
    ...
}
```

**Conversion:**

```
load_time_ms = load_duration_ns / 1_000_000
```

**s390x note:** On s390x, `mmap` is intentionally disabled for model loading so that tensor
data can be read into writable buffers and byte-swapped before use. This forces a full
buffered read of every tensor block on every cold load, adding approximately **0.5–2 s**
of extra load time compared to an equivalent x86_64 run. This cost is proportional to
total weight size and is therefore larger for bigger models and higher-precision
quantizations (F16 > Q8_0 > Q4_K_M > Q4_0). See
[`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md) for the full root-cause
analysis.

---

### 2.3 Time to First Token (TTFT)

| Field | Value |
|---|---|
| **Definition** | Wall-clock time from the moment the HTTP request is sent to the moment the first streaming response chunk is received by the client |
| **Unit** | milliseconds (ms) |
| **Measured by** | External client timer; requires `stream: true` |

**How to measure:**

```bash
time curl -s -o /dev/null --write-out "%{time_starttransfer}" \
  -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","prompt":"List 3 facts about the ocean.","stream":true,"options":{"seed":42,"temperature":0,"num_predict":80}}'
```

The `time_starttransfer` curl variable captures the time to the first byte of the response
body, which corresponds to TTFT.

**s390x note:** On the **first inference after server startup**, TTFT is significantly
elevated because the AIU (Application Intelligent Unit) JIT-compiles the compute graph for
the model on first use. This one-time compilation cost typically adds several seconds to
the first inference only. All TTFT measurements **must discard the first 1–2 runs** (see
[Section 3.2](#32-warmup-protocol)). After warmup, TTFT variance under shared LPAR load
should be expected and noted in results.

---

### 2.4 Prompt Eval Latency (Prompt TPS)

| Field | Value |
|---|---|
| **Definition** | Rate at which the model processes input prompt tokens |
| **Formula** | `prompt_eval_count / (prompt_eval_duration / 1e9)` |
| **Unit** | tokens/second (tok/s) |
| **API fields** | `prompt_eval_count` (integer), `prompt_eval_duration` (nanoseconds) |

**Formula:**

```
prompt_tps = prompt_eval_count / (prompt_eval_duration / 1_000_000_000)
```

**Example** (from [`docs/api.md`](api.md:119)):

```json
{
  "prompt_eval_count": 26,
  "prompt_eval_duration": 130079000
}
```

```
prompt_tps = 26 / (130079000 / 1e9) = 26 / 0.130079 ≈ 199.9 tok/s
```

**s390x note:** Prompt TPS can vary significantly between runs on a shared LPAR depending
on CPU time-slice allocation. Results should always be taken as medians over multiple
runs, not single-shot values.

---

### 2.5 Generation Throughput (Eval TPS)

| Field | Value |
|---|---|
| **Definition** | Rate at which the model generates output tokens during autoregressive decoding |
| **Formula** | `eval_count / (eval_duration / 1e9)` |
| **Unit** | tokens/second (tok/s) |
| **API fields** | `eval_count` (integer), `eval_duration` (nanoseconds) |

**Formula** (from [`docs/api.md`](api.md:119)):

```
eval_tps = eval_count / (eval_duration / 1_000_000_000)
```

**Example:**

```json
{
  "eval_count": 259,
  "eval_duration": 4232710000
}
```

```
eval_tps = 259 / (4232710000 / 1e9) = 259 / 4.23271 ≈ 61.2 tok/s
```

**Warmup exclusion rule:** The first 1–2 generation runs after server startup **must be
discarded** before recording eval TPS. The AIU JIT compiles the execution graph on first
use; including these runs will produce artificially low outliers that distort median and
mean calculations. See [Section 3.2](#32-warmup-protocol).

**s390x note:** Q8_0 quantization is expected to produce *higher* eval TPS than Q4_K_M on
s390x due to better alignment with the 128-bit VXE2 vector registers. This is the reverse
of the typical x86 expectation where higher compression usually means higher throughput.
See [Section 5](#5-interpretation-notes) for details.

---

### 2.6 Memory Usage

| Metric | Source | Meaning | Unit |
|--------|--------|---------|------|
| **Steady-state RSS** | `/proc/<PID>/status` → `VmRSS` | Resident set size after a completed generation; reflects the model's stable in-memory footprint | MiB |
| **Peak memory** | `/proc/<PID>/status` → `VmPeak` | High-water mark reached during model load; captures the extra buffer needed for byte-swapping on s390x | MiB |
| **Running model size** | `GET /api/ps` → `size` field | As reported by the Ollama API for currently loaded models | bytes |

**How to read VmRSS and VmPeak:**

```bash
# Replace <PID> with the ollama or llama-server process ID
grep -E 'VmRSS|VmPeak' /proc/<PID>/status
```

Example output:

```
VmPeak:  3145728 kB
VmRSS:   1572864 kB
```

Convert to MiB: divide kB value by 1024.

**How to query running models via API:**

```bash
curl -s http://localhost:11434/api/ps | jq '.models[] | {name, size, size_vram}'
```

**s390x note:** Peak memory (`VmPeak`) will exceed steady-state RSS (`VmRSS`) by a
model-size-dependent margin during cold load on s390x, because the mmap-disabled path
allocates extra writable buffers for tensor byte-swapping before freeing them. This
transient peak should always be recorded alongside steady-state RSS when characterizing
memory requirements for a deployment.

---

## 3. Measurement Methodology

### 3.1 Environment Requirements

Before running any benchmark:

| Requirement | Rationale |
|---|---|
| Ollama server fully started and returning `200 OK` on `/api/version` | Eliminates startup overhead from inference timings |
| Server idle (no in-flight requests) before each run | Prevents CPU contention from concurrent requests skewing results |
| `OLLAMA_KEEP_ALIVE=-1` set in the server environment | Prevents the model from being evicted from memory between runs, which would silently introduce cold-load overhead into warm-run measurements |
| Fixed `seed` (e.g., `42`) in every request | Ensures deterministic token sampling; eliminates output-length variance |
| `temperature: 0` in every request | Disables stochastic sampling; tokens generated are fully reproducible |
| `num_predict: 80` | Fixed output length; prevents variable eval counts from distorting TPS calculations |

**Setting `OLLAMA_KEEP_ALIVE`:**

```bash
export OLLAMA_KEEP_ALIVE=-1
ollama serve
```

---

### 3.2 Warmup Protocol

| Step | Count | Action |
|------|-------|--------|
| Warmup runs | 2 | Send the standard test prompt (Section 3.3); discard all metric values |
| Measured runs | 10 | Send the standard test prompt; record all metric fields from the response |
| Reported value | — | **Median** of the 10 measured runs |

**Why 2 warmup runs?**

1. **AIU JIT compilation** — The AIU compiles the compute graph for the model on the very
   first inference. This produces an anomalously high TTFT and anomalously low eval TPS
   that are not representative of steady-state performance.
2. **Cache hydration** — KV-cache, weight cache, and OS page-cache effects stabilize after
   the first 1–2 inferences.

**Why report the median?**

On a shared LPAR, individual run times are subject to CPU time-slice jitter. The median is
robust to outliers in a way that the mean is not. Report the full distribution (min, median,
max, and optionally p95) when investigating variance.

---

### 3.3 Standard Test Prompt

All baseline measurements use a single fixed prompt to ensure comparability across models,
runs, and hardware configurations.

| Parameter | Value |
|-----------|-------|
| **Prompt text** | `"List 3 facts about the ocean."` |
| **`num_predict`** | `80` |
| **`seed`** | `42` |
| **`temperature`** | `0` |
| **`stream`** | `false` for load time / eval TPS; `true` for TTFT measurement |

**Non-streaming request (eval TPS, load time, prompt TPS):**

```bash
curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "List 3 facts about the ocean.",
    "stream": false,
    "options": {
      "seed": 42,
      "temperature": 0,
      "num_predict": 80
    }
  }' | jq '{load_duration, prompt_eval_count, prompt_eval_duration, eval_count, eval_duration}'
```

**Streaming request (TTFT):**

```bash
curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "List 3 facts about the ocean.",
    "stream": true,
    "options": {
      "seed": 42,
      "temperature": 0,
      "num_predict": 80
    }
  }'
```

---

### 3.4 Baseline Models

Three models are designated as baselines for all s390x benchmark comparisons. Using these
exact models and quantizations ensures that results from different runs, dates, and
hardware configurations are directly comparable.

| Role | Model | Tag | Quant | Expected Tok/s | Expected RAM |
|------|-------|-----|-------|---------------|-------------|
| **Fast baseline** | SmolLM 360M | `smollm:360m` | Q4_0 | ~77.9 | ~340 MiB |
| **Industry baseline** | Llama 3.2 1B | `llama3.2:1b` | Q4_K_M | ~17.6 | ~1.5 GiB |
| **IBM s390x reference** | Granite 3.3 2B | `granite3.3:2b` | Q4_K_M | ~12.25 | ~1.9 GiB |

Reference values are medians from a z15 LPAR with AIU, 32 CPUs, 1 TB RAM. Values on
different hardware will differ; the baselines are used to detect relative regressions, not
to assert absolute performance targets.

**Pull commands:**

```bash
ollama pull smollm:360m
ollama pull llama3.2:1b
ollama pull granite3.3:2b
```

---

### 3.5 Cold vs Warm Measurement

Many metrics have materially different values depending on whether the model is already
loaded into memory. Always record and label which condition applies.

| Condition | Definition | How to achieve |
|-----------|------------|----------------|
| **Cold** | Model not in memory at the time of the request; full disk-to-RAM load occurs | Restart `ollama serve` (or run `ollama stop <model>`) immediately before the test request |
| **Warm** | Model already resident in memory from a prior load | Run at least one generation request (or use `OLLAMA_KEEP_ALIVE=-1`) before starting the measured sequence |

**Cold measurement procedure:**

```bash
# Stop any running model instances
ollama stop llama3.2:1b
# Wait for unload to complete
sleep 2
# First request will trigger a cold load — record load_duration from this response
curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","prompt":"List 3 facts about the ocean.","stream":false,"options":{"seed":42,"temperature":0,"num_predict":80}}' \
  | jq '.load_duration'
```

**Warm measurement procedure:**

```bash
# Pre-load the model with OLLAMA_KEEP_ALIVE=-1 already set
curl -s -X POST http://localhost:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama3.2:1b","prompt":"warmup","stream":false,"options":{"seed":42,"temperature":0,"num_predict":5}}' \
  > /dev/null
# Now run the timed measurement — load_duration should be near zero
```

**s390x note:** The cold-warm delta is larger on s390x than on x86_64 because of the
mmap-disabled buffered-read + byte-swap path taken on every cold load. Expect cold loads to
be 0.5–2 s slower than equivalent x86_64 cold loads, with the delta scaling with model
size and quantization precision.

---

## 4. Metric Summary Table

Quick reference for all metrics defined in this document.

| Metric | Formula / Source | Unit | s390x Caveat |
|--------|-----------------|------|--------------|
| **Server Startup Time** | Wall-clock: process start → first `/api/version` 200 | ms | +overhead from 50+ runtime binary path discovery |
| **Model Load Time (cold)** | `load_duration` / 1 000 000 | ms | +0.5–2 s from mmap-disabled byte-swap path |
| **Model Load Time (warm)** | `load_duration` / 1 000 000 | ms | Near zero; model already in memory |
| **TTFT (post-warmup)** | Wall-clock: request sent → first streaming chunk | ms | First 1–2 runs inflated by AIU JIT; must discard |
| **Prompt TPS** | `prompt_eval_count / (prompt_eval_duration / 1e9)` | tok/s | Sensitive to LPAR CPU jitter; use median |
| **Eval TPS** | `eval_count / (eval_duration / 1e9)` | tok/s | Exclude first 1–2 runs (AIU JIT); Q8_0 > Q4_K_M |
| **Steady-state RSS** | `/proc/<PID>/status` `VmRSS` after completed generation | MiB | Reflects post-swap in-memory footprint |
| **Peak memory** | `/proc/<PID>/status` `VmPeak` during model load | MiB | Elevated by transient byte-swap buffers on cold load |

**Reference benchmark values** (z15 LPAR, AIU, 32 CPUs, 1 TB RAM):

| Model | Quant | Eval TPS (median) | Steady-state RSS |
|-------|-------|:-----------------:|:----------------:|
| SmolLM 135M | Q4_0 | 104.6 tok/s | 178 MiB |
| SmolLM 360M | Q4_0 | 77.9 tok/s | 340 MiB |
| Llama 3.2 1B | Q8_0 | 22.75 tok/s | 1.5 GiB |
| Llama 3.2 1B | Q4_K_M | 17.6 tok/s | 1.5 GiB |
| Llama 3.2 1B | Q2_K | 1.4–11.4 tok/s ⚠️ | 781 MiB |
| Llama 3.2 1B | F16 | 4.9 tok/s | 2.5 GiB |
| Llama 3.2 3B | Q4_K_M | 12.2 tok/s | 2.4 GiB |
| Granite 3.3 2B | Q4_K_M | 12.25 tok/s | 1.9 GiB |
| Mistral 7B | Q4_K_M | 5.8 tok/s | 4.6 GiB |

⚠️ Q2_K results are highly unstable. See [Section 5](#5-interpretation-notes).

---

## 5. Interpretation Notes

### Q8_0 outperforms Q4_K_M on s390x

On typical x86_64 hardware, Q4_K_M usually outperforms Q8_0 because lower-bit
quantization reduces data bandwidth and x86 AVX2/AVX-512 kernels are optimized for 4-bit
paths. On s390x the situation is reversed:

- The IBM Z VXE2 (Vector-Enhancements Facility 2) provides 128-bit vector registers.
- Q8_0 blocks have a simpler, naturally aligned layout that maps cleanly onto VXE2
  operations.
- Q4_K_M's mixed-precision blocks require more dequantization arithmetic that does not
  benefit as much from VXE2's fixed-width element model.

**Practical implication:** When evaluating a new model, always test Q8_0 alongside
Q4_K_M on s390x. Do not assume the x86 ranking applies. See
[`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) for VXE2 background.

---

### Always exclude the first 1–2 inferences (AIU JIT)

The AIU compiles the model's compute graph on first use. This is a one-time cost per
server process lifetime (not per request), but it is large enough to dominate TTFT and
substantially reduce eval TPS for the first 1–2 runs. Including these runs in a reported
median will produce a pessimistic and misleading result.

**Rule:** Always run 2 warmup requests and discard their metrics before beginning
measured collection.

---

### Q2_K results are unreliable — flag if run

Q2_K throughput on s390x has been observed to range from 1.4 to 11.4 tok/s on the same
model and hardware configuration (Llama 3.2 1B on z15 LPAR). The source of this variance
is not yet fully characterized but is suspected to be related to the mixed-precision
dequantization path interacting poorly with VXE2 scheduling under variable LPAR load.

**Rule:** If Q2_K results are included in a report, they must be explicitly flagged as
unreliable with the full observed range noted. Do not report a Q2_K median as if it were a
stable figure.

---

### IQ4_XS (iQuant family) is unsupported

iQuant formats (IQ4_XS and related) are not supported on s390x. Attempting to load a
model in an iQuant format will fail. See
[`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) for the full
quantization support table.

---

### TTFT variance is expected under shared LPAR load

IBM Z LPARs share physical CPU resources with other logical partitions. CPU time-slice
jitter is normal and will produce run-to-run TTFT variance that is unrelated to model or
inference quality. Always report TTFT as a distribution (min / median / max) rather than a
single value, and note the LPAR configuration and co-tenancy conditions when publishing
results.

---

### F16 throughput is lower than Q4_K_M

F16 doubles the weight data volume relative to Q4_K_M without a proportional increase in
compute, making it bandwidth-bound on CPU-only inference. The measured 4.9 tok/s for
Llama 3.2 1B F16 versus 17.6 tok/s for Q4_K_M confirms this. F16 is primarily useful for
debugging weight correctness, not for production throughput measurement.
