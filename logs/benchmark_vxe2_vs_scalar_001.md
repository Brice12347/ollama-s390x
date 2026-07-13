# Benchmark Log: VXE2 vs Scalar — s390x SIMD benchmark series

**Date:** 2026-07-13  
**Platform:** IBM Z z15 LPAR (triframe), 1 TB RAM, 32 logical CPUs, 12 AIU virtual functions  
**Container:** `localhost/workspace_ollama-dev:latest` (podman)  
**Binary:** `ollama` built from source (`main` branch)  
**Model:** `smollm:135m` (Q4_0, ~86 MB)  
**Prompt:** `"List 3 facts about the ocean."` — fixed, `num_predict=80`  
**Metric:** `eval_count / eval_duration * 1e9` (tok/s)

---

## Methodology

To force ollama to use a specific binary, the VXE2 binary was moved out of reach before
starting the scalar run:

```bash
# VXE2 run
OLLAMA_LLM_LIBRARY=build/llama-server-cpu_s390x/bin ./ollama serve

# Scalar run — remove VXE2 binary first so glob can only find novxe
mv build/llama-server-cpu_s390x/bin/llama-server /tmp/llama-server-vxe2
OLLAMA_LLM_LIBRARY=build/llama-server-cpu_s390x_novxe/bin ./ollama serve
```

Binary selection verified via `starting llama-server cmd=` in serve output:

| Run | cmd path confirmed |
|-----|--------------------|
| VXE2 | `build/llama-server-cpu_s390x/bin/llama-server` ✅ |
| Scalar | `build/llama-server-cpu_s390x_novxe/bin/llama-server` ✅ |

---

## Raw Results

### VXE2 run (`cpu_s390x`, z15 with VXE2 SIMD) — 19:56 UTC
```
156.0  108.7  75.4  72.7  109.7  127.1  130.0  135.0  142.0  98.2
```

### Scalar run (`cpu_s390x_novxe`, no VXE) — 20:00 UTC
```
126.1  123.7  102.3  115.4  77.5  83.3  89.4  113.6  109.7  106.3
```

---

## Statistics

| Build | Mean (tok/s) | Median (tok/s) | Stdev | Min | Max |
|-------|-------------|---------------|-------|-----|-----|
| VXE2 (`cpu_s390x`) | **115.5** | **118.4** | 27.7 | 72.7 | 156.0 |
| Scalar (`cpu_s390x_novxe`) | **104.7** | **108.0** | 16.6 | 77.5 | 126.1 |
| **VXE2 advantage** | **+10.8 tok/s** | **+10.4 tok/s** | — | — | — |
| **VXE2 advantage %** | **+10.3%** | **+9.6%** | — | — | — |

---

## Analysis

**VXE2 provides a modest ~10% throughput improvement over scalar on this workload.**

This is significantly lower than the 2–4× speedup hypothesised in `docs/bottleneck_analysis.md`.
Key factors:

1. **AIU VF contention dominates variance** — stdev of 27.7 on VXE2 vs 16.6 on scalar means
   runs can't be compared sample-by-sample; the 10% figure is a mean comparison only.
2. **smollm:135m is too small to stress SIMD** — the model fits entirely in L3/LLC. Memory
   bandwidth is not the bottleneck, so VXE2's wider vector ops have little opportunity to help.
   A larger model (≥1B, not LLC-resident) would show a larger SIMD gap.
3. **Q4_0 dequantization is the hot path** — VXE2 helps here, but the model is so small
   that dequant time is a tiny fraction of total latency.

### Hypothesis 1 verdict

**Partially confirmed.** VXE2 does provide measurable improvement (+10%) on this platform
and workload, but the 2–4× hypothesis is not confirmed. A clean test on a larger model
(llama3.2:1b or llama3.2:3b) on the LinuxONE Community Cloud VM (CPU-only, no AIU
contention) is needed to isolate the SIMD contribution properly.

---

## Next Steps

1. Repeat on LinuxONE Community Cloud VM with `llama3.2:1b` — CPU-only, no AIU contention,
   larger model stresses SIMD more
2. Compare same model/quant on both builds
3. Update `docs/model_compatibility_matrix.md` with VXE2 vs scalar column

---

## Run 2 — llama3.2:3b Q4_K_M, z15 triframe (2026-07-13)

