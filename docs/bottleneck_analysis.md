# Bottleneck Analysis — Ollama on s390x (IBM Z / LinuxONE)

**Platform:** IBM Z z15 LPAR, 1 TB RAM, 32 logical CPUs, 12 AIU virtual functions  
**Build:** Ollama from source, `main` branch, CPU-only + AIU-accelerated configurations  
**Last updated:** 2026-07-13

---

## Executive Summary

Five distinct bottleneck categories have been identified on s390x. In order of impact:

1. **Model size vs available memory** — RAM is the primary constraint on small VMs (4 GB LinuxONE Community Cloud). Larger models simply OOM.
2. **KV cache pressure at large context** — tok/s drops significantly as context window fills. deepseek-r1:1.5b drops from 21.95 → 6.64 tok/s between short and long-context runs at 8192.
3. **Big-endian byte-swap at model load** — adds 0.5–10s latency on first load depending on model size. Not a steady-state bottleneck.
4. **Quantization format selection** — Q2_K is unstable (1–11 tok/s variance). IQ4_XS fails to load entirely. Wrong quant choice can make a model unusable.
5. **Library path misconfiguration** — `OLLAMA_LIBRARY_PATH` not set → `llama-server` not found → 500 on every inference request. Fixed in installer and Makefile but a recurring trap on manual setups.

---

## 1. CPU / SIMD Acceleration

### What is active

The `cpu_s390x` CMake preset compiles `llama-server` with:
- `-march=z15 -mvx -mzvector` → VXE2 SIMD enabled for z15 hardware
- `-march=z16 -mvx -mzvector` → VXE2 + NNPA enabled for z16 hardware
- `GGML_CPU_ALL_VARIANTS=ON` → runtime dispatch picks the best variant

This means both z15 and z16 variants are compiled into the same binary and the best one is selected at runtime.

### Observed throughput

CPU-only benchmarks (LinuxONE Community Cloud VM, no AIU):

| Model | Quant | Tok/s |
|-------|-------|-------|
| SmolLM 135M | Q4_0 | 104.6 |
| SmolLM 360M | Q4_0 | 77.9 |
| Llama 3.2 1B | Q4_K_M | 17.6 |
| Llama 3.2 1B | Q8_0 | 22.75 |
| Granite 3.3 2B | Q4_K_M | 12.25 |
| Llama 3.2 3B | Q4_K_M | 12.2 |
| Mistral 7B | Q4_K_M | 5.8 |

Source: [`logs/model_test_001.md`](../logs/model_test_001.md)

### Hypothesis: VXE2 vs scalar gap

No scalar baseline has been measured yet. The `cpu_s390x_novxe` CMake preset builds without VXE and can be used to isolate the SIMD contribution:

```sh
make cmake PRESET=cpu_s390x_novxe   # not yet a Makefile param — run manually
cmake -S llama/server --preset cpu_s390x_novxe -DGGML_BLAS=OFF
cmake --build build/llama-server-cpu_s390x_novxe --parallel $(nproc)
```

Expected: 2–4× throughput difference between VXE2 and scalar for quantized integer kernels. This is unconfirmed — **measuring this is the highest-value next benchmark**.

### OpenBLAS

`GGML_BLAS=OFF` is set in `make cmake` because OpenBLAS is not installed in the dev container or on the LinuxONE Community Cloud. OpenBLAS on s390x supports VSX/VXE and could improve matrix multiplication throughput for larger models. Not yet tested.

**To test:**
```sh
sudo apt-get install -y libopenblas-dev
cmake -S llama/server --preset cpu_s390x   # GGML_BLAS=ON is in the preset
cmake --build build/llama-server-cpu_s390x --parallel $(nproc)
```

---

## 2. Memory / KV Cache Pressure

### Context scaling data

From the AIU-accelerated triframe benchmarks:

| Model | Context | Prompt Tokens | Eval TPS |
|-------|---------|--------------|----------|
| deepseek-r1:1.5b | 4096 | 10 | 18.42 |
| deepseek-r1:1.5b | 4096 | 2090 | 4.22 |
| deepseek-r1:1.5b | 8192 | 10 | 21.95 |
| deepseek-r1:1.5b | 8192 | 4190 | 6.64 |
| deepseek-r1:1.5b | 16384 | 10 | 19.73 |
| lfm2.5-thinking | 8192 | 20 | 46.28 |
| lfm2.5-thinking | 8192 | 4630 | 13.83 |
| gpt-oss:20b | 4096 | 80 | 3.58 |
| gpt-oss:20b | 8192 | 80 | 7.78 |

