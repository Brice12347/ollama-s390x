# quay.io Container Experiment — Ollama s390x
**Date:** 2026-07-02  
**Tester:** Brice Patchou  
**Host:** `b39-triframe1` (IBM Z / s390x)  
**Goal:** Build a production-ready `Containerfile` for `ollama-s390x`, push it to quay.io, and run a smoke test.

---

## Environment

- **Machine:** IBM Z (`s390x`) accessed via SSH
- **Runtime container:** `e0ee8c207e86` (`spyre-runtime-dev`)
- **Repo:** `~/workspace/ollama-s390x`
- **Registry:** `quay.io/brice_patchou/ollama-s390x`
- **Image format:** Docker (OCI dropped — does not support `HEALTHCHECK`)

---

## Containerfile Summary

4-stage multi-stage build, all pinned to `--platform linux/s390x`:

| Stage | Name | Base | Purpose |
|---|---|---|---|
| 1 | `base-s390x` | `ubuntu:24.04` | GCC 13, CMake 3.28, Ninja, OpenBLAS, pkg-config toolchain |
| 2 | `llama-server-cpu_s390x` | `base-s390x` | Builds C++ inference backend with `cpu_s390x` CMake preset |
| 3 | `build` | `base-s390x` | Compiles the Go `ollama` binary (CGO enabled) |
| 4 | Final | `ubuntu:24.04` | Minimal runtime — non-root user, healthcheck, no GPU libs |

### CMake preset flags (`cpu_s390x`)

| Flag | Value | Effect |
|---|---|---|
| `OLLAMA_S390X_BIGENDIAN` | `ON` | Big-endian GGUF byte-swap |
| `GGML_VXE` | `ON` | IBM z Vector Extensions (z15+ VXE/VXE2) |
| `GGML_BLAS` / `GGML_BLAS_VENDOR` | `ON` / `OpenBLAS` | BLAS matrix acceleration |
| `GGML_CPU_ALL_VARIANTS` | `ON` | All CPU dispatch variants |

### Security properties

- Non-root user: `ollama` (uid 10001)
- `OLLAMA_HOST=127.0.0.1:11434` (localhost-only binding)
- `HEALTHCHECK` embedded in image metadata

---

## Issues Encountered & Fixes Applied

### 1. CMake 404 on `curl` download

**Cause:** The original `Containerfile` tried to download a pre-built CMake binary from
`github.com/Kitware/CMake/releases` using `$(uname -m)` which returns `s390x`. Kitware
does not publish pre-built binaries for `s390x`.

**Fix:** Replaced the `curl` download with `apt-get install cmake ninja-build` — Ubuntu
24.04 ships CMake 3.28 and Ninja 1.11, both satisfying the ≥3.24 requirement.

```dockerfile
# Before (broken on s390x)
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz \
    | tar xz -C /usr/local --strip-components 1

# After
RUN apt-get install -y cmake ninja-build
```

---

### 2. `Could NOT find PkgConfig` — CMake BLAS configure error

**Cause:** The `ggml-blas` CMake module calls `find_package(PkgConfig)` to locate
`openblas.pc`. `pkg-config` was not installed in the build image.

**Fix:** Added `pkg-config` to the `apt-get install` list in `base-s390x`.

```dockerfile
apt-get install -y ... pkg-config libopenblas-dev
```

---

### 3. `HEALTHCHECK` warning with `--format oci`

**Cause:** The OCI image spec does not define a `HEALTHCHECK` field. Podman emits a
warning and silently drops the directive when building with `--format oci`.

```
WARN[0288] HEALTHCHECK is not supported for OCI image format and will be ignored. Must use `docker` format
```

**Fix:** Switched build flag from `--format oci` to `--format docker`, which stores the
`HEALTHCHECK` in image metadata correctly.

---

### 4. Stale Podman layer cache

**Cause:** After fixing the `Containerfile`, `podman build` continued using cached
layers from the broken build, re-running the old curl step.

**Fix:** Used `--no-cache` to force a clean rebuild:

```sh
podman build --no-cache --platform linux/s390x --format docker ...
```

---

### 5. Port 11434 already in use

**Cause:** A `podman compose` stack (`ollama-dev` + `jupyter`) was running and had
already bound port 11434. Could not `sudo fuser -k` without root access.

**Fix:** Mapped a different host port (`11435`) to the container's internal port `11434`:

```sh
podman run -d \
  --name ollama \
  -p 127.0.0.1:11435:11434 \
  -v ollama-data:/home/ollama/.ollama \
  quay.io/brice_patchou/ollama-s390x:latest
```

---

## Build Output (final successful run)

