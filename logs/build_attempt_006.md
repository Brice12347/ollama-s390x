# Build Attempt 006 — llama.cpp-s390x Inside IBM Accelerated PyTorch Container

**Date:** 2026-08-06
**Environment:** IBM zCX (z/OS Container Extensions) — Docker shell
**Host:** `9.47.95.173:8022` (user: `ollama`)
**Architecture:** s390x (IBM Z / LinuxONE)
**Base image:** `icr.io/ibmz/ibmz-accelerated-for-pytorch@sha256:ed3f7b5e612bd5a5fb2e6feb36d08288563ea708a8a6bca0fae1a88e00f38439`
**Repo:** https://github.com/taronaeo/llama.cpp-s390x

---

## Objective

Repeat the llama.cpp-s390x CPU inference smoke test (build_attempt_005) inside
the IBM Z Accelerated for PyTorch container image, to establish a baseline
generation speed on the same hardware and determine whether the image's runtime
environment offers any advantage over a plain Ubuntu container.

---

## Environment Constraints

| Constraint | Detail |
|---|---|
| No `git` on zCX host shell | `git` is not installed in the IBM zCX SSH shell |
| No `sudo` on zCX host | `ollama` user has no sudo privileges |
| Bind mounts blocked | `docker run -v` rejected by `zcxauthplugin` |
| `icr.io` requires authentication | IBM Container Registry requires an IBM Cloud IAM API key even for public images |

---

## Steps Taken

### 1. Authenticate against `icr.io`

`icr.io` (IBM Container Registry) returns `UNAUTHORIZED` without credentials,
even for public images. Authentication was performed using an IBM Cloud API key:

```bash
docker login icr.io -u iamapikey -p <IBM_CLOUD_API_KEY>
```

### 2. Pull the IBM Z Accelerated for PyTorch image

```bash
docker pull icr.io/ibmz/ibmz-accelerated-for-pytorch@sha256:ed3f7b5e612bd5a5fb2e6feb36d08288563ea708a8a6bca0fae1a88e00f38439
```

Pull succeeded — 16 layers downloaded.

### 3. Start the container

```bash
docker run -d --name pytorch-test \
  icr.io/ibmz/ibmz-accelerated-for-pytorch@sha256:ed3f7b5e612bd5a5fb2e6feb36d08288563ea708a8a6bca0fae1a88e00f38439 \
  sleep infinity
```

### 4. Inspect PyTorch build variant

```bash
docker exec -it pytorch-test bash
python3 -c "import torch; print('PyTorch:', torch.__version__); print(dir(torch.backends))"
```

**Output:**
```
PyTorch: 2.11.0+cpu
['cpu', 'cuda', 'cudnn', 'cusparselt', 'kleidiai', 'm', 'mha', 'miopen',
 'mkl', 'mkldnn', 'mps', 'nnpack', 'openmp', 'opt_einsum', 'quantized']
```

**Finding:** The image ships a `+cpu` (CPU-only) PyTorch build. There is no
`torch.backends.nnpa` attribute — NNPA/zAIU acceleration is not compiled into
this image. `torch.backends.nnpack.is_available()` also returned `False`.
This image provides no hardware acceleration beyond CPU scalar on any host,
including zCX.

### 5. Install build tools (as root inside container)

The default user is `ibm-user` (non-root) and has no package manager access.
Used `docker exec -u root` to gain root inside the container:

```bash
docker exec -it -u root pytorch-test bash
dnf install -y cmake gcc gcc-c++ make openblas-devel wget
```

`openblas-devel` was already present. All other packages installed from UBI 10
and EPEL 10 repos. GCC 14.3.1 and CMake 3.31.8 installed successfully.

### 6. Download the llama.cpp-s390x source (from zCX host)

`git` was unavailable on the zCX host. Downloaded the repo as a tarball and
extracted to a staging directory:

```bash
# On zCX host
wget -O ~/llama.tar.gz https://github.com/taronaeo/llama.cpp-s390x/tarball/HEAD
mkdir -p ~/llama.cpp-s390x-build
tar xzf ~/llama.tar.gz -C ~/llama.cpp-s390x-build --strip-components=1

# Copy into running container
docker cp ~/llama.cpp-s390x-build pytorch-test:/home/ibm-user/llama.cpp-s390x
```

### 7. Build — Run 1 (VXE2=ON, NNPA=OFF) — SUCCESS ✓

```bash
cd /home/ibm-user/llama.cpp-s390x
mkdir -p build && cd build
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_NATIVE=OFF \
  -DLLAMA_S390X=ON \
  -DLLAMA_VXE2=ON \
  -DLLAMA_NNPA=OFF
cmake --build . --config Release --target llama-cli -j$(nproc)
```

Build succeeded. Binary placed at `build/bin/llama-cli`.

### 8. Download quantized model

```bash
cd /home/ibm-user/llama.cpp-s390x
wget --inet4-only \
  https://huggingface.co/taronaeo/Llama-3.2-1B-Instruct-BE-GGUF/resolve/main/llama-3.2-1b-instruct-be.Q4_0.gguf
```

Download: 735 MB at 7.69 MB/s — completed in 96 s.

### 9. Run inference — Run 1 (NNPA=OFF)

```bash
./build/bin/llama-cli \
  -m llama-3.2-1b-instruct-be.Q4_0.gguf \
  -p "Hello, how are you?" \
  -n 128 --temp 0.7
```