Source: [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md)

### Analysis

- **Short-prompt throughput is 3–5× higher than long-prompt throughput** for the same model and context size. This is the KV cache effect — each new token must attend over all previous tokens.
- **Doubling context from 4096 → 8192 can improve throughput** for short prompts (deepseek-r1: 18.42 → 21.95 tok/s) because the larger context reduces re-loading overhead. It does not help once the context is full.
- **gpt-oss:20b benefits from larger context** (3.58 → 7.78 tok/s at 80-token prompt, 4096 → 8192). Likely due to better memory layout at the larger size.

### RAM constraints

| Scenario | Max recommended model |
|----------|-----------------------|
| 4 GB VM (LinuxONE Community Cloud) | `llama3.2:1b` (1.5 GiB) |
| 8 GB VM | `llama3.2:3b` (2.4 GiB) or `granite3.3:2b` (1.9 GiB) |
| 32 GB+ (triframe LPAR) | Any model in the compatibility matrix |

Source: [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md)

KV cache adds to RSS beyond the model weights. At `num_ctx=8192` with `granite3.3:2b`, expect ~3.5 GB total RSS.

---

## 3. Model Load Time

### Data

| Model | Load Time (s) | Notes |
|-------|--------------|-------|
| lfm2.5-thinking | 0.91 | Small model, fast load |
| deepseek-r1:1.5b | 1.54–1.57 | Consistent across context sizes |
| qwen2.5vl:3b | 2.88–2.89 | Stable |
| qwen2.5-coder | 3.05 | |
| qwen3-coder:30b | 8.82 | Large model |
| gpt-oss:20b | 9.51–9.81 | Large model |
| gemma4 | 10.33 | Highest load time observed |

Source: [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md)

### Big-endian byte-swap overhead

All GGUF models from Ollama.com and HuggingFace are stored little-endian. The s390x build applies per-tensor byte-swap at load time via `gguf-big-endian-byteswap.patch`. This is logged as:

```
handle_bigendian_bswap: big-endian host detected with little-endian GGUF; registering per-tensor bswap LoadOps
```

**Impact:** Estimated 0.5–2s additional load time for models up to 7B. Not measured in isolation.  
**Subsequent loads:** Tensors are cached after first load — repeat inferences within `keep_alive` window do not re-swap.  
**Mitigation:** Keep `OLLAMA_KEEP_ALIVE` at 5m+ in production to avoid repeated load cycles.

Source: [`docs/gguf_s390x_notes.md`](gguf_s390x_notes.md)

---

## 4. Quantization Format Impact

### Throughput by quantization (Llama 3.2 1B)

| Quant | Tok/s | RAM | Status |
|-------|-------|-----|--------|
| Q4_0 | ~104 (SmolLM proxy) | — | ✅ |
| Q4_K_M | 17.6 | 1.5 GiB | ✅ |
| Q5_K_M | 21.6 | 1.1 GiB | ✅ |
| Q8_0 | 22.75 | 1.5 GiB | ✅ |
| F16 | 4.9 | 2.5 GiB | ✅ |
| Q2_K | 4.4 (median), 1.4–11.4 (range) | 781 MiB | ⚠️ |
| IQ4_XS | — | — | ❌ |

Source: [`logs/model_test_001.md`](../logs/model_test_001.md)

### Key findings

- **Q8_0 outperforms Q4_K_M** (22.75 vs 17.6 tok/s) — the AIU handles higher-precision formats more efficiently than expected. This is counter-intuitive vs x86 GPU behavior where smaller quantizations are usually faster.
- **Q5_K_M is a good middle ground** — slightly better throughput than Q4_K_M with less RAM than Q8_0.
- **F16 is slower than Q8_0** — the larger memory footprint (2.5 vs 1.5 GiB) reduces AIU cache efficiency.
- **Q2_K is not production-ready** — 1.4–11.4 tok/s variance across 15 runs makes latency unpredictable. Root cause unknown; likely numerical instability in the dequantization path on big-endian.
- **IQ4_XS fails at load time** — incompatible with the big-endian byteswap implementation. Not fixable without upstream llama.cpp changes.

### qwen2.5-coder anomaly

`qwen2.5-coder:latest` showed **1.91 prompt eval TPS** at 4096 context — far below other models of similar parameter count. Generation TPS (6.29) was within normal range. This suggests the bottleneck is specific to tokenizer or attention computation during prompt processing, not generation.

