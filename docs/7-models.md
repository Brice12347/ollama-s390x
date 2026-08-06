# Step 7 — Model Selection and Compatibility on s390x

Choosing the right model matters on IBM Z. LPARs have carefully sized memory allocations,
CPU-only inference is the only option (no GPU backend), and the big-endian byte-swap adds
load-time overhead that scales with model size. This guide gives you everything you need
to pick a model and size resources correctly.

---

## s390x-specific quirks that affect your choice

### mmap is disabled — add 20–30% to all RAM figures

On s390x, `mmap` is disabled so tensors can be byte-swapped on load (see
[docs/6-endianness-fix.md](6-endianness-fix.md)). Tensors are heap-allocated rather than
memory-mapped. **Use `RAM × 1.3` as your pod `limits.memory` or LPAR allocation.**

### Q8_0 is faster than Q4_K_M on s390x

This is the **opposite** of the typical x86_64 expectation. On x86, higher compression
usually means higher throughput. On s390x, the 128-bit VXE2 vector registers align better
with Q8_0's 8-bit integer layout than Q4_K_M's 4-bit packed layout, producing higher
eval TPS despite more data moving through memory.

| Quant | Llama 3.2 1B tok/s | Llama 3.2 3B tok/s |
|---|---|---|
| Q8_0 | **22.75** | **7.5** |
| Q5_K_M | 21.6 | — |
| Q4_K_M | 17.6 | 12.2 |

**Recommendation:** use Q8_0 when you have the RAM headroom; use Q4_K_M when memory is tight.

### Cold load takes minutes, not seconds

Every cold load byte-swaps the entire model from LE→BE. On CPU-only s390x:

| Model | Approx cold load time |
|---|---|
| `smollm:135m` | ~5–6 minutes |
| `llama3.2:1b` | ~10–12 minutes |
| `granite3.3:2b` | ~15–20 minutes |

Set `OLLAMA_LOAD_TIMEOUT=30m` and keep the model warm with `OLLAMA_KEEP_ALIVE=-1`.

---

## Compatibility matrix

Benchmarks: median of 15 runs, 80-token generation, prompt `"List 3 facts about the ocean."`,
first 1–2 runs excluded (AIU JIT warmup), on a z15 LPAR with AIU (12 VFs).
RAM = `VmRSS` of `llama-server` after a completed generation.

