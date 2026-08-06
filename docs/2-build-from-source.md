# Step 2 — Build Ollama from Source on s390x

Complete build reference for IBM Z (s390x). Three paths are documented:

| Path | When to use |
|---|---|
| [A — CPU/VXE (default)](#path-a--cpuvxe-default) | Standard build; works on any s390x LPAR or LinuxONE VM |
| [B — zDNN/zAIU](#path-b--zdnnzaiu-z17) | IBM z17+ with NNPA hardware and the `llama.cpp-s390x` fork |
| [C — Go-only iteration](#path-c--go-only-iteration) | Fast inner loop when only Go code changed |

---

## Prerequisites

Install all build dependencies on Ubuntu 22.04 / Debian 12 (s390x):

```sh
sudo apt update && sudo apt install -y \
  build-essential cmake ninja-build git \
  golang-go libopenblas-dev
```

Minimum versions:

| Tool | Minimum | Check |
|---|---|---|
| Go | 1.22 | `go version` |
| CMake | 3.24 | `cmake --version` |
| GCC / G++ | 11 | `gcc --version` |
| Ninja | any | `ninja --version` |
| OpenBLAS | any | `dpkg -l libopenblas-dev` |

---

## Clone

```sh
git clone https://github.com/Brice12347/ollama-s390x.git
cd ollama-s390x
```

---

## Path A — CPU/VXE (default)

Standard build. Enables VXE2 SIMD (IBM z15+, auto-detected by GGML) and OpenBLAS.
The CMake configure step fetches llama.cpp at the pinned commit in `LLAMA_CPP_VERSION`
and applies the three endianness patches automatically.

### Configure + build

```sh
cmake -B build .
cmake --build build --parallel 8
```

CMake variables set by the `cpu_s390x` preset (from [`llama/server/CMakePresets.json`](../llama/server/CMakePresets.json)):

| Variable | Value | Effect |
|---|---|---|
| `OLLAMA_S390X_BIGENDIAN` | `ON` | Enables the big-endian byteswap code path |
| `GGML_CPU_ALL_VARIANTS` | `ON` | Builds all GGML CPU micro-kernel variants |
| `GGML_BLAS` | `ON` | Enables BLAS (OpenBLAS) acceleration |
| `GGML_BLAS_VENDOR` | `OpenBLAS` | Selects OpenBLAS as the BLAS backend |
| `GGML_VXE` | `ON` | Enables VXE/VXE2 128-bit SIMD (IBM z15+) |
| `BUILD_SHARED_LIBS` | `ON` | Produces `.so` shared libraries |
| `GGML_BACKEND_DL` | `ON` | Dynamic backend loader |
| `CMAKE_BUILD_TYPE` | `Release` | Optimised release build |

### Output locations

| Artifact | Path |
|---|---|
| `ollama` binary | `./ollama` (repo root) |
| `llama-server` + GGML shared libs | `build/lib/ollama/` |
| Installed layout | `dist/lib/ollama/` (after `cmake --install`) |

### Start the server

```sh
./ollama serve
```

Confirm the byteswap path is active — look for this line when a model loads:

```
compat patch disabled mmap for transformed text tensors
```

### Test inference

```sh
# In a second terminal
./ollama run smollm:135m "Hello, how are you?"
```

Before the fix: `.....................`  
After the fix: coherent text response

### Install to system prefix

```sh
cmake --install build --prefix /usr/local
# Binary: /usr/local/bin/ollama
# Libraries: /usr/local/lib/ollama/
```

---

## Path B — zDNN/zAIU (z17+)

Builds the zDNN hardware acceleration backend using the `cpu_s390x_zdnn` CMake preset.
This requires:

1. IBM z17+ hardware with NNPA (Neural Network Processing Assist)
2. The `libzdnn` library installed on the build host
3. The `llama.cpp-s390x` fork (the default upstream llama.cpp has no zDNN implementation)

### Status

> **Current status (as of internship handoff):** The Ollama scaffolding (`cpu_s390x_zdnn` preset, `cmake/local.cmake`, `Dockerfile.kserve` stage) is complete. The real zDNN GGML backend exists in `../llama.cpp-s390x/ggml/src/ggml-zdnn` but is **not yet integrated into a validated end-to-end build**. The next step is a configure + build attempt using the source override below. See [`docs/zdnn-status.md`](zdnn-status.md) for full context.

### Install libzdnn (Ubuntu/Debian)

```sh
sudo apt install -y libzdnn-dev
# Verify:
ls /usr/lib/s390x-linux-gnu/libzdnn.so* 2>/dev/null \
  || ls /usr/local/lib/libzdnn.so* 2>/dev/null \
  || echo "libzdnn not found — build from source (see below)"
```

#### Build libzdnn from source (if package unavailable)

```sh
sudo apt install -y autoconf automake libtool
git clone --depth 1 -b v1.1.1 https://github.com/IBM/zDNN.git /tmp/zdnn
cd /tmp/zdnn
autoconf
./configure --prefix=/usr/local
make -j$(nproc) build
sudo make install
sudo ldconfig
```

### Point Ollama at the zDNN-capable llama.cpp fork

The default llama.cpp fetched by Ollama's CMake has no `ggml-zdnn` backend.
Use `OLLAMA_LLAMA_CPP_SOURCE` to override the source path:

```sh
# Assumes the fork is checked out as a sibling of this repo
export OLLAMA_LLAMA_CPP_SOURCE=../llama.cpp-s390x
```

Or clone it if you don't have it:

```sh
git clone https://github.com/IBM/llama.cpp-s390x.git ../llama.cpp-s390x
```

### Configure + build (zDNN)

```sh
OLLAMA_LLAMA_CPP_SOURCE=../llama.cpp-s390x \
  cmake -B build .

cmake --build build --parallel 8
```

CMake variables set by the `cpu_s390x_zdnn` preset (inherits `cpu_s390x_base`):

| Variable | Value | Effect |
|---|---|---|
| `OLLAMA_S390X_BIGENDIAN` | `ON` | Big-endian byteswap |
| `GGML_CPU_ALL_VARIANTS` | `ON` | All CPU micro-kernels |
| `GGML_BLAS` | `ON` | OpenBLAS |
| `GGML_BLAS_VENDOR` | `OpenBLAS` | |
| `GGML_VXE` | `ON` | VXE2 SIMD |
| `GGML_ZDNN` | `ON` | **Enables the zDNN backend** |

#### Build just the llama-server backend (without full Ollama Go binary)

Useful for validating the C++ layer before compiling Go:

```sh
OLLAMA_LLAMA_CPP_SOURCE=../llama.cpp-s390x \
  cmake -S llama/server --preset cpu_s390x_zdnn

cmake --build build/llama-server-cpu_s390x_zdnn -- -l $(nproc)
cmake --install build/llama-server-cpu_s390x_zdnn --component llama-server --strip
# Output: dist/lib/ollama/s390x_zdnn/
```

### Selecting the zDNN runtime at inference time

Ollama auto-discovers runners by scanning subdirectories of `lib/ollama/`.
The zDNN runner lives in `lib/ollama/s390x_zdnn/`.

To force Ollama to use only the zDNN runner (bypassing CPU auto-selection):

```sh
OLLAMA_RUNNERS_DIR=/usr/lib/ollama/s390x_zdnn ./ollama serve
```

Or in a container/pod via environment variable — see [`t9-kserve/servingruntime.yaml`](../t9-kserve/servingruntime.yaml).

### Verify zDNN is loaded

```sh
./ollama serve 2>&1 | grep -i zdnn
# Expected: a line referencing the zdnn backend or nnpa capability check
```

On hardware without NNPA (z15 or earlier), the runtime NNPA check in
`ggml-zdnn.cpp` will cause Ollama to fall back to the CPU runner automatically.

---

## Path C — Go-only iteration

When only Go code has changed and the native payload is already built (or installed from the one-liner):

```sh
go build .
go run . serve
```

> **If native code and Go data structures get out of sync**, force a full rebuild:
> ```sh
> go clean -cache
> cmake -B build .
> cmake --build build --parallel 8
> ```

---

## Available presets

All presets are defined in [`llama/server/CMakePresets.json`](../llama/server/CMakePresets.json).

| Preset | Binary dir | Key flags | Use case |
|---|---|---|---|
| `cpu_s390x` | `build/llama-server-cpu_s390x` | `GGML_VXE=ON` | Standard s390x build (z15+) |
| `cpu_s390x_zdnn` | `build/llama-server-cpu_s390x_zdnn` | `GGML_VXE=ON`, `GGML_ZDNN=ON` | z17+ with NNPA hardware |
| `cpu_s390x_novxe` | `build/llama-server-cpu_s390x_novxe` | `GGML_VXE=OFF` | Scalar-only, z14 or debugging |
| `cpu_s390x_spyre` | `build/llama-server-cpu_s390x_spyre` | `GGML_VXE=ON` | Spyre scaffolding (mirrors CPU until native support) |

To build just the llama-server backend for a specific preset:

```sh
cmake -S llama/server --preset <preset-name>
cmake --build build/llama-server-<preset-name> -- -l $(nproc)
cmake --install build/llama-server-<preset-name> --component llama-server --strip
```

---

## How the endianness patches are applied

The patches in [`llama/compat/`](../llama/compat/) are applied automatically by
`apply-patch.cmake` during `cmake -B build .` via CMake's FetchContent `PATCH_COMMAND`.
Applied in filename order against the pinned llama.cpp commit (`LLAMA_CPP_VERSION`):

| Patch | Purpose |
|---|---|
| `001-llama-cpp-hooks.patch` | Compat layer call-site insertions |
| `002-gguf-big-endian-byteswap.patch` | GGUF metadata byteswap |
| `003-tensor-data-big-endian-byteswap.patch` | Tensor weight byteswap (the critical fix) |

Patches are **idempotent** — re-running `cmake -B build .` does not re-apply already-applied patches.

When using `OLLAMA_LLAMA_CPP_SOURCE` to point at a fork, patches whose target file is absent
are **skipped with a WARNING** (not a fatal error) — this allows patches targeting files added
in newer upstream commits to be silently bypassed against older forks.

See [docs/6-endianness-fix.md](6-endianness-fix.md) for the full technical explanation.

---

## Run tests

```sh
go test ./...
```

---

## Next steps

| Goal | Guide |
|---|---|
| Build a container image | [docs/3-container-build.md](3-container-build.md) |
| Deploy on OpenShift AI | [docs/4-openshift-deploy.md](4-openshift-deploy.md) |
| Understand the endianness fix | [docs/6-endianness-fix.md](6-endianness-fix.md) |
| zDNN current status and next steps | [docs/zdnn-status.md](zdnn-status.md) |