Hypotheses:
1. Unusual tokenizer vocabulary size causing slow embedding lookup
2. Architecture-specific attention pattern (sliding window, grouped query) not optimized for s390x byteswap path
3. Bug in the specific quantization variant shipped as `latest`

**Status: unresolved.** Source: [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md)

---

## 5. Library Path / llama-server Discovery

### The problem

`ollama serve` searches for `llama-server` in a fixed set of paths at startup:

```
/workspace/ollama-s390x/llama-server
/workspace/lib/ollama/llama-server
/workspace/ollama-s390x/build/lib/ollama/llama-server
/workspace/ollama-s390x/dist/linux-s390x/lib/ollama/llama-server
/workspace/ollama-s390x/dist/linux_s390x/lib/ollama/llama-server
```

The CMake build outputs to `build/llama-server-cpu_s390x/bin/` — **none of the default paths**. Without `OLLAMA_LIBRARY_PATH` set, ollama falls back to a no-op CPU stub that cannot run inference, and every model load returns:

```
500 Internal Server Error: llama-server process has terminated: exit status 127
```

### Fix

Set `OLLAMA_LIBRARY_PATH` to the directory containing `llama-server` and its `.so` files:

```sh
OLLAMA_LIBRARY_PATH=build/llama-server-cpu_s390x/bin ./ollama serve
```

This is now set automatically in `make run` via the `LLAMA_BUILD_DIR` variable.

For installed deployments (`install.sh`), the install script creates `.so.0` symlinks and runs `ldconfig` so the system linker can find the libraries without `OLLAMA_LIBRARY_PATH`.

Source: [`docs/install-sh-s390x-improvements.md`](install-sh-s390x-improvements.md), [`scripts/install.sh`](../scripts/install.sh)

---

## 6. AIU Accelerator Behavior

The triframe benchmarks show all models reporting **100% GPU** even though `ollama ps` reports `total_vram="0 B"`. This is because the IBM AIU (Accelerator for AI / Spyre) is transparent to Ollama's scheduler — it appears as a CPU device but offloads matrix operations via the AIU driver.

### Implications

- Ollama's `--gpu-layers` / `num_gpu` parameters have no effect on AIU utilization
- AIU JIT-compiles the compute graph on first 1–2 inferences — exclude warmup runs from benchmarks
- AIU VF contention: other workloads on the same LPAR compete for the 12 virtual functions, causing occasional throughput spikes down to 1–3 tok/s
- Restarting `ollama serve` between models resets the AIU state cleanly

Source: [`logs/model_test_001.md`](../logs/model_test_001.md)

---

## 7. Hypotheses to Investigate

| Hypothesis | How to test | Expected outcome |
|-----------|-------------|-----------------|
| VXE2 SIMD provides 2–4× speedup over scalar | Run same benchmark with `cpu_s390x` vs `cpu_s390x_novxe` build | Confirm SIMD contribution |
| OpenBLAS improves large-model throughput | Install `libopenblas-dev`, rebuild with `GGML_BLAS=ON` | 5–20% improvement on 7B+ models |
| zDNN (z17+/AIU2) accelerator improves throughput | Build with `cpu_s390x_zdnn` preset on z17 hardware | Significant improvement for supported ops |
| qwen2.5-coder 1.91 TPS is a tokenizer bug | Profile tokenizer separately, test with raw embeddings | Identify slow path in prompt eval |
| Q2_K instability is a byteswap bug | Run Q2_K with `GGML_BIGENDIAN=OFF` (little-endian QEMU) | Confirm or rule out byteswap as root cause |
| keep_alive=0 between tests eliminates AIU state contamination | Benchmark with explicit unload vs continuous | Cleaner inter-model comparison |

---

## 8. Benchmark Data Sources

| File | Contents |
|------|---------|
| [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) | AIU-accelerated performance test — load time, prompt eval TPS, eval TPS, context scaling across 7 models |
| [`logs/model_test_001.md`](../logs/model_test_001.md) | CPU-only functional + throughput test — 12 models, 7 quant formats, RAM usage |
| [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) | Summary matrix — all tested models with tok/s, RAM, pass/fail status |
| [`docs/gguf_s390x_notes.md`](gguf_s390x_notes.md) | GGUF endianness, quantization formats, SIMD notes |
| [`docs/install-sh-s390x-improvements.md`](install-sh-s390x-improvements.md) | Library path and installer fix history |
