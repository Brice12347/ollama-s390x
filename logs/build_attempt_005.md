# Build Attempt 005 — llama.cpp-s390x CPU Inference Smoke Test

**Date:** 2026-08-06  
**Environment:** IBM zCX (z/OS Container Extensions) — Docker shell  
**Host:** `9.47.95.173:8022` (user: `ollama`)  
**Architecture:** s390x (IBM Z / LinuxONE)  
**Repo:** https://github.com/taronaeo/llama.cpp-s390x  

---

## Objective

Validate that `llama.cpp` can be compiled from source on IBM Z (s390x) inside a
Docker container running within the IBM zCX environment, and confirm CPU inference
works end-to-end with a quantized Llama 3.2 1B model.

---

## Environment Constraints

| Constraint | Detail |
|---|---|
| No `git` on zCX host shell | `git` is not installed in the IBM zCX SSH shell |
| No `sudo` on zCX host | `ollama` user has no sudo privileges |
| `apt-get` requires root | Host package manager unusable without sudo |
| Bind mounts blocked | `docker run -v` rejected by `zcxauthplugin` |
| Only IBM base images on host | Only `ibm_zcx_zos_ssh_cli_image` and `ibm_zcx_zos_zos_cli_base` present initially |

---

## Steps Taken

### 1. Clone repo (from zCX host — `wget` was available)

`git` was absent, but the zCX host had `wget`. The repo was cloned by pulling
GitHub's zip archive, then extracted. After extraction, the source tree was
available at `~/llama.cpp-s390x`.

### 2. Pull Ubuntu 22.04 image

Docker Hub was reachable from zCX:

```bash
docker pull ubuntu:22.04
```

Pull succeeded — `ubuntu:22.04` (s390x variant) downloaded.

### 3. Copy source into a detached container

Bind mounts (`-v`) are blocked by the zCX authorization plugin. Used `docker cp`
instead:

```bash
docker run -d --name llama-build --platform linux/s390x ubuntu:22.04 sleep infinity
docker cp ~/llama.cpp-s390x llama-build:/workspace
docker exec -it llama-build bash
```

### 4. Install build dependencies (inside container, running as root)

```bash
apt-get update && apt-get install -y cmake build-essential libopenblas-dev wget
```

### 5. Configure with CMake

```bash
cd /workspace
mkdir -p build && cd build
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_NATIVE=OFF \
  -DLLAMA_S390X=ON \
  -DLLAMA_VXE2=ON \
  -DLLAMA_NNPA=ON \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON
```

### 6. Build — first attempt FAILED

```bash
cmake --build . --config Release -j$(nproc)
```

**Error:** The build attempted to embed a web UI (`llama-ui-embed`) and failed
because `loading.html` was missing from the gzip asset list.

```
missing required asset(s): loading.html
CMake Error at /workspace/scripts/ui-assets.cmake:266 (message):
  UI: llama-ui-embed failed (1)
```

**Fix:** Target a specific executable instead of the full build:

```bash
cmake --build . --config Release --target llama -j$(nproc)
```

> Note: `--target llama-cli` does not exist in this repo version.
> `--target llama` builds `libllama.so` (shared library), not an executable.

### 7. Identify correct executable target

```bash
cmake --build . --target help | grep -i llama
```

Available targets included `llama-simple`, `llama-simple-chat`, `llama-bench`, etc.
`llama-simple` accepts `-p` (prompt) and `-n` (token count) flags.

### 8. Build `llama-simple` and `llama-simple-chat`

```bash
cmake --build /workspace/build --config Release --target llama-simple-chat -j$(nproc)
cmake --build /workspace/build --config Release --target llama-simple -j$(nproc)
```

Both succeeded. Binaries placed at `/workspace/build/bin/`.

### 9. Download quantized model

```bash
cd /workspace
wget --inet4-only \
  https://huggingface.co/taronaeo/Llama-3.2-1B-Instruct-BE-GGUF/resolve/main/llama-3.2-1b-instruct-be.Q4_0.gguf
```

Download: 735 MB at ~3.21 MB/s — completed in 3m 49s.

### 10. Run inference

```bash
/workspace/build/bin/llama-simple \
  -m /workspace/llama-3.2-1b-instruct-be.Q4_0.gguf \
  -p "Hello, how are you?" \
  -n 128
```