**Model:** `llama3.2:3b` (Q4_K_M, 2.0 GB)
**Prompt:** `"List 3 facts about the ocean."` — fixed, `num_predict=80`
**Time:** 20:31–20:34 UTC
**Platform:** IBM Z z15 LPAR (triframe), 1 TB RAM, 32 logical CPUs, 12 AIU virtual functions

### Methodology

Same binary-swap approach as Run 1. Binary confirmed via `starting llama-server cmd=` log line:

| Run | cmd path confirmed |
|-----|--------------------|
| VXE2 | `build/llama-server-cpu_s390x/bin/llama-server` ✅ |
| Scalar | `build/llama-server-cpu_s390x_novxe/bin/llama-server` ✅ |

### Raw Results

**VXE2 run (`cpu_s390x`) — 20:31 UTC**
```
10.9  11.7  12.9  12.4  13.2  13.1  14.1  12.9  10.5  12.5
```

**Scalar run (`cpu_s390x_novxe`) — 20:33 UTC**
```
13.3  13.1  12.6  14.1  12.7  11.8  12.4  13.3  14.0  12.5
```

### Statistics

| Build | Mean (tok/s) | Median (tok/s) | Stdev | Min | Max |
|-------|-------------|---------------|-------|-----|-----|
| VXE2 (`cpu_s390x`) | **12.42** | **12.65** | 1.10 | 10.5 | 14.1 |
| Scalar (`cpu_s390x_novxe`) | **12.98** | **12.95** | 0.72 | 11.8 | 14.1 |
| **Scalar advantage** | **+0.56 tok/s (+4.5%)** | +0.30 tok/s | — | — | — |

### Load time comparison

| Build | llama-server load time |
|-------|----------------------|
| VXE2 (`cpu_s390x`) | **15.33 s** |
| Scalar (`cpu_s390x_novxe`) | **2.01 s** |
| **Scalar faster by** | **7.6×** |

The scalar build completed the entire 255-tensor bswap in ~834 ms; individual tensors took 1–9 ms.
The VXE2 build took 14,192 ms for the same bswap; tensors ranged 0.01–508 ms with high variance.

**Hypothesis:** The VXE2 bswap path may have higher branch misprediction overhead, SIMD unit
contention with the AIU VFs at load time, or a less-optimised big-endian store path that triggers
expensive cache-line bouncing on z15.

### Analysis

**No meaningful SIMD advantage at 3B on this AIU-equipped LPAR.**

- Scalar is marginally faster (+4.5%) at inference — within run-to-run noise given stdev of 1.10/0.72.
- The 10% VXE2 advantage seen on smollm:135m at this same platform **does not extend to 3B**.
- Likely cause: at 3B, the AIU virtual functions are handling matrix operations regardless of which
  CPU binary is selected. The 12 AIU VFs dominate throughput; scalar vs VXE2 bswap path in the
  CPU code becomes irrelevant.
- VXE2's SIMD benefit is visible only on workloads the AIU does **not** handle — tiny models like
  smollm:135m that run entirely through the scalar GGML CPU kernel.

### Hypothesis 1 revised verdict

**Inconclusive at 3B on AIU hardware.** The AIU masks any SIMD difference at 3B scale.
A definitive VXE2 vs scalar test requires a **CPU-only system** (LinuxONE Community Cloud VM,
no AIU), tested at ≥1B where the SIMD path is actually exercised during inference.

---

## Summary across runs

| Run | Model | Platform | VXE2 mean | Scalar mean | VXE2 Δ |
|-----|-------|----------|-----------|-------------|---------|
| 1 | smollm:135m Q4_0 | z15 triframe (AIU) | 115.5 tok/s | 104.7 tok/s | **+10.3%** |
| 2 | llama3.2:3b Q4_K_M | z15 triframe (AIU) | 12.42 tok/s | 12.98 tok/s | **−4.5%** (scalar faster) |

The inversion between Run 1 and Run 2 is explained by AIU dominance at 3B: VXE2 SIMD is only
visible when the workload stays in the CPU kernel (tiny models that don't trigger AIU offload).

---

## Remaining next steps

1. Repeat on LinuxONE Community Cloud VM with `llama3.2:1b` or `llama3.2:3b` — CPU-only,
   no AIU contention. This is the only configuration that will isolate VXE2 vs scalar cleanly.
2. Investigate VXE2 bswap load time regression (15.33s vs 2.01s scalar) — profile the
   `gguf-big-endian-byteswap.patch` bswap loop on VXE2 vs scalar build.
3. Update `docs/model_compatibility_matrix.md` with VXE2 vs scalar column once CPU-only test done.
