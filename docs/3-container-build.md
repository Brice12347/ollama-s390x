# Step 3 — Build and Push a Container Image (s390x)

Build a Podman/Docker image for IBM Z (s390x) and push it to a container registry.
Two Dockerfiles are provided:

| File | Purpose |
|---|---|
| [`Containerfile`](../Containerfile) | General-purpose image (CPU inference, multi-arch build) |
| [`Dockerfile.kserve`](../Dockerfile.kserve) | UBI 9 image for OpenShift AI / KServe (non-root, production-ready) |

---

## Prerequisites

- Podman 4.0+ (or Docker)
- Access to an s390x host **or** QEMU user-space emulation (`qemu-user-static`) for cross-builds
- A [quay.io](https://quay.io) account (or any OCI-compatible registry)

---

## Build — general image (`Containerfile`)

Replace `<your-org>` with your quay.io username or organisation.

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  -f Containerfile \
  -t quay.io/<your-org>/ollama-s390x:latest \
  .
```

### Optional build arguments

| Argument | Default | Purpose |
|---|---|---|
| `CMAKEVERSION` | `3.31.2` | CMake version used in build stages |
| `NINJAVERSION` | `1.12.1` | Ninja version used in build stages |

Override example:

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  --build-arg CMAKEVERSION=3.31.2 \
  -f Containerfile \
  -t quay.io/<your-org>/ollama-s390x:latest \
  .
```

---

## Build — KServe image (`Dockerfile.kserve`)

This is the production image used with OpenShift AI. It is a **4-stage build**:

| Stage | Base | What it does |
|---|---|---|
| `base-s390x` | `ubi9/ubi:latest` | Installs GCC, OpenBLAS, CMake, Ninja from the Red Hat registry |
| `llama-server-cpu_s390x` | base-s390x | Compiles `llama-server` with the `cpu_s390x` CMake preset (OpenBLAS, no GPU) |
| `build` | base-s390x | Downloads Go for `linux/s390x`, compiles the Ollama binary (`CGO_ENABLED=1 -buildmode=pie`) |
| `runtime` | `ubi9/ubi-minimal:latest` | Minimal image — only `openblas`. Copies in the Go binary and llama-server libraries. Runs as non-root uid 10001. |

The image bakes in three environment variable defaults that are overridden at runtime:

| Variable | Baked-in default | Runtime override |
|---|---|---|
| `OLLAMA_HOST` | `127.0.0.1:11434` | `0.0.0.0:11434` (so KServe proxy can reach it) |
| `OLLAMA_MODELS` | `/home/ollama/.ollama/models` | PVC mount path |
| `OLLAMA_LOAD_TIMEOUT` | `30m` | Keep at `30m` — GGUF byte-swap on cold start takes 5–6 min for a 135M model |

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  -f Dockerfile.kserve \
  -t quay.io/<your-org>/ollama-s390x:kserve \
  .
```

---

## Push the image

```sh
podman login quay.io
podman push quay.io/<your-org>/ollama-s390x:kserve
```

Make the repository **public** in the quay.io UI so OpenShift can pull it without credentials.

---

## Smoke test locally

```sh
podman run --rm -p 11434:11434 \
  -e OLLAMA_HOST=0.0.0.0:11434 \
  quay.io/<your-org>/ollama-s390x:kserve

# In another terminal
curl http://localhost:11434/
# Expected: Ollama is running
```

---

## Next steps

| Goal | Guide |
|---|---|
| Deploy this image on OpenShift AI | [docs/4-openshift-deploy.md](4-openshift-deploy.md) |
| Add OpenWebUI | [docs/5-open-webui.md](5-open-webui.md) |
