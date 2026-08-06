# The Endianness Fix — How Ollama Was Made to Work on s390x

This document explains the core technical problem that prevented Ollama from producing
coherent output on IBM Z (s390x) and how it was solved.

---

## The problem in one sentence

GGUF model files are stored in **little-endian** byte order.
IBM Z (s390x) is a **big-endian** architecture.
Without correction, every scale factor in every quantized weight block is read with its bytes reversed — and the model produces garbage output.

---

## Background: what was already working

Work at the IBM China Systems Lab (2023) and later contributions by Aaron Teo (IBM Technology Singapore) established llama.cpp as viable on s390x. Those efforts:

- Introduced big-endian awareness into GGUF conversion tooling and the model loader (GGUFv3)
- Added VXE/VXE2 (128-bit SIMD) support for IBM z15 and later
- Documented build procedures and benchmarked performance across IFL counts and SMT settings

The existing `002-gguf-big-endian-byteswap.patch` already fixed the **GGUF metadata** layer — the key-value pairs in the file header (architecture name, hyperparameters, tokeniser data) were byte-swapped correctly when the file was opened. The model would load, tokenise input, and start producing tokens — but the tokens were garbage.

---

## What was missing: tensor data

The **tensor data** — the actual weight matrices the model computes with — was not being byte-swapped.

In a quantized block like Q4_K or Q8_0, each block contains:

- **Integer quant bits** — packed nibbles or bytes. These are byte arrays with no endian sensitivity. No swap needed.
- **FP16/FP32 scale fields** (`d`, `dmin`) — floating-point values used to dequantize the integer bits back to real numbers. These are multi-byte values that **must be byte-swapped** on big-endian hosts.

| Type | Block size | Scale field position |
|---|---|---|
| F16 / BF16 | 2 bytes | entire value |
| F32 | 4 bytes | entire value |
| Q4_0, Q5_0, Q8_0 | 18–34 B | `d` at offset 0 |
| Q4_1, Q5_1 | 20–36 B | `d` at offset 0, `m` at offset 2 |
| Q4_K | 144 B | `d` at offset 0, `dmin` at offset 2 |
| Q5_K | 176 B | `d` at offset 0, `dmin` at offset 2 |
| Q2_K | 84 B | `d` at offset 80, `dmin` at offset 82 |
| Q3_K | 110 B | `d` at offset 108 |
| Q6_K | 210 B | `d` at offset 208 |

Most Ollama-distributed models use **Q4_K_M** format (`GGML_TYPE_Q4_K`), which was entirely absent from the initial byteswap attempt — explaining why results were always garbage.

---

## Why mmap made it harder

llama.cpp uses `mmap()` by default to load model files on Linux.
`mmap` maps the file directly into the process's virtual address space as a **read-only region**.
Attempting to byte-swap in place would fault immediately.

The byte-swap must happen into a **writable buffer**, which only exists when `mmap` is disabled and tensors are loaded via `read()`.

---

## Why the first fix attempt didn't work

llama.cpp has two tensor loading code paths:

- `load_data_for()` — loads a single tensor; used by offline tools like `llama-quantize`
- `load_all_data()` — loads all tensors in a loop; used by the **actual inference server**

The initial byteswap implementation hooked only `load_data_for`. Inference goes through `load_all_data`, so the byteswap never ran during a real `ollama run`.

---

## The fix

### Patch 1: `003-tensor-data-big-endian-byteswap.patch`

Applied to llama.cpp at build time (against the pinned commit in `LLAMA_CPP_VERSION`).

Two functions are added to `src/llama-model-loader.cpp`:

```c
// Works on a raw buffer
static void bswap_buf(ggml_type type, uint8_t * data, size_t nbytes);

// Thin wrapper for ggml_tensor* callers
static void bswap_tensor_data(struct ggml_tensor * t);
```

Both compile to **no-ops on little-endian hosts** via:

```c
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && \
    (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
```

Three call sites are patched:
1. `load_data_for()` — after `file->read_raw()`, before validation
2. `load_all_data()`, host-buffer path — after `file->read_raw(cur->data, n_size)`
3. `load_all_data()`, non-host-buffer path — after `file->read_raw(read_buf.data(), n_size)`, before `ggml_backend_tensor_set()`

### Patch 2: disable mmap on big-endian hosts

In `llama/compat/llama-ollama-compat.cpp`, the `translate_metadata()` function (which runs at model load time before any tensor data is read) forces llama.cpp off the zero-copy mmap path:

```cpp
#if defined(__BYTE_ORDER__) && defined(__ORDER_BIG_ENDIAN__) && \
    (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
    disable_mmap_for(ml);
#endif
```

This ensures every tensor read goes through a writable buffer where `bswap_tensor_data` can operate.

---

## How the patches are delivered

The patches live in [`llama/compat/`](../llama/compat/) and are applied automatically by
`apply-patch.cmake` during `cmake -B build .` via FetchContent's `PATCH_COMMAND`.
They are applied in filename order:

| File | Purpose |
|---|---|
| `001-llama-cpp-hooks.patch` | Compat layer call-site insertions |
| `002-gguf-big-endian-byteswap.patch` | GGUF metadata byteswap (pre-existing) |
| `003-tensor-data-big-endian-byteswap.patch` | Tensor weight byteswap (this work) |

The patches are idempotent — re-running `cmake -B build .` does not re-apply already-applied patches.

---

## Verification

Start the server. When a model loads, look for this line in the server log:

```
compat patch disabled mmap for transformed text tensors
```

This confirms mmap was disabled and the byteswap path is active.

Then:

```sh
./ollama run smollm:135m "Hello, how are you?"
```

| Before fix | After fix |
|---|---|
| `.....................` | Coherent text response |

---

## Side effects and limitations

| Effect | Detail |
|---|---|
| **Higher memory usage** | mmap disabled → tensors are heap-allocated rather than mapped. Add 20–30% to the model's nominal RSS when sizing pods or LPARs. |
| **Slower cold start** | Every cold load byte-swaps the tensor data. A 135M model takes 5–6 minutes on CPU-only s390x. Set `OLLAMA_LOAD_TIMEOUT=30m`. |
| **No GPU support** | s390x has no GGML GPU backend. All inference is CPU-only. |
| **iQuant types not covered** | IQ2_XXS, IQ3_S, IQ4_XS and similar iQuant formats are not yet handled in `bswap_buf`. These are uncommon in Ollama-published models. |
| **Patch is temporary** | The right long-term fix is for GGUF or llama.cpp to handle big-endian natively. This patch bridges the gap until that happens upstream. |

---

## File reference

| File | Purpose |
|---|---|
| `llama/compat/003-tensor-data-big-endian-byteswap.patch` | Injects `bswap_buf` / `bswap_tensor_data` into llama.cpp's tensor load paths |
| `llama/compat/llama-ollama-compat.cpp` | Disables mmap on big-endian in `translate_metadata()` |
| `llama/compat/apply-patch.cmake` | Idempotent patch applier invoked by FetchContent |
| `llama/compat/compat.cmake` | Wires the patch command into the FetchContent declaration |
| `LLAMA_CPP_VERSION` | Pinned llama.cpp commit the patches are written against |