| Model | Tag | Quant | Params | Status | Tok/s | RAM | Pod limit |
|---|---|---|---|---|---|---|---|
| SmolLM 135M | `smollm:135m` | Q4_0 | 135M | ✅ | 104.6 | 178 MiB | 256 MiB |
| SmolLM 360M | `smollm:360m` | Q4_0 | 360M | ✅ | 77.9 | 340 MiB | 512 MiB |
| Llama 3.2 1B | `llama3.2:1b` | Q4_K_M | 1B | ✅ | 17.6 | 1.5 GiB | 2 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-q8_0` | Q8_0 | 1B | ✅ | **22.75** | 1.5 GiB | 2 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-q5_k_m` | Q5_K_M | 1B | ✅ | 21.6 | 1.1 GiB | 1.5 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-q2_k` | Q2_K | 1B | ⚠️ | 4.4 | 781 MiB | 1.1 GiB |
| Llama 3.2 1B | `llama3.2:1b-instruct-fp16` | F16 | 1B | ✅ | 4.9 | 2.5 GiB | 3.3 GiB |
| Llama 3.2 3B | `llama3.2:3b` | Q4_K_M | 3B | ✅ | 12.2 | 2.4 GiB | 3.2 GiB |
| Llama 3.2 3B | `llama3.2:3b-instruct-q8_0` | Q8_0 | 3B | ✅ | **7.5** | 3.7 GiB | 4.9 GiB |
| Granite 3.3 2B | `granite3.3:2b` | Q4_K_M | 2B | ✅ | 12.25 | 1.9 GiB | 2.5 GiB |
| Mistral 7B | `mistral:7b` | Q4_K_M | 7B | ✅ | 5.8 | 4.6 GiB | 6 GiB |
| Qwen2.5 0.5B | `qwen2.5:0.5b` | Q4_K_M | 500M | ❌ | — | — | — |

**Status:** ✅ Working · ⚠️ Unstable · ❌ Do not use

> **Pod limit** = RAM × 1.3, rounded up. Use this value for `resources.limits.memory` in
> your Deployment or InferenceService manifest.

---

## Quantization format support

| Format | Status | Notes |
|---|---|---|
| Q4_0 | ✅ | Fastest for very small models (smollm) |
| Q4_K_M | ✅ | Default for most Ollama-published models; good memory/quality tradeoff |
| Q5_K_M | ✅ | Slightly better quality than Q4_K_M, modest RAM increase |
| Q8_0 | ✅ | **Recommended on s390x** — faster than Q4_K_M due to VXE2 alignment |
| F16 | ✅ | Full precision; highest RAM, lowest throughput |
| Q2_K | ⚠️ | Highly variable throughput (1.4–11.4 tok/s); avoid in production |
| IQ4_XS | ❌ | Fails to load — iQuant types not yet handled in `bswap_buf` |
| IQ3_S, IQ2_XXS | ❌ | Same reason — iQuant family unsupported |

---

## Recommendations by use case

| Use case | Model | Tag | Why |
|---|---|---|---|
| CI smoke test / health check | SmolLM 135M | `smollm:135m` | 178 MiB, ~105 tok/s, fastest cold start |
| E2E test baseline | Llama 3.2 1B | `llama3.2:1b-instruct-q8_0` | Highest tok/s for 1B on s390x |
| Enterprise demo / FFDC log analysis | Granite 3.3 2B | `granite3.3:2b` | IBM model, best quality per GB |
| General chat | Llama 3.2 3B | `llama3.2:3b` | Good quality/speed balance |
| Low-memory LPAR (≤ 4 GiB total) | SmolLM 135M or Llama 3.2 1B | `smollm:135m` / `llama3.2:1b` | Both fit with headroom |
| Highest quality within 8 GiB | Mistral 7B | `mistral:7b` | 5.8 tok/s, needs 6 GiB limit |

---

## Do not pull these

| Tag | Failure mode |
|---|---|
| `qwen2.5:0.5b` | Garbage output on first inference, then server crash |
| `llama3.2:1b-instruct-q2_k` | Throughput varies 1.4–11.4 tok/s; unreliable for any consistent workload |
| Any `IQ4_XS`, `IQ3_S`, `IQ2_XXS` tag | Fails to load — `bswap_buf` does not handle iQuant types |

---

## Copy-paste pull commands (all validated models)

Run these on a bare-metal/VM install. For OpenShift see the `oc exec` variants below.

```sh
# --- Smoke test / CI ---
ollama pull smollm:135m
ollama pull smollm:360m

# --- 1B class (use q8_0 for best throughput on s390x) ---
ollama pull llama3.2:1b                        # Q4_K_M  — memory-constrained systems
ollama pull llama3.2:1b-instruct-q8_0          # Q8_0    — recommended for s390x
ollama pull llama3.2:1b-instruct-q5_k_m        # Q5_K_M  — middle ground

# --- 2–3B class ---
ollama pull granite3.3:2b                      # Q4_K_M  — IBM model, FFDC/enterprise
ollama pull llama3.2:3b                        # Q4_K_M
ollama pull llama3.2:3b-instruct-q8_0          # Q8_0    — needs ~5 GiB limit

# --- 7B class (requires ≥ 6 GiB pod limit) ---
ollama pull mistral:7b
```

For OpenShift Deployment pods:
```sh
oc exec -it deploy/ollama -n project-ollama -- ollama pull granite3.3:2b
```

For KServe InferenceService pods:
```sh
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama pull granite3.3:2b
```

Verify what's loaded:
```sh
ollama list
curl -s http://localhost:11434/api/tags | jq '.models[] | {name, size}'
```

---

## Memory sizing reference

| Pod `limits.memory` | Models that fit |
|---|---|
| 512 MiB | `smollm:135m`, `smollm:360m` |
| 2 GiB | + `llama3.2:1b` (any quant) |
| 3 GiB | + `llama3.2:1b-instruct-fp16`, `llama3.2:3b` (Q4_K_M) |
| 4 GiB | + `granite3.3:2b`, `llama3.2:3b` (Q4_K_M) with headroom |
| 5 GiB | + `llama3.2:3b-instruct-q8_0` |
| 6+ GiB | + `mistral:7b` |

Formula: `limits.memory = RSS × 1.3` (extra 30% for the transient byte-swap buffer on cold load).

---

## Next steps

| Goal | Guide |
|---|---|
| Install Ollama and run a model | [docs/1-install.md](1-install.md) |
| Understand why cold loads are slow | [docs/6-endianness-fix.md](6-endianness-fix.md) |
| Deploy on OpenShift AI | [docs/4-openshift-deploy.md](4-openshift-deploy.md) |
| Full benchmark methodology | [docs/performance_metrics.md](performance_metrics.md) |