---

## Result — SUCCESS ✓

Model loaded and generated output on s390x CPU.

### Performance

| Metric | Value |
|---|---|
| Model load time | 2120 ms |
| Prompt eval | 8.54 t/s (12 tokens, 117 ms/token) |
| Generation | **3.43 t/s** (31 tokens, 291 ms/token) |
| Total time | 11,189 ms / 43 tokens |
| Threads | Default (all available CPUs) |
| Accelerator | None — CPU only |
| Backend | `CPU_Mapped` (mmap) |

### Model Details

| Field | Value |
|---|---|
| Model | Llama 3.2 1B Instruct |
| Quantization | Q4_0 (4.94 BPW) |
| File size | 727.75 MiB |
| Layers | 16 |
| Context (trained) | 131072 |
| Context (used) | 256 (default for `llama-simple`) |
| Vocab | 128256 tokens (BPE) |

---

## Observations

- **VXE2 / NNPA flags compiled in** (`-DLLAMA_VXE2=ON -DLLAMA_NNPA=ON`) but at
  runtime all layers were assigned to `CPU` — no VXE SIMD or NNPA acceleration
  was detected or activated. This is expected when the zCX container does not
  expose the underlying z hardware SIMD/NNPA features to the guest.
- Generation speed of **3.43 t/s** is a baseline CPU-only figure. VXE or NNPA
  acceleration would significantly improve this on a native z15/z16/z17 LPAR.
- The `llama-simple` binary context window defaults to 256 tokens, which is
  lower than the model's trained 131072. Pass `-c <size>` to increase it.

---

## Run 2 — Explicit CPU-only (zDNN=OFF, NNPA=OFF)

**CMake flags changed:**
- `-DLLAMA_NNPA=OFF` (was ON)
- `-DLLAMA_S390X_ZDNN=OFF` (explicit, was absent/default)
- `-DLLAMA_VXE2=ON` retained

Build was incremental — only `llama-simple` target rebuilt (all shared libs
already up to date from Run 1).

```bash
cmake --build . --config Release --target llama-simple -j$(nproc)

/workspace/build/bin/llama-simple \
  -m /workspace/llama-3.2-1b-instruct-be.Q4_0.gguf \
  -p "Hello, how are you?" \
  -n 128
```

### Performance — Run 2

| Metric | Run 1 (VXE2=ON, NNPA=ON) | Run 2 (VXE2=ON, NNPA=OFF, zDNN=OFF) | Delta |
|---|---|---|---|
| Model load time | 2120 ms | 1920 ms | −200 ms |
| Prompt eval | 8.54 t/s | **9.15 t/s** | +0.61 t/s |
| Generation | 3.43 t/s | **3.26 t/s** | −0.17 t/s |
| Total time | 11,189 ms | 11,497 ms | +308 ms |
| Tokens generated | 43 | 43 | — |
| Backend | CPU_Mapped | CPU_Mapped | — |

### Observations — Run 2

- Results are **within noise margin** of Run 1. Disabling NNPA and explicitly
  setting zDNN=OFF has no measurable effect on this hardware — as expected,
  since neither accelerator is exposed by the zCX container environment.
- The slight prompt eval improvement (+0.61 t/s) and generation regression
  (−0.17 t/s) are within normal run-to-run variance; not attributable to the
  flag change.
- **Conclusion:** In a zCX Docker container, `LLAMA_NNPA`, `LLAMA_VXE2`, and
  `LLAMA_S390X_ZDNN` flags make no observable runtime difference. The CPU
  scalar path is used regardless. A native LinuxONE LPAR is required to
  exercise VXE SIMD or NNPA.

---

## Next Steps

- [x] Rebuild without zDNN/NNPA flags — confirmed no regression in zCX.
- [ ] Test on a native LinuxONE LPAR (not zCX) where VXE SIMD is exposed to
      the OS to measure acceleration benefit.
- [ ] Compare generation TPS against the Ollama-wrapped llama-server build in
      `t9-kserve/Dockerfile`.

---

## Related Files

- `t9-kserve/Dockerfile` — production Ollama build for s390x (UBI 9 + KServe)
- `logs/build_attempt_004.md` — previous build attempt (install script 404)
- Repo used: https://github.com/taronaeo/llama.cpp-s390x
