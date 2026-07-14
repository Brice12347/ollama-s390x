# Running Ollama on s390x with Podman

This guide covers building the Ollama container image for IBM Z / LinuxONE
(`s390x`), pushing it to [quay.io](https://quay.io), and running a smoke test
to confirm the image is working.

> **Prerequisites**
> - Podman 4.0 or later
> - Access to an s390x host or a cross-build environment with QEMU user-space
>   emulation (`qemu-user-static`) installed
> - A [quay.io](https://quay.io) account and a repository created under your
>   organisation

---

## 1. Build the image

Replace `brice_patchou` with your quay.io organisation or username (e.g.
`mycompany` → `quay.io/mycompany/ollama-s390x`).

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  -f Containerfile \
  -t quay.io/brice_patchou/ollama-s390x:latest \
  .
```

### Build arguments

| Argument | Default | Purpose |
|---|---|---|
| `CMAKEVERSION` | `3.31.2` | CMake version installed in the build stages |
| `NINJAVERSION` | `1.12.1` | Ninja build system version |

Override with `--build-arg`, for example:

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  -f Containerfile \
  --build-arg CMAKEVERSION=3.31.2 \
  -t quay.io/brice_patchou/ollama-s390x:latest \
  .
```

### CMake preset used

The native C++ inference backend is compiled with the **`cpu_s390x`** preset
(defined in [`llama/server/CMakePresets.json`](../llama/server/CMakePresets.json)).
This enables:

| CMake flag | Value | Effect |
|---|---|---|
| `OLLAMA_S390X_BIGENDIAN` | `ON` | Big-endian GGUF byte-swap (required on z/Architecture) |
| `GGML_VXE` | `ON` | IBM z Vector Extensions — VXE/VXE2 SIMD (z15+) |
| `GGML_BLAS` / `GGML_BLAS_VENDOR` | `ON` / `OpenBLAS` | BLAS matrix-multiply acceleration |
| `GGML_CPU_ALL_VARIANTS` | `ON` | Ships all CPU dispatch variants |

---

## 2. Push to quay.io

```sh
# Log in (interactive prompt for username and password / token)
podman login quay.io

# Push
podman push quay.io/brice_patchou/ollama-s390x:latest
```

To push a versioned tag alongside `latest`:

```sh
podman tag quay.io/brice_patchou/ollama-s390x:latest \
           quay.io/brice_patchou/ollama-s390x:0.1.0

podman push quay.io/brice_patchou/ollama-s390x:0.1.0
```

---

## 3. Run the container

```sh
podman run -d \
  --name ollama \
  -p 127.0.0.1:11434:11434 \
  -v ollama-data:/home/ollama/.ollama \
  quay.io/brice_patchou/ollama-s390x:latest
```

| Flag | Purpose |
|---|---|
| `-p 127.0.0.1:11434:11434` | Binds the API port to localhost only — do not use `0.0.0.0` |
| `-v ollama-data:/home/ollama/.ollama` | Persists downloaded models across container restarts |

### Environment variable overrides

| Variable | Default | Notes |
|---|---|---|
| `OLLAMA_HOST` | `127.0.0.1:11434` | Change to `0.0.0.0:11434` only inside a trusted private network |
| `OLLAMA_MODELS` | `/home/ollama/.ollama/models` | Override to mount a pre-populated model volume |

---

## 4. Check container health

The image ships with a built-in `HEALTHCHECK` that polls the Ollama REST API
every 30 seconds:

```sh
podman inspect --format '{{.State.Health.Status}}' ollama
# healthy
```

---

## 5. Smoke test

Run a small model to confirm end-to-end inference is working.
[`smollm:135m`](https://ollama.com/library/smollm) (~270 MB) is a good
minimal choice for s390x CI environments.

```sh
# Pull the model
podman exec ollama ollama pull smollm:135m

# Run a quick inference
podman exec ollama ollama run smollm:135m "What is 2 + 2?"
```

Expected: the model prints a response containing `4` (or similar) and exits
with code `0`.

### Non-interactive one-liner (useful in CI)

```sh
podman exec ollama sh -c \
  'ollama run smollm:135m "What is 2+2?" --nowordwrap' \
  | grep -q '4' && echo "SMOKE TEST PASSED" || { echo "SMOKE TEST FAILED"; exit 1; }
```

---

## 6. Full CI example (shell script)

```sh
#!/bin/sh
set -e

IMAGE="quay.io/brice_patchou/ollama-s390x:latest"

# 1. Build
podman build --platform linux/s390x --format oci -f Containerfile -t "$IMAGE" .

# 2. Start
podman run -d --name ci-ollama -p 127.0.0.1:11434:11434 "$IMAGE"

# 3. Wait for healthy
for i in $(seq 1 10); do
  STATUS=$(podman inspect --format '{{.State.Health.Status}}' ci-ollama 2>/dev/null || echo "starting")
  [ "$STATUS" = "healthy" ] && break
  echo "Waiting for healthy... ($i/10)"
  sleep 5
done

# 4. Smoke test
podman exec ci-ollama ollama pull smollm:135m
podman exec ci-ollama sh -c \
  'ollama run smollm:135m "What is 2+2?" --nowordwrap' \
  | grep -q '4' && echo "SMOKE TEST PASSED"

# 5. Cleanup
podman stop ci-ollama
podman rm ci-ollama
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `exec format error` | Image built for wrong arch | Ensure `--platform linux/s390x` was used at build time |
| `GGUF model load failed` / byte-swap errors | Little-endian GGUF file | Use a Big-Endian GGUF (filename contains `-BE`) or re-quantize on s390x |
| Container stays `starting` in healthcheck | Slow model server init | Increase `--start-period` in `HEALTHCHECK` or wait longer before polling |
| `libopenblas.so.0 not found` | Missing runtime lib | Ensure the final stage `apt-get install libopenblas0` ran successfully |
