# zDNN Backend Design & Implementation Notes

**Date:** 2026-07-15
**Author:** Justin Veltri
**Branch:** `justin-testing-branch`
**Hardware:** IBM LinuxONE Emperor 5 (Type 9175 / z17 / arch15)
**Status:** Partial — `libggml-zdnn.so` builds and loads; quantized op dispatch not yet implemented

---

## Summary

This document records what was discovered, built, fixed, and measured during the
Sprint 4 zDNN investigation on 2026-07-15. It is intended to give the next
implementer a complete starting point.

**Key findings:**

- The test machine is a **z17 (LinuxONE Emperor 5, Type 9175)** — zDNN hardware
  is present and confirmed via `zdnn_is_nnpa_installed()`.
- `libzdnn` was not pre-installed; it was built from source
  ([IBM/zDNN](https://github.com/IBM/zDNN) v1.2.0) and installed to
  `/usr/local/lib`.
- The upstream llama.cpp backend (`ggml/src/ggml-zdnn/ggml-zdnn.cpp`) is a
  **real, substantial implementation** — not a stub. It implements the full ggml
  backend interface and dispatches `GGML_OP_MUL_MAT` to the zAIU co-processor.
- Two CMake bugs prevented the backend from being built and installed. Both are
  now fixed in this repo.
- After fixes, `libggml-zdnn.so` builds, installs, and the server loads it
  alongside `libggml-cpu-z15.so` and `libggml-cpu-z16.so`.
- **Benchmark result: zDNN + VXE ≈ VXE-only for Q4_K_M quantized models.**
  This is expected — the zDNN backend explicitly skips quantized tensor types.
  The path to real acceleration requires implementing quantized op dispatch.

---

## Hardware Confirmation

```
/proc/sysinfo:
  Manufacturer: IBM
  Type:         9175        ← LinuxONE Emperor 5 = IBM z17 / arch15
  Model:        708
```

Confirmed z17 via:
```sh
cat /proc/sysinfo | grep -E "Type|Model|Manufacturer"
```

z17 is required for zDNN / NNPA (Neural Network Processing Assist). The
`zdnn_is_nnpa_installed()` function returns `true` on this machine.

---

## What Was Built

### 1. libzdnn from source

The IBM zDNN library was not available as a system package. Built from source:

```sh
apt-get install -y git cmake build-essential autoconf automake libtool
git clone https://github.com/IBM/zDNN.git /tmp/zDNN
cd /tmp/zDNN
autoreconf --install
./configure
make -j8
make install   # installs to /usr/local/lib and /usr/local/include
ldconfig
```

Result:
```
/usr/local/lib/libzdnn.so.0
/usr/local/lib/libzdnn.so
/usr/local/include/zdnn.h
```

### 2. libggml-zdnn.so

After two CMake fixes (see below), `libggml-zdnn.so` builds and installs to
`build-zdnn/lib/ollama/libggml-zdnn.so` (30 KB).

Build command:
```sh
cmake -B build-zdnn . -DOLLAMA_S390X_ZDNN=ON -DOLLAMA_S390X_VXE=ON
cmake --build build-zdnn --parallel 8
```

---

## CMake Bugs Fixed

### Bug 1 — `GGML_ZDNN` not crossing FetchContent boundary

**File:** `llama/server/CMakeLists.txt`

**Problem:** `set(GGML_ZDNN ON CACHE BOOL ... FORCE)` sets the variable in the
`llama-server-local` CMake cache, but `FetchContent_MakeAvailable(llama_cpp)`
creates a separate build directory (`_deps/llama_cpp-build`) with its own fresh
`CMakeCache.txt`. On the first configure of that directory, `GGML_ZDNN` is
absent, so `option(GGML_ZDNN ... OFF)` in `ggml/CMakeLists.txt` writes `OFF`
into it. The cache entry in the parent is never consulted.

**Fix:** Add `set(GGML_ZDNN ON)` as a plain (non-cache) variable alongside the
cache entry. FetchContent's `add_subdirectory` call inherits normal variables
from the parent scope. The plain variable is visible when `option()` checks
whether to write its default, preventing the reset.

```cmake
if(OLLAMA_S390X_ZDNN AND CMAKE_SYSTEM_PROCESSOR MATCHES "s390x")
    set(GGML_ZDNN ON CACHE BOOL "..." FORCE)
    set(GGML_ZDNN ON)   # ← this line is the fix
    message(STATUS "  GGML_ZDNN forced ON (OLLAMA_S390X_ZDNN=ON)")
endif()
```

**Confirmed by:** `-- Including zDNN backend` appearing in build output after fix.

### Bug 2 — `libggml-zdnn.so` not installed

**File:** `llama/server/CMakeLists.txt`

**Problem:** The `install(CODE)` block that copies backend `.so` files to
`build-zdnn/lib/ollama/` uses a glob that only matches `libggml-cpu*` and
`libggml-blas*`. `libggml-zdnn.so` was compiled to `bin/` but never copied
to the install destination.

**Fix:** Add `libggml-zdnn*` to the glob patterns:

```cmake
file(GLOB _dir_cpu_backends
    LIST_DIRECTORIES false
    \"${_dir}/libggml-cpu*\"
    \"${_dir}/libggml-blas*\"
    \"${_dir}/libggml-zdnn*\"    # ← added
    ...
)
```

**Confirmed by:** `-- Installing: .../libggml-zdnn.so` in build output after fix.

---

## Benchmark Results

**Hardware:** z17 / LinuxONE Emperor 5 (Type 9175), 32 vCPUs, ~1007 GiB RAM
**Model:** `granite3.3:2b` (Q4_K_M quantization)
**Prompt:** "Explain what IBM Z is in 3 sentences."
**Settings:** `temperature=0`, `seed=1`, `num_predict=100`
**OpenBLAS:** not installed during this test run

| Build | Run 1 | Run 2 | Run 3 | Average |
|---|---|---|---|---|
| VXE only (`build/`) | 11 tok/s | 10 tok/s | 14 tok/s | **11.7 tok/s** |
| VXE + zDNN (`build-zdnn/`) | 13 tok/s | 11 tok/s | 12 tok/s | **12.0 tok/s** |

**Conclusion: no measurable improvement from zDNN on Q4_K_M workloads.**

---

## Why zDNN Shows No Improvement Yet

The zDNN backend's `supports_op()` function explicitly rejects quantized tensor types:

```cpp
// ggml-zdnn.cpp
case GGML_OP_MUL_MAT:
    switch (weights->type) {
        case GGML_TYPE_F32:
        case GGML_TYPE_F16:
        case GGML_TYPE_BF16:
            return true;   // ← only these three types are accepted
        default:
            return false;  // ← Q4_K_M, Q8_0, etc. all fall here
    }
```

The source comment says:
```cpp
// TODO: implement support for quantized types
// we currently only support f32, f16, and bf16
```

`granite3.3:2b` (and all typical Ollama models) use Q4_K_M quantization.
All `MUL_MAT` ops fall back to the CPU VXE path. The zAIU hardware is
initialized and detected but never actually dispatched to during inference.

To trigger real zDNN acceleration on a Q4_K_M model, the weights would need
to be loaded in F16 or F32 format (`--quantize f16`), which increases memory
usage significantly. This is not practical for production use.

---

## What Needs to Be Implemented

The path to real zDNN acceleration for quantized inference:

### Phase 1 — Dequantize-then-dispatch (medium effort, immediate gains)

The zDNN backend could dequantize weights to F16 on-the-fly before calling
`zdnn_matmul_op()`. This is what the BLAS backend does for non-F32 types.

In `ggml-zdnn.cpp`, the `ggml_zdnn_compute_forward_mul_mat` function would:
1. Detect quantized `src0` type
2. Dequantize to F16 into a temporary buffer using `ggml_get_type_traits()->to_float`
3. Stickify the F16 buffer
4. Call `zdnn_matmul_op()` as normal

**Effort:** 3–5 days. Adds a dequantization pass but gains zAIU hardware
acceleration for all matrix multiplications.

### Phase 2 — Native quantized dispatch (high effort, best performance)

IBM's zDNN library exposes `zdnn_quantized_matmul_op()` for INT8 quantized
matrix multiplication. This would avoid the dequantization overhead entirely.

This requires:
- Mapping GGML quantized block formats onto zDNN's quantization scheme
- Implementing stickification for quantized data
- Handling scale/offset extraction from GGML block headers

**Effort:** 2–4 weeks. Requires deep knowledge of both GGML quant formats and
zDNN's quantized tensor API.

### Phase 3 — Additional ops (incremental)

Beyond `MUL_MAT`, the zDNN library supports operations that map onto other
hot inference ops:

| zDNN function | GGML op | Notes |
|---|---|---|
| `zdnn_add()` | `GGML_OP_ADD` | Residual connections |
| `zdnn_softmax()` | `GGML_OP_SOFT_MAX` | Attention weights |
| `zdnn_gelu()` | `GGML_OP_GELU` | FFN activations |
| `zdnn_layernorm()` | `GGML_OP_NORM`, `GGML_OP_RMS_NORM` | Layer normalization |
| `zdnn_lstm()` / `zdnn_gru()` | — | Not relevant for transformer models |

**Effort:** 1–2 days per op once Phase 1 is working.

---

## Key Source Files

| File | Location | Purpose |
|---|---|---|
| `ggml-zdnn.cpp` | `_deps/llama_cpp-src/ggml/src/ggml-zdnn/` | Full backend implementation |
| `common.hpp` | same | Context structs, `ggml_backend_zdnn_buffer`, device context |
| `mmf.cpp` / `mmf.hpp` | same | Memory-mapped file helpers for tensor data |
| `utils.cpp` / `utils.hpp` | same | `ggml_zdnn_init_tensor`, `ggml_zdnn_load_tensor`, stickification |
| `zdnn.h` | `/usr/local/include/` | IBM zDNN public API |
| `llama/server/CMakeLists.txt` | this repo | Build wiring for `OLLAMA_S390X_ZDNN` |

The most important function to understand is `ggml_zdnn_mul_mat_f()` in
`mmf.cpp` — this is where the actual `zdnn_matmul_op()` call happens and
where dequantization support would be added.

---

## zDNN Tensor Layout (Stickification)

zDNN requires tensors to be converted from standard row-major layout into an
internal "stickified" format before any operation. This happens in
`ggml_zdnn_load_tensor()` via `zdnn_transform_ztensor()`.

The transformation is:
1. Allocate a `zdnn_ztensor` with a pre-transform descriptor matching the
   source shape and type
2. Call `zdnn_generate_transformed_desc()` to produce the hardware-native
   descriptor
3. Call `zdnn_init_ztensor_with_malloc()` to allocate the stickified buffer
4. Call `zdnn_transform_ztensor()` to convert the data

This must happen in `init_tensor` (for weights, done once at load time) and
in `set_tensor` (for activations, done per inference call). The current
implementation handles this correctly for F32/F16/BF16.

For quantized types, the dequantization step (Phase 1 above) would need to
happen before step 3, producing an F16 intermediate that can then be stickified.

---

## How to Re-run This Experiment

```sh
# 1. Build libzdnn (one-time, persists in container)
cd /tmp && git clone https://github.com/IBM/zDNN.git
cd zDNN && autoreconf --install && ./configure && make -j8 && make install && ldconfig

# 2. Build zDNN-enabled ollama
cd /workspace/ollama-s390x
cmake -B build-zdnn . -DOLLAMA_S390X_ZDNN=ON -DOLLAMA_S390X_VXE=ON
cmake --build build-zdnn --parallel 8

# 3. Verify libggml-zdnn.so is installed
ls build-zdnn/lib/ollama/ | grep zdnn

# 4. Run with zDNN
pkill ollama 2>/dev/null
OLLAMA_MODELS=/root/.ollama/models \
OLLAMA_LIB_DIR=/workspace/ollama-s390x/build-zdnn/lib/ollama \
LD_LIBRARY_PATH=/workspace/ollama-s390x/build-zdnn/lib/ollama:/usr/local/lib \
./ollama serve &
```

---

## References

- [IBM zDNN GitHub](https://github.com/IBM/zDNN)
- [zDNN API reference — zdnn.h](https://github.com/IBM/zDNN/blob/main/zdnn/zdnn.h)
- [ggml backend interface](ggml/src/ggml-backend-impl.h) — `ggml_backend_i`, `ggml_backend_buffer_i`
- [BLAS backend](ggml/src/ggml-blas/ggml-blas.cpp) — reference for dequantize-then-dispatch pattern
- [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) — VXE/VXE2 capabilities
- [`docs/bottleneck_analysis.md`](bottleneck_analysis.md) — original performance hypothesis document