```
[1/4] STEP 1/7: FROM --platform=linux/s390x ubuntu:24.04 AS base-s390x
[2/4] STEP 5/5: RUN cmake -S llama/server --preset cpu_s390x ...
  OLLAMA_S390X_BIGENDIAN = ON
  GGML_VXE               = ON
  GGML_BLAS              = ON / OpenBLAS
  GGML_CPU_ALL_VARIANTS  = ON
  -- VXE2 enabled
  -- z15 cross-compile target
  -- z16 cross-compile target
  -- NNPA enabled
  -- BLAS found: /usr/lib/s390x-linux-gnu/libopenblas.so
[3/4] Go build complete → /bin/ollama
[4/4] COMMIT quay.io/brice_patchou/ollama-s390x:latest
Successfully tagged quay.io/brice_patchou/ollama-s390x:latest
```

---

## Push to quay.io

```sh
podman login quay.io        # Username: brice_patchou
podman push quay.io/brice_patchou/ollama-s390x:latest
```

Repository set to **public** via quay.io Settings → Repository Visibility → Make Public.

---

## Smoke Test

### Container start

```sh
podman run -d \
  --name ollama \
  -p 127.0.0.1:11435:11434 \
  -v ollama-data:/home/ollama/.ollama \
  quay.io/brice_patchou/ollama-s390x:latest
51328c3e31423b2f3c4f276693d0dddd2daaab31815084fa00ca107e40dc770a
```

### Container status

```
CONTAINER ID  IMAGE                                     COMMAND  CREATED         STATUS                  PORTS                       NAMES
51328c3e3142  quay.io/brice_patchou/ollama-s390x:latest serve    10 seconds ago  Up 9 seconds (healthy)  127.0.0.1:11435->11434/tcp  ollama
```

> ✅ Status shows `(healthy)` — `HEALTHCHECK` is working.

### API check

```sh
curl -sf http://127.0.0.1:11435/ && echo "OK"
```

### Model pull & inference

```sh
podman exec ollama ollama pull smollm:135m
```

```
pulling manifest
pulling eb2c714d40d4: 100%  91 MB
pulling 62fbfd9ed093: 100%  182 B
pulling cfc7749b96f6: 100%  11 KB
pulling ca7a9654b546: 100%  89 B
pulling f590523c855b: 100%  488 B
verifying sha256 digest
writing manifest
success
```

```sh
podman exec ollama ollama run smollm:135m "What is 2 + 2?"
```

```
The answer to this question depends on the context and the specific
problem you're trying to solve. Here are a few possible approaches:

1. **Binary to Decimal**: Divide the number into two parts (binary) and
then convert it back to decimal using a binary representation like 0b or
1c. This approach is useful when dealing with large numbers, as it can be
computationally efficient for small inputs.
2. **Decimal to Binary**: Convert the binary representation of the number
into a decimal value by multiplying it by 2 and adding 1 (e.g., 1000 * 2 =
1000 + 1). This approach is useful when dealing with large numbers or when
working with very small inputs.
3. **Decimal to Octal**: Convert the binary representation of the number
into an octal value by multiplying it by 8 and adding 1 (e.g., 2^8 = 2 * 4
+ 1). This approach is useful for large numbers or when dealing with very
small inputs.
4. **Binary to Hexadecimal**: Convert the binary representation of the
number into a hexadecimal value by multiplying it by 16 and adding 1
(e.g., 2^16 = 2 * 32 + 1). This approach is useful for large numbers or
when dealing with very small inputs.
5. **Binary to Hexadecimal**: Convert the binary representation of the
number into a hexadecimal value by multiplying it by 8 and adding 1 (e.g.,
2^8 = 2 * 32 + 1). This approach is useful for large numbers or when
dealing with very small inputs, as it can be computationally efficient for
small inputs.
6. **Binary to Octal**: Convert the binary representation of the number
into an octal value by multiplying it by 8 and adding 1 (e.g., 2^8 = 2 *
32 + 1). This approach is useful for large numbers or when dealing with
very small inputs, as it can be computationally efficient for large
inputs.
7. **Binary to Hexadecimal**: Convert the binary representation of
the number into a hexadecimal value by multiplying it by 8 and adding 1
(e.g., 2^8 = 2 * 32 + 1). This approach is useful for large numbers or
when dealing with very small inputs, as it can be computationally
efficient for large inputs.

In general, binary to hexadecimal conversion involves dividing the number
into two parts (binary) and then multiplying it by 8 and adding 1 (e.g.,
2^8 = 2 * 32 + 1). This approach is useful when dealing with very small
inputs or when working with large numbers, as it can be computationally
efficient for small inputs.
```

> ✅ Model pulled and inference completed successfully on s390x.

---

## Result

| Criterion | Status |
|---|---|
| Multi-stage build completes on s390x | ✅ |
| Non-root user (ollama, uid 10001) | ✅ |
| Healthcheck included and working | ✅ `(healthy)` confirmed in `podman ps` |
| Podman build + run instructions in docs | ✅ `docs/podman-s390x.md` |
| Image pushed to quay.io | ✅ `quay.io/brice_patchou/ollama-s390x:latest` |
| Smoke test passes | ✅ `smollm:135m` pulled and ran inference |
