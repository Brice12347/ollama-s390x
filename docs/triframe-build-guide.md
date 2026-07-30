# Building Ollama zDNN Image on Triframe

## Overview

Triframe is an s390x build environment where you can build the zDNN-accelerated Ollama image. This guide walks you through the process.

---

## Prerequisites

- SSH access to Triframe host
- `podman` installed on Triframe
- Logged in to quay.io: `podman login quay.io`
- Git clone of ollama-s390x repo on Triframe

---

## Step 1: Connect to Triframe

```bash
# From your Mac
ssh root@<triframe-ip-or-hostname>

# Or if you have a dev container running:
oc rsh -n <namespace> <pod-name> bash
```

Once connected, verify you're on s390x:

```bash
uname -m
# Should output: s390x

podman --version
# Should output: podman version X.X.X
```

---

## Step 2: Navigate to Repo

```bash
# Clone or navigate to existing clone
cd /workspace/ollama-s390x

# Or if in a container:
cd /path/to/ollama-s390x

# Verify files exist
ls -la Containerfile.zdnn CMakePresets.json
```

---

## Step 3: Login to quay.io

```bash
podman login quay.io

# When prompted:
# - Username: your quay.io username (e.g., justinveltri)
# - Password: your quay.io API token or password
```

---

## Step 4: Build the Image

### Quick Build (30-60 minutes)

```bash
podman build \
  --platform linux/s390x \
  --format docker \
  -f Containerfile.zdnn \
  -t quay.io/justinveltri/ollama-s390x:latest-zdnn \
  .
```

### Or Use the Build Script

```bash
chmod +x build-and-push-zdnn.sh
./build-and-push-zdnn.sh justinveltri latest-zdnn
```

---

## Step 5: Monitor Build Progress

The build has 4 stages:

| Stage | Name | Duration | What It Does |
|-------|------|----------|--------------|
| 1 | base-s390x | ~5 min | Install toolchain (gcc, cmake, ninja, OpenBLAS) |
| 2 | llama-server | ~40 min | Build llama-server with zDNN using cmake preset `cpu_s390x_zdnn` |
| 3 | Go build | ~10 min | Compile ollama Go binary |
| 4 | Final image | ~5 min | Package runtime image |

**Watch for these success markers:**

```
[1/4] STEP 1/4: FROM --platform=linux/s390x ubuntu:24.04 AS base-s390x
...
[1/4] STEP 2/4: RUN apt-get update ... (wait ~5 min)
...
[2/4] STEP 1/1: FROM base-s390x AS llama-server-cpu_s390x_zdnn
...
[2/4] STEP 2/2: RUN --mount=type=cache ... cmake ... (wait ~40 min)
...
[3/4] STEP 1/1: FROM base-s390x AS build
...
[3/4] STEP 2/2: RUN --mount=type=cache ... go build ... (wait ~10 min)
...
[4/4] STEP 1/4: FROM --platform=linux/s390x ubuntu:24.04
...
[4/4] STEP 4/4: ENTRYPOINT ["/usr/bin/ollama"]
```

**At the end, you should see:**
```
Successfully tagged quay.io/justinveltri/ollama-s390x:latest-zdnn
```

---

## Step 6: Verify Build

```bash
# List local images
podman images | grep ollama-s390x

# Test the image (optional, ~10 seconds)
podman run --rm \
  -e OLLAMA_HOST=127.0.0.1:11434 \
  quay.io/justinveltri/ollama-s390x:latest-zdnn \
  /usr/bin/ollama --version
```

---

## Step 7: Push to quay.io

```bash
podman push quay.io/justinveltri/ollama-s390x:latest-zdnn
```

**Expected output:**
```
Getting image source signatures
Copying blob sha256:abc123...
...
Writing manifest to image destination
```

**Verify it's pushed:**
```bash
podman search quay.io/justinveltri/ollama-s390x
```

---

## Step 8: Update OpenShift Deployment (Back on Your Mac)

Once the image is pushed to quay.io, update the deployment:

```bash
# From your Mac terminal
oc set image deployment/ollama-zdnn \
  ollama=quay.io/justinveltri/ollama-s390x:latest-zdnn \
  -n project-ollama

# Watch the rollout
oc rollout status deployment/ollama-zdnn -n project-ollama

# View logs once pod is running
oc logs -f deployment/ollama-zdnn -n project-ollama
```

---

## Troubleshooting

### Build segfaults during apt-get

**Cause**: Race condition in Ubuntu 24.04 s390x package mirror

**Fix**: Retry the build:
```bash
podman build --platform linux/s390x -f Containerfile.zdnn -t quay.io/justinveltri/ollama-s390x:latest-zdnn . --no-cache
```

### cmake compilation fails

**Cause**: Missing zDNN headers or incompatible libzdnn version

**Fix**: Install zDNN development package:
```bash
# On Ubuntu 24.04
apt-get install libzdnn-dev

# On RHEL 9
dnf install libzdnn-devel
```

### podman push times out

**Cause**: Network timeout to quay.io

**Fix**: Retry with timeout:
```bash
podman push --retry 5 quay.io/justinveltri/ollama-s390x:latest-zdnn
```

### Pod still can't pull image after push

**Cause**: Image isn't actually in quay.io registry yet

**Fix**: Verify:
```bash
# On Triframe:
podman search quay.io/justinveltri/ollama-s390x

# Check quay.io web UI:
# https://quay.io/repository/justinveltri/ollama-s390x
```

---

## Summary

```bash
# Total commands:
ssh root@<triframe>
cd /workspace/ollama-s390x
podman login quay.io
podman build --platform linux/s390x -f Containerfile.zdnn -t quay.io/justinveltri/ollama-s390x:latest-zdnn .
podman push quay.io/justinveltri/ollama-s390x:latest-zdnn
exit

# Then from Mac:
oc set image deployment/ollama-zdnn ollama=quay.io/justinveltri/ollama-s390x:latest-zdnn -n project-ollama
oc logs -f deployment/ollama-zdnn -n project-ollama
```

**Total time**: ~1-1.5 hours (mostly waiting for build)

---

## Next Steps

1. ✅ Build completes on Triframe
2. ✅ Image pushed to quay.io
3. ✅ Deployment updated in OpenShift
4. ✅ Pod starts and pulls model
5. ✅ Test inference with `curl` or `oc rsh`
