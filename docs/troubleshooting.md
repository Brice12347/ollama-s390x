# Troubleshooting Guide — Ollama on IBM Z (s390x)

This guide covers common issues encountered when running the s390x port of Ollama on IBM Z and LinuxONE systems. It addresses problems across the full lifecycle: Podman/container setup, bootstrap scripting, build from source, runtime model-loading, and production performance tuning. Follow the sections most relevant to your situation, or start with the [Quick Diagnostic Checklist](#3-quick-diagnostic-checklist) if you are unsure where to begin.

---

## Table of Contents

1. [Title & Introduction](#troubleshooting-guide--ollama-on-ibm-z-s390x)
2. [Quick Diagnostic Checklist](#3-quick-diagnostic-checklist)
3. [Log Locations & How to Read Them](#4-log-locations--how-to-read-them)
4. [Installation Issues](#5-installation-issues)
   - [5.1 Broken symlink after install](#51-broken-symlink-after-install)
   - [5.2 "Installation successful" shown after a failure](#52-installation-successful-shown-after-a-failure)
   - [5.3 systemd service not starting on s390x](#53-systemd-service-not-starting-on-s390x)
   - [5.4 `llama-server` not found / 500 errors on first `ollama run`](#54-llama-server-not-found--500-errors-on-first-ollama-run)
   - [5.5 Version pinning](#55-version-pinning)
5. [Podman / Container Issues](#6-podman--container-issues)
   - [6.1 Container startup — bootstrap script](#61-container-startup--bootstrap-script)
   - [6.2 `apt` lock contention in dev container](#62-apt-lock-contention-in-dev-container)
   - [6.3 `git: command not found` inside dev container](#63-git-command-not-found-inside-dev-container)
   - [6.4 Podman Compose not finding `compose.yml`](#64-podman-compose-not-finding-composeyml)
   - [6.5 Container architecture mismatch](#65-container-architecture-mismatch)
   - [6.6 Volume permissions in Podman](#66-volume-permissions-in-podman)
6. [Build Issues](#7-build-issues)
   - [7.1 CMake prerequisites](#71-cmake-prerequisites)
   - [7.2 OpenBLAS not found warning](#72-openblas-not-found-warning)
   - [7.3 zDNN library not found](#73-zdnn-library-not-found)
   - [7.4 CMake PRIVATE_HEADER / PUBLIC_HEADER warnings](#74-cmake-private_header--public_header-warnings)
   - [7.5 UI assets warning](#75-ui-assets-warning)
   - [7.6 Build using Makefile](#76-build-using-makefile)
   - [7.7 Full CMake build from scratch](#77-full-cmake-build-from-scratch)
7. [Runtime / Model-Loading Issues](#8-runtime--model-loading-issues)
   - [8.1 `invalid GGUF version: 50331648`](#81-invalid-gguf-version-50331648)
   - [8.2 Garbage / nonsense output from model](#82-garbage--nonsense-output-from-model)
   - [8.3 Model hangs on first token](#83-model-hangs-on-first-token)
   - [8.4 LLM library override](#84-llm-library-override)
   - [8.5 `/tmp noexec` runtime error](#85-tmp-noexec-runtime-error)
   - [8.6 `llama-server --list-devices` exits 127 (benign)](#86-llama-server---list-devices-exits-127-benign)
8. [Quantization Format Compatibility](#9-quantization-format-compatibility)
9. [Performance / Throughput Issues](#10-performance--throughput-issues)
   - [10.1 Slow first inference](#101-slow-first-inference)
   - [10.2 Variable throughput / tok/s drops](#102-variable-throughput--toks-drops)
   - [10.3 Throughput reference](#103-throughput-reference-tested-on-z15aiu-with-12-vfs)
   - [10.4 Enabling VXE SIMD acceleration](#104-enabling-vxe-simd-acceleration)
   - [10.5 Enabling zDNN (z17+ only)](#105-enabling-zdnn-z17-only)
10. [Known Model Compatibility Issues](#11-known-model-compatibility-issues)
11. [Getting More Help](#12-getting-more-help)

---

## 3. Quick Diagnostic Checklist

When something is wrong, verify these items first in order before diving deeper:

1. **Is the binary on `PATH`?**
   ```sh
   ollama --version
   ```
   If this returns `command not found`, see [Section 5.1](#51-broken-symlink-after-install).

2. **Is the systemd service running?**
   ```sh
   systemctl status ollama
   ```
   If the service is inactive, failed, or missing, see [Section 5.3](#53-systemd-service-not-starting-on-s390x).

3. **Are the logs showing errors?**
   ```sh
   journalctl -u ollama --no-pager -n 100
   ```
   See [Section 4](#4-log-locations--how-to-read-them) for all log locations and key patterns to search for.

4. **Is the model quantization supported?**
   Some quantization formats are unstable or unsupported on s390x. See [Section 9](#9-quantization-format-compatibility) for the full compatibility table. In particular, avoid `Q2_K` in production and `IQ4_XS` entirely.

5. **Is the GGUF version compatible (GGUFv3+)?**
   This fork requires GGUFv3 or later model files. Older GGUF formats are not byte-swap patched and will fail to load. If you see `invalid GGUF version` in logs, see [Section 8.1](#81-invalid-gguf-version-50331648).

---

## 4. Log Locations & How to Read Them

### Linux (systemd-managed service)

```sh
journalctl -u ollama --no-pager -n 100
```

For a live-follow view:
```sh
journalctl -u ollama -f
```

### Manual run (foreground or background)

```
~/.ollama/logs/server.log
```

### Docker / Podman container

```sh
docker logs <container_name_or_id>
podman logs <container_name_or_id>
```

To follow logs in real time:
```sh
podman logs -f <container_name_or_id>
```

### macOS

```
~/.ollama/logs/server.log
```

### Key log patterns to search for

| Pattern | Meaning |
|---------|---------|
| `invalid GGUF version` | Model file has the wrong byte order or an unsupported version — see [8.1](#81-invalid-gguf-version-50331648) |
| `bswap` | Byte-swap patch is active and processing tensor data — expected on s390x |
| `mmap disabled` | Memory-mapped file I/O was disabled (expected on big-endian) — tensors loaded into RAM |
| `compat patch` | The s390x compatibility patch is running — confirms fork patches are applied |

Use `grep` to filter the log file quickly:
```sh
grep -E "invalid GGUF|bswap|mmap disabled|compat patch" ~/.ollama/logs/server.log
```

---

## 5. Installation Issues

### 5.1 Broken symlink after install

**Symptom:** `ollama: command not found` even after the installer reports success, or the binary is present but cannot start.

**Root Cause:** Earlier versions of the install script created the symlink at `$OLLAMA_INSTALL_DIR/ollama` (pointing to the tarball root) instead of `$OLLAMA_INSTALL_DIR/bin/ollama` (where the actual binary lives after extraction).

**Fix:**
```sh
sudo ln -sf /usr/local/lib/ollama/bin/ollama /usr/local/bin/ollama
```

Verify the symlink is correct:
```sh
ls -la /usr/local/bin/ollama
ollama --version
```

---

### 5.2 "Installation successful" shown after a failure

**Symptom:** The installer prints `Installation successful` and exits 0, but Ollama is not actually installed or is broken.

**Root Cause:** The `EXIT` trap in the install script fires the success message unconditionally on any exit, including error exits that occur mid-installation.

**Fix:** Re-run the install script. This bug is fixed in the latest version of `scripts/install.sh`. After re-running, verify the binary and symlink as described in [5.1](#51-broken-symlink-after-install).

---

### 5.3 systemd service not starting on s390x

**Symptom:** `systemctl start ollama` fails with `Unit ollama.service not found`, or the service file was never created.

**Root Cause:** An early-exit code path in the install script could bypass the section responsible for writing the systemd unit file and running `systemctl daemon-reload`.

**Fix:** Manually create the service unit file:

```sh
sudo tee /etc/systemd/system/ollama.service > /dev/null <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=/usr/share/ollama"
Environment="OLLAMA_HOST=0.0.0.0"

[Install]
WantedBy=multi-user.target
EOF
```

Then reload systemd and enable the service:
```sh
sudo systemctl daemon-reload
sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama 2>/dev/null || true
sudo systemctl enable ollama
sudo systemctl start ollama
systemctl status ollama
```

---

### 5.4 `llama-server` not found / 500 errors on first `ollama run`

**Symptom:** Every `ollama run <model>` immediately returns an HTTP 500 error. Logs show something like `llama-server: no such file or directory` or `runner not found`.

**Root Cause:** The release tarball was incomplete — `lib/ollama/llama-server` (the inference runner binary) was missing from the archive.

**Fix:** Reinstall from the latest release. Before extracting, verify the tarball contains the expected binary:
```sh
tar -tzf ollama-linux-s390x.tgz | grep llama-server
```

You should see an entry like:
```
lib/ollama/llama-server
```

If it is absent, download a newer release from the [releases page](https://github.com/Brice12347/ollama-s390x/releases) and reinstall.

---

### 5.5 Version pinning

To install a specific version of Ollama for s390x, set the `OLLAMA_VERSION` environment variable before piping the install script:

```sh
OLLAMA_VERSION=v0.1.0 curl -fsSL \
  https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

Replace `v0.1.0` with the desired tag. Available versions are listed on the [GitHub releases page](https://github.com/Brice12347/ollama-s390x/releases).

---

## 6. Podman / Container Issues

### 6.1 Container startup — bootstrap script

The recommended way to start the development environment is via the bootstrap script, which generates `compose.yml` and other required files:

```sh
bash scripts/bootstrap_dev_env.sh
```

After bootstrapping, start the container:
```sh
podman run -d \
  --name ollama-s390x-dev \
  -p 11434:11434 \
  -v "$PWD":/workspace:Z \
  -v ollama-models:/root/.ollama/models:Z \
  ollama-s390x-dev
```

Confirm the container is healthy:
```sh
# Check container is running
podman ps

# Tail startup logs
podman logs -f ollama-s390x-dev

# Exec into the container for interactive work
podman exec -it ollama-s390x-dev bash
```

---

### 6.2 `apt` lock contention in dev container

**Symptom:**
```
E: Could not get lock /var/lib/dpkg/lock-frontend - open (11: Resource temporarily unavailable)
E: Unable to acquire the dpkg frontend lock
```

**Root Cause:** The container entrypoint runs `apt-get install` at container start time. If another process (or a previous interrupted install) holds the dpkg lock, the installation fails.

**Fix (preferred):** Use the updated `Dockerfile.dev` which pre-installs all dependencies at image build time so `apt` is never run at container runtime.

**Fix (manual recovery):**
```sh
podman exec -it ollama-s390x-dev bash -c \
  "sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock && \
   sudo dpkg --configure -a && \
   sudo apt-get install -f"
```

---

### 6.3 `git: command not found` inside dev container

**Symptom:** Running `git` inside the container fails with `command not found`, even though the container started successfully.

**Root Cause:** The `podman exec` was run before `apt-get install git` (triggered by the entrypoint) had time to finish, leaving the container in a partially-installed state.

**Fix:** Wait for the container to reach a ready state before exec-ing in:
```sh
# Wait until apt install is complete — watch logs until no apt activity
podman logs -f ollama-s390x-dev

# Then exec in
podman exec -it ollama-s390x-dev bash
```

**Permanent fix:** Rebuild the dev image using the updated `Dockerfile.dev` that pre-installs `git`, `curl`, `cmake`, `ninja-build`, and other build dependencies at image build time, eliminating runtime apt calls entirely.

---

### 6.4 Podman Compose not finding `compose.yml`

**Symptom:**
```
Error: no compose file found in current directory
```

**Root Cause:** `compose.yml` is generated by `scripts/bootstrap_dev_env.sh` and is not committed to the repository. If the bootstrap script has not been run, the file does not exist.

**Fix:**
```sh
bash scripts/bootstrap_dev_env.sh
```

Verify the file was created:
```sh
ls -la compose.yml
```

Then retry `podman compose up`.

---

### 6.5 Container architecture mismatch

**Symptom:**
```
exec /usr/local/bin/ollama: exec format error
```

This error appears when trying to run an s390x container image on an x86_64 (or other non-s390x) host without emulation.

**Root Cause:** The container image was compiled for `linux/s390x` (big-endian). Non-s390x hosts cannot execute s390x binaries natively.

**Fix (native):** Build and run the container directly on an IBM Z or LinuxONE system running a supported Linux distribution.

**Fix (cross-platform, development only):** Use the `--platform` flag to signal the intended architecture and ensure QEMU user-mode emulation is installed on the host:
```sh
podman run --platform linux/s390x -it ollama-s390x-dev bash
```

> ⚠️ Emulation via QEMU is significantly slower than native execution and is not suitable for production inference workloads.

---

### 6.6 Volume permissions in Podman

**Symptom:**
```
permission denied: open /models/some-model.gguf
```

**Root Cause:** SELinux on the host labels the volume source directory with a context that the container process is not permitted to access.

**Fix:** Append the `:Z` relabelling option to all volume mount flags. This instructs Podman to relabel the mount point with the correct SELinux context for the container:

```sh
podman run -d \
  --name ollama-s390x \
  -v ./models:/models:Z \
  -v ~/.ollama:/root/.ollama:Z \
  ollama-s390x
```

> The `:Z` label grants private, unshared access to that specific container. Use `:z` (lowercase) if the volume needs to be shared between multiple containers.

---

## 7. Build Issues

### 7.1 CMake prerequisites

Building from source requires the following minimum toolchain versions:

| Tool | Minimum version |
|------|----------------|
| CMake | 3.28 |
| Ninja | any recent |
| GCC or Clang | GCC 11+ / Clang 14+ |
| Go | 1.21+ |

Install all build dependencies on Ubuntu/Debian:
```sh
sudo apt update
sudo apt install -y cmake ninja-build build-essential pkg-config
```

Verify CMake version:
```sh
cmake --version
# cmake version 3.28.x or later required
```

Install Go 1.21+ from the [official Go downloads page](https://go.dev/dl/) if your distribution's package manager provides an older version.

---

### 7.2 OpenBLAS not found warning

**Warning:**
```
s390x build: OpenBLAS not found on this host.
  SIMD (VXE) acceleration depends on BLAS; performance will be degraded.
```

**Root Cause:** The CMake build probes for `libopenblas` to enable accelerated BLAS operations for matrix multiplication. If not found, GGML falls back to a generic C implementation.

**Fix:**
```sh
sudo apt install -y libopenblas-dev
```

After installing, re-run CMake configuration to pick up the library:
```sh
cmake -B build . && cmake --build build --parallel 8
```

---

### 7.3 zDNN library not found

**Error:**
```
s390x build: GGML_ZDNN=ON but the IBM zDNN library (libzdnn) was not found.
```

**Root Cause:** zDNN acceleration was requested (`-DOLLAMA_S390X_ZDNN=ON`) but the IBM zDNN library is not installed on the build host.

**Fix (install libzdnn):**
Download and install the library from the IBM zDNN GitHub repository:
```
https://github.com/IBM/zDNN
```

Follow the build and install instructions in that repository, then re-run CMake.

**Fix (disable zDNN):**
If you do not have a z17 system or do not require AIU hardware acceleration, disable the flag:
```sh
cmake -B build -DOLLAMA_S390X_ZDNN=OFF .
cmake --build build --parallel 8
```

---

### 7.4 CMake PRIVATE_HEADER / PUBLIC_HEADER warnings

**Warning:**
```
CMake Warning: Target 'ggml' has PUBLIC_HEADER files but no PUBLIC_HEADER DESTINATION
CMake Warning: Target 'ggml' has PRIVATE_HEADER files but no PRIVATE_HEADER DESTINATION
```

**Impact:** Non-fatal. The build succeeds normally. These warnings indicate that when CMake's `install()` command runs, GGML headers will not be copied to a standard include path. This only matters if you are building a separate project that tries to link against the installed GGML as a library. For building and running Ollama itself, these warnings can be safely ignored.

---

### 7.5 UI assets warning

**Warning:**
```
Embedded UI assets not found. Server will run without web interface.
```

**Impact:** Low priority for most users. The Ollama REST API (`/api/generate`, `/api/chat`, etc.) is fully functional. Only the optional browser-based chat interface is absent.

To build with the web UI, generate the frontend assets before the Go build:
```sh
cd app && npm install && npm run build && cd ..
make build
```

---

### 7.6 Build using Makefile

The project Makefile provides convenient targets for the most common build operations:

```sh
# Build the Go binary (ollama)
make build

# Build llama-server using the cpu_s390x CMake preset
make cmake

# Remove all build artifacts
make clean

# Run health check + quick inference smoke test
make smoke
```

Run `make help` for a full list of available targets.

---

### 7.7 Full CMake build from scratch

To configure, build, and run the server entirely from the CMake layer:

```sh
# Configure (run from repository root)
cmake -B build .

# Build using 8 parallel jobs (adjust to your core count)
cmake --build build --parallel 8

# Start the server
./ollama serve
```

For a release-optimised build:
```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release .
cmake --build build --parallel 8
```

For an s390x-specific build with VXE SIMD enabled and zDNN disabled (the typical z15 configuration):
```sh
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DOLLAMA_S390X_BIGENDIAN=ON \
  -DOLLAMA_S390X_VXE=ON \
  -DOLLAMA_S390X_ZDNN=OFF \
  .
cmake --build build --parallel 8
```

---

## 8. Runtime / Model-Loading Issues

### 8.1 `invalid GGUF version: 50331648`

**Symptom:**
```
Error: invalid GGUF version: 50331648
```
Model loading fails immediately after the file is opened.

**Root Cause:** `50331648` is `0x03000000` in hexadecimal — a little-endian GGUF version 3 magic value that has been read without byte-swapping. On a big-endian s390x system, the raw four bytes `03 00 00 00` are interpreted as the 32-bit big-endian integer `0x03000000 = 50331648` instead of the correct value `3`.

This means either:
- The s390x byte-swap patches have not been applied, or
- You are running an unpatched upstream Ollama binary against a standard little-endian GGUF file.

**Fix:** Verify that the s390x compatibility patches are active by checking the logs for the string `compat patch`:
```sh
grep "compat patch\|mmap disabled\|bswap" ~/.ollama/logs/server.log
```

If these strings are absent, you are running an unpatched binary. Reinstall from this fork's releases or rebuild from source with all patches applied (see [Section 7](#7-build-issues)).

---

### 8.2 Garbage / nonsense output from model

**Symptom:** The model loads without errors and produces output, but the output is random tokens, repeated characters, or complete nonsense — not a language model failure but byte-level corruption.

**Root Cause:** GGUF metadata (header, key-value pairs, tensor descriptors) was byte-swapped correctly, but the tensor weight data itself was not byte-swapped, or was byte-swapped in the wrong order/width.

**Fix:** Three patch files must be applied in sequence. Verify all three are present and were applied during the build:

| Patch | File | Purpose |
|-------|------|---------|
| 001 | `llama/compat/001-llama-cpp-hooks.patch` | Compat layer call-site insertions |
| 002 | `llama/compat/002-gguf-big-endian-byteswap.patch` | Byte-swap GGUF metadata (header, KV pairs, tensor descriptors) |
| 003 | `llama/compat/003-tensor-data-big-endian-byteswap.patch` | Byte-swap tensor weight data; disable mmap on big-endian |

If any patch is missing, rebuild from source:
```sh
git checkout main
make cmake
```

---

### 8.3 Model hangs on first token

**Symptom:** After sending a prompt, the server accepts the request but no tokens appear for 0.5–5 seconds. Subsequent tokens arrive at normal speed.

**Root Cause:** On the first load of a model, mmap is disabled (see log pattern `mmap disabled`) and all tensor weights are read sequentially into RAM with per-tensor byte-swapping applied. For large models (7B+), this sequential byte-swap pass takes noticeable time.

**This is expected behaviour.** The latency does not repeat on subsequent requests within the same session because the model stays loaded in memory.

**Workaround:** First-load latency of 0.5–2 seconds is normal for small models (≤3B) and up to 10–20 seconds for large models (7B+). Pre-warm the model with a throwaway request after `ollama serve` starts:
```sh
curl -s http://localhost:11434/api/generate \
  -d '{"model":"llama3.2:1b","prompt":"hi","stream":false}' > /dev/null
```

---

### 8.4 LLM library override

If Ollama is selecting the wrong inference backend (e.g. attempting a GPU path that does not exist on s390x), you can force the CPU library:

```sh
OLLAMA_LLM_LIBRARY="cpu" ollama serve
```

You can also set this permanently in the systemd unit file or in `/etc/ollama/ollama.conf`:
```sh
sudo systemctl edit ollama
```
Add under `[Service]`:
```ini
Environment="OLLAMA_LLM_LIBRARY=cpu"
```

---

### 8.5 `/tmp noexec` runtime error

**Symptom:**
```
fork/exec /tmp/ollama<random>/llama-server: permission denied
```
or similar errors about executing a binary extracted to `/tmp`.

**Root Cause:** The filesystem hosting `/tmp` is mounted with the `noexec` flag, which prevents executing binaries placed there. Ollama extracts runner binaries to a temporary directory under `/tmp` by default.

**Fix:** Redirect the temporary directory to a location on an `exec`-enabled filesystem:
```sh
export OLLAMA_TMPDIR=/usr/share/ollama/
ollama serve
```

Set this permanently in the systemd unit or your shell profile:
```sh
# /etc/systemd/system/ollama.service (via systemctl edit ollama)
Environment="OLLAMA_TMPDIR=/usr/share/ollama/"
```

---

### 8.6 `llama-server --list-devices` exits 127 (benign)

**Symptom:** The server logs show:
```
llama-server --list-devices: exit status 127
```

**Root Cause:** Ollama calls `llama-server --list-devices` at startup to enumerate accelerator hardware (GPUs, NPUs). On s390x there is no GPU device enumeration support; `llama-server` returns exit code 127 (command/feature not found) for this flag.

**This is expected and benign.** The server proceeds normally using the CPU backend. No action is required.

---

## 9. Quantization Format Compatibility

The following quantization formats have been tested on s390x big-endian with this fork's byte-swap patches applied:

| Format | Status | Notes |
|--------|--------|-------|
| Q4_0 | ✅ Supported | Baseline format; widely compatible |
| Q4_K_M | ✅ Supported | **Recommended default** — good balance of size and quality |
| Q8_0 | ✅ Supported | Higher RAM usage, faster than Q4_K_M for throughput-sensitive tasks |
| Q5_K_M | ✅ Supported | Higher quality than Q4_K_M at modest RAM cost |
| F16 | ✅ Supported | Full half-precision; large RAM footprint |
| Q2_K | ⚠️ Unstable | Highly variable throughput (1.4–11.4 tok/s); output quality inconsistent; **avoid for production** |
| IQ4_XS | ❌ Not supported | iQuant byte-swap path not yet patched; loading will fail or produce corrupt output |
| BF16 | ⚠️ TBD | Big-endian BF16 handling documentation pending; not validated |

> **Recommendation:** Use **Q4_K_M** for the best all-around reliability on s390x. Use **Q8_0** when you have sufficient RAM and need higher throughput or quality. Avoid **Q2_K** and **IQ4_XS** in production.

---

## 10. Performance / Throughput Issues

### 10.1 Slow first inference

**Cause:** On s390x, `mmap()` of model files is disabled by the compatibility patches because memory-mapped big-endian reads would require every access to byte-swap in place, which is slower and more complex than a one-time bulk conversion. Instead, all tensor weights are read into RAM with byte-swapping applied during model load.

**Expected latency overhead vs. x86:** An additional 0.5–2 seconds on the first `ollama run` or first API request after a model is loaded. This overhead is a one-time cost per server restart — the model remains resident in RAM for all subsequent requests.

---

### 10.2 Variable throughput / tok/s drops

**Cause:** On shared LPARs (Logical Partitions), the IBM z Integrated Information Processor (zIIP/AIU) co-processor capacity is shared across all LPARs on the same physical frame. Under contention, available AIU throughput can drop significantly mid-inference.

**Workaround:**
- Run inference workloads in a **dedicated LPAR** with reserved CPU and memory resources.
- If using a shared LPAR, schedule batch inference jobs during off-peak hours when co-processor contention is lowest.
- Monitor LPAR CPU utilisation with `vmstat`, `top`, or IBM's `nmon` tool.

---

### 10.3 Throughput reference (tested on z15/AIU with 12 VFs)

The following numbers were measured on a z15 system with 12 virtual functions (VFs) allocated to the AIU co-processor:

| Model | Quantization | Throughput |
|-------|-------------|-----------|
| SmolLM 135M | Q4_0 | ~104.6 tok/s |
| Llama 3.2 1B | Q8_0 | ~22.75 tok/s |
| Mistral 7B | Q4_K_M | ~5.8 tok/s |

> These figures represent single-user, single-request throughput. Concurrent requests will share available capacity.

---

### 10.4 Enabling VXE SIMD acceleration

s390x VXE (Vector Extension Facility Enhancement) provides 256-bit SIMD vector instructions analogous to AVX2 on x86. This fork enables VXE by default on z15 and later hardware.

**Confirm VXE is enabled** by checking CMake configuration output during build:
```
--   OLLAMA_S390X_BIGENDIAN = ON
--   OLLAMA_S390X_VXE       = ON  (GGML_VXE; z15+ SIMD)
--   OLLAMA_S390X_ZDNN      = OFF  (GGML_ZDNN; z17+ zAIU co-processor)
```

If VXE does not appear or shows `vxe=OFF`, force it explicitly:
```sh
cmake -B build -DOLLAMA_S390X_VXE=ON .
```

> VXE is available on z15 (8561/8562) and z16 (3931/3932) hardware. It is not available on z14 or earlier.

---

### 10.5 Enabling zDNN (z17+ only)

The IBM zDNN (Deep Neural Network) library provides hardware-accelerated tensor operations on the IBM Integrated Accelerator for AI (IAA), available on z17 systems.

**zDNN is disabled by default** because it requires specific hardware and the `libzdnn` library to be installed.

**Opt-in:**
```sh
cmake -B build \
  -DOLLAMA_S390X_ZDNN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  .
cmake --build build --parallel 8
```

**Prerequisites:**
- z17 (3932) hardware with IAA enabled in the LPAR profile
- `libzdnn` installed (see [Section 7.3](#73-zdnn-library-not-found))

**Verify zDNN is active** after build:
```
--   OLLAMA_S390X_BIGENDIAN = ON
--   OLLAMA_S390X_VXE       = ON  (GGML_VXE; z15+ SIMD)
--   OLLAMA_S390X_ZDNN      = ON  (GGML_ZDNN; z17+ zAIU co-processor)
```

---

## 11. Known Model Compatibility Issues

### Qwen2.5 0.5B — ❌ Do Not Use

Qwen2.5 0.5B causes a server crash on s390x. The model appears to load and begins generating, but produces garbage output and then crashes the `llama-server` process. Root cause is under investigation. **Avoid this model until a fix is available.**

### Q2_K quantization — ⚠️ Unstable

Q2_K quantized models are unstable on s390x across all model families. Symptoms include:
- Wildly variable token throughput (observed range: 1.4–11.4 tok/s on the same model)
- Occasional incorrect or truncated responses
- Worse instability on smaller models (< 1B parameters)

Use Q4_K_M or Q4_0 instead.

---

## 12. Getting More Help

If this guide does not resolve your issue:

- **GitHub Issues:** Open a bug report or ask a question at  
  https://github.com/Brice12347/ollama-s390x/issues  
  Please include: your s390x hardware model, Linux distro and kernel version, Ollama version (`ollama --version`), relevant log output, and the model name + quantization format you were using.

- **Repository documentation:** Additional guides are in the `docs/` directory of this repository:
  - [`docs/bottleneck_analysis.md`](bottleneck_analysis.md) — Performance profiling and bottleneck analysis
  - [`docs/gguf_s390x_notes.md`](gguf_s390x_notes.md) — GGUF big-endian format details and byte-swap implementation notes
  - [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) — IBM Z architecture reference for this port

- **Upstream Ollama documentation:** https://github.com/ollama/ollama/blob/main/docs/

> When filing an issue, always include the output of `journalctl -u ollama --no-pager -n 100` or `~/.ollama/logs/server.log`. Issues without logs are significantly harder to diagnose.