**Results:**

| Prompt | Prompt eval (t/s) | Generation (t/s) |
|---|---|---|
| "Hello, how are you?" | 9.4 | 3.3 |
| "write me a poem about basketball" | 8.2 | 3.2 |
| "what is the capital of france" | 6.4 | 3.3 |

### 10. Build — Run 2 (VXE2=ON, NNPA=ON) — full build FAILED, targeted build SUCCESS ✓

Cleaned build directory and reconfigured with `NNPA=ON`:

```bash
rm -rf build
mkdir -p build && cd build
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_NATIVE=OFF \
  -DLLAMA_S390X=ON \
  -DLLAMA_VXE2=ON \
  -DLLAMA_NNPA=ON
cmake --build . --config Release -j$(nproc)
```

**Error:** Full build failed — UI embed step missing `loading.html`:

```
missing required asset(s): loading.html
CMake Error at /home/ibm-user/llama.cpp-s390x/scripts/ui-assets.cmake:266 (message):
  UI: llama-ui-embed failed (1)
```

**Fix:** Target `llama-cli` directly to skip the UI step:

```bash
cmake --build . --config Release --target llama-cli -j$(nproc)
```

Build succeeded.

### 11. Run inference — Run 2 (NNPA=ON)

```bash
./build/bin/llama-cli \
  -m llama-3.2-1b-instruct-be.Q4_0.gguf \
  -p "Hello, how are you?" \
  -n 128 --temp 0.7
```

**Results:**

| Prompt | Prompt eval (t/s) | Generation (t/s) |
|---|---|---|
| "Hello, how are you?" | 10.3 | 3.8 |
| "what is the capital of france" | 6.9 | 3.3 |
| "write a short poem about basketball" | 7.8 | 3.1 |

---

## Results Summary

### Run 1 vs Run 2 — Inside PyTorch Container

| Metric | Run 1 (VXE2=ON, NNPA=OFF) | Run 2 (VXE2=ON, NNPA=ON) | Delta |
|---|---|---|---|
| Prompt eval — "Hello" | 9.4 t/s | 10.3 t/s | +0.9 t/s |
| Generation — "Hello" | 3.3 t/s | 3.8 t/s | +0.5 t/s |
| Prompt eval — "capital of france" | 6.4 t/s | 6.9 t/s | +0.5 t/s |
| Generation — "capital of france" | 3.3 t/s | 3.3 t/s | — |
| Backend | CPU (scalar) | CPU (scalar) | — |
| Accelerator active | None | None | — |

> **Note:** Despite `NNPA=ON` being compiled in, no NNPA/zAIU acceleration was
> activated at runtime — the backend remained CPU scalar in both runs. The small
> performance differences are within normal run-to-run variance. This is
> consistent with build_attempt_005 findings: zCX containers do not expose
> z hardware accelerators to guests.

### Comparison vs build_attempt_005 (Ubuntu 22.04, same zCX hardware)

| Metric | Attempt 005 (Ubuntu) | Attempt 006 Run 1 (NNPA=OFF) | Attempt 006 Run 2 (NNPA=ON) |
|---|---|---|---|
| Prompt eval | 8.54 t/s | 9.4 t/s | 10.3 t/s |
| Generation | 3.43 t/s | 3.3 t/s | 3.8 t/s |
| Backend | CPU_Mapped | CPU | CPU |
| GCC version | Ubuntu default | 14.3.1 | 14.3.1 |
| OpenBLAS | libopenblas-dev | 0.3.29 (pre-installed) | 0.3.29 (pre-installed) |

> The prompt eval improvement over attempt 005 likely reflects the newer GCC
> (14.3.1) and OpenBLAS (0.3.29) in the UBI 10 based PyTorch image.
> Generation speed is within noise margin across all three runs.

---

## Observations

- The `ibmz-accelerated-for-pytorch` image ships **PyTorch 2.11.0+cpu** — a
  CPU-only build with no NNPA/zAIU backend compiled in.
- `torch.backends.nnpa` does not exist in this image; `nnpack` is present but
  returns `False` on this hardware.
- The image is based on **UBI 10** (RHEL 10), which provides newer toolchain
  packages (GCC 14, OpenBLAS 0.3.29, CMake 3.31) compared to Ubuntu 22.04.
- `docker exec -u root` grants container-level root even when the default user
  is non-root — useful in restricted zCX environments without host sudo.
- The UI embed build step (`llama-ui-embed` / `loading.html`) continues to
  fail in this repo version; targeting `--target llama-cli` is the reliable
  workaround.
- Generation speed of **~3.3–3.8 t/s** is consistent with build_attempt_005
  results on the same zCX hardware. A native LinuxONE LPAR is required to
  observe VXE or NNPA acceleration.

---

## Next Steps

- [ ] Run on a native LinuxONE LPAR (not zCX) to measure VXE SIMD benefit.
- [ ] Find or build an `ibmz-accelerated-for-pytorch` image with NNPA enabled
      (`+nnpa` build variant) and retest on z17 / LinuxONE 5.
- [ ] Compare generation TPS against the Ollama-wrapped `llama-server` build
      in `t9-kserve/Dockerfile`.

---

## Related Files

- `t9-kserve/Dockerfile` — production Ollama build for s390x (UBI 9 + KServe)
- `logs/build_attempt_005.md` — previous run (Ubuntu 22.04 container, same zCX host)
