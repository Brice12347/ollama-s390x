# Step 7 — Model Selection and Compatibility on s390x

Choosing the right model is important on IBM Z because LPARs have carefully sized
memory allocations and CPU-only inference is the only option (no GPU backend exists for s390x).
This guide summarises which models work, their resource requirements, and when to use each.

---

## Key constraint: mmap is disabled

On s390x, `mmap` is disabled to enable the big-endian byte-swap (see [docs/6-endianness-fix.md](6-endianness-fix.md)).
This means tensors are heap-allocated rather than memory-mapped.
**Add 20–30% to a model's nominal size when sizing pod `limits.memory` or LPAR memory.**

---

## Compatibility matrix

| Model | Tag | Quant | Params | Status | Tok/s | RAM |
|---|---|---|---|---|---|---|
| SmolLM 135M | `smollm:135m` | Q4_0 | 135M | ✅ | 104.6 | 178 MiB |
| SmolLM 360M | `smollm:360m` | Q4_0 | 360M | ✅ | 77.9 | 340 MiB |
| Llama 3.2 1B | `llama3.2:1b` | Q4_K_M | 1B | ✅ | 17.6 | 1.5 GiB |
| Llama 3.2 1B (Q8_0) | `llama3.2:1b-instruct-q8_0` | Q8_0 | 1B | ✅ | 22.75 | 1.5 GiB |
| Llama 3.2 1B (Q5_K_M) | `llama3.2:1b-instruct-q5_k_m` | Q5_K_M | 1B | ✅ | 21.6 | 1.1 GiB |
| Llama 3.2 1B (Q2_K) | `llama3.2:1b-instruct-q2_k` | Q2_K | 1B | ⚠️ | 4.4 | 781 MiB |
| Llama 3.2 1B (F16) | `llama3.2:1b-instruct-fp16` | F16 | 1B | ✅ | 4.9 | 2.5 GiB |
| Llama 3.2 3B | `llama3.2:3b` | Q4_K_M | 3B | ✅ | 12.2 | 2.4 GiB |
| Llama 3.2 3B (Q8_0) | `llama3.2:3b-instruct-q8_0` | Q8_0 | 3B | ✅ | 7.5 | 3.7 GiB |
| Granite 3.3 2B | `granite3.3:2b` | Q4_K_M | 2B | ✅ | 12.25 | 1.9 GiB |
| Mistral 7B | `mistral:7b` | Q4_K_M | 7B | ✅ | 5.8 | 4.6 GiB |
| Qwen2.5 0.5B | `qwen2.5:0.5b` | Q4_K_M | 500M | ❌ | — | — |

**Status:** ✅ Working · ⚠️ Unstable · ❌ Fails

> **Benchmarks:** Median of 15 consecutive runs, 80-token generation, prompt `"List 3 facts about the ocean."` First 1–2 runs excluded. CPU-only inference; results vary with host load and IFL count.

---

## Quantization format support

| Format | Status | Notes |
|---|---|---|
| Q4_0 | ✅ | |
| Q4_K_M | ✅ | Default for most Ollama-published models |
| Q5_K_M | ✅ | |
| Q8_0 | ✅ | Higher quality, higher RAM |
| F16 | ✅ | Full precision, highest RAM |
| Q2_K | ⚠️ | Highly variable throughput (1.4–11.4 tok/s) |
| IQ4_XS | ❌ | Fails to load — iQuant types not yet handled in `bswap_buf` |

---

## Recommendations by use case

| Use case | Recommended model | Why |
|---|---|---|
| CI / health checks / smoke tests | `smollm:135m` | ~178 MiB, ~105 tok/s, loads in seconds |
| E2E test baseline | `llama3.2:1b` | Industry-standard, predictable outputs |
| Enterprise demo / FFDC log analysis | `granite3.3:2b` | IBM model, best quality per GB on s390x |
| General chat | `llama3.2:3b` | Good balance of quality and speed |
| Low-memory LPARs (≤ 4 GiB) | `smollm:135m` or `llama3.2:1b` | Both fit comfortably |

---

## What to avoid

| Model / format | Why |
|---|---|
| `qwen2.5:0.5b` | Garbage output and server crash after first inference |
| IQ4_XS and other iQuant formats | Fail to load — `bswap_buf` does not handle iQuant types yet |
| Q2_K | Highly unstable throughput; use Q4_K_M instead |

---

## Memory sizing guide

When setting pod `resources.limits.memory` or LPAR allocation, use this formula:

```
limit = model_ram * 1.3
```

Example for `granite3.3:2b` (1.9 GiB):
```
1.9 * 1.3 ≈ 2.5 GiB minimum limit
```

The overhead comes from mmap being disabled on s390x: tensors are heap-allocated
rather than memory-mapped, increasing RSS relative to the model's nominal size.

---

## Pulling a model

```sh
# On a bare-metal / VM install
ollama pull granite3.3:2b

# Inside an OpenShift Deployment pod
oc exec -it deploy/ollama -n project-ollama -- ollama pull granite3.3:2b

# Inside a KServe InferenceService pod
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama pull granite3.3:2b

# List downloaded models
ollama list
```

---

## Next steps

| Goal | Guide |
|---|---|
| Install Ollama and try a model | [docs/1-install.md](1-install.md) |
| Understand why load times are long | [docs/6-endianness-fix.md](6-endianness-fix.md) |
| Deploy on OpenShift AI | [docs/4-openshift-deploy.md](4-openshift-deploy.md) |
