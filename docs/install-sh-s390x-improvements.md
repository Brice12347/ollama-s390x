# Improving the One-Line Installer for s390x / LinuxONE

## Goal

Enable IBM Z (s390x) users to install Ollama with a single command from a
clean shell — identical in experience to the official Ollama one-liner on
x86_64:

```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

After the command completes, the user can immediately run:

```sh
ollama run llama3.2:1b
```

No extra manual steps.

---

## What the Script Does

`scripts/install.sh` is a POSIX shell script that:

1. Detects the OS and CPU architecture (`uname -s`, `uname -m`).
2. For `s390x`, queries the GitHub Releases API to find the latest release tag,
   downloads the pre-built `ollama-linux-s390x.tgz` tarball from that release,
   extracts it, symlinks the binary into `PATH`, and optionally configures a
   systemd service.
3. For `amd64` / `arm64`, downloads from `ollama.com` as before.

---

## Issues Found and How They Were Fixed

### Issue 1 — Wrong symlink target ("binary cannot start")

**Symptom:** `ollama` was installed but refused to start. `which ollama`
returned a path that pointed at a non-existent file.

**Root cause:** The original s390x symlink pointed at
`$OLLAMA_INSTALL_DIR/ollama` (the install directory root), but the tarball
extracts the binary to `$OLLAMA_INSTALL_DIR/bin/ollama`. The symlink was
dangling.

**Fix:**
```sh
# Before (broken)
$SUDO ln -sf "$OLLAMA_INSTALL_DIR/ollama" "$BINDIR/ollama"

# After (correct)
$SUDO ln -sf "$OLLAMA_INSTALL_DIR/bin/ollama" "$BINDIR/ollama"
```

---

### Issue 2 — `install_success` printed after an error

**Symptom:** After a fatal error, the script printed:
```
ERROR: Could not determine latest release tag.
...
>>> The Ollama API is now available at 127.0.0.1:11434.
>>> Install complete. Run "ollama" from the command line.
```

The success message appeared even though installation had failed, which was
confusing and misleading.

**Root cause:** `trap install_success EXIT` fires on every exit, including
`exit 1` triggered by `error()`. The EXIT trap was not cleared before
erroring out.

**Fix:** Added `trap - EXIT` inside `error()` so the success trap is cleared
before the script exits with a non-zero code:
```sh
# Before
error() { echo "${red}ERROR:${plain} $*"; exit 1; }

# After
error() { echo "${red}ERROR:${plain} $*" >&2; trap - EXIT; exit 1; }
```

The `>&2` redirect was also added so error output goes to stderr, consistent
with `status()`.

---

### Issue 3 — `configure_systemd_s390x: command not found`

**Symptom:** The install completed but printed:
```
main: line 199: configure_systemd_s390x: command not found
```

**Root cause:** In POSIX shell, a function must be defined before it is called.
The `configure_systemd_s390x` function was defined after the s390x block, but
the s390x block called it and then did `exit 0` — the shell never reached the
function definition.

**Fix:** Moved `configure_systemd_s390x` to before the s390x block so it is
defined by the time it is called.

---

### Issue 4 — No systemd service configured for s390x

**Symptom:** On LinuxONE servers, Ollama did not start automatically on boot.

**Root cause:** The original s390x branch exited early before reaching the
`configure_systemd` call used by the amd64/arm64 path.

**Fix:** Added a dedicated `configure_systemd_s390x` function and called it
just before the s390x `exit 0`. The s390x service unit differs from the
standard one — it omits GPU device groups (`render`, `video`) which do not
exist on LinuxONE, and uses `WantedBy=multi-user.target` (server default)
instead of `WantedBy=default.target`:

```ini
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=..."

[Install]
WantedBy=multi-user.target
```

---

### Issue 5 — Opaque error when no GitHub Release exists

**Symptom:** When no release had been published yet, the script failed with:
```
ERROR: Could not determine latest release tag from https://github.com/...
```

No explanation of why, or what to do next.

**Fix:** Expanded the error message to name the exact API endpoint queried,
the likely cause (rate limit or no release yet), and a concrete workaround:

```
ERROR: Could not determine latest release tag.
  API endpoint : https://api.github.com/repos/Brice12347/ollama-s390x/releases/latest
  Possible cause: GitHub API rate limit or no published release yet.
  Workaround   : Set OLLAMA_VERSION=vX.Y.Z and re-run, e.g.:
    OLLAMA_VERSION=v0.1.1 curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

---

### Issue 6 — Hardcoded repo slug in two places

**Symptom:** The GitHub API URL and the download URL each contained the
literal string `Brice12347/ollama-s390x`. A repo rename would require two
changes in separate places.

**Fix:** Extracted a single `S390X_REPO_SLUG` variable at the top of the
s390x block:

```sh
S390X_REPO_SLUG="Brice12347/ollama-s390x"
S390X_REPO="https://github.com/${S390X_REPO_SLUG}"
```

All URLs are now derived from this single variable.

---

### Issue 7 — Unquoted shell variables

**Symptom:** Potential word-splitting on paths containing spaces; `$PATH`
unquoted in a `grep -q` call.

**Fix:** All `$BINDIR`, `$OLLAMA_INSTALL_DIR`, and `$PATH` expansions inside
the s390x block were double-quoted.

---

### Issue 8 — No `.tar.zst` fallback

**Symptom:** If a release only published a `.tar.zst` asset (smaller, faster
to decompress), the script would fail silently.

**Fix:** Added a HEAD-check on the `.tgz` URL first. If unavailable, falls
back to `.tar.zst` with a clear error if `zstd` is not installed:

```sh
if curl --fail --silent --head --location "$S390X_URL_TGZ" >/dev/null 2>&1; then
    # download .tgz
else
    # fall back to .tar.zst
fi
```

---

### Issue 9 — `install_success` defined twice, called before definition

**Symptom:** The function was defined inline inside the s390x block (after
its own call on the next line), and again for the non-s390x path — duplicated
and in the wrong order.

**Fix:** Consolidated to a single definition moved before both code paths.
The EXIT trap handles calling it on success; no explicit call needed.

---

### Issue 10 — Incomplete release tarball (missing `llama-server`)

**Symptom:** After a successful install, `ollama run` failed with:
```
500 Internal Server Error: error starting llama-server: llama-server binary not found
(checked: /usr/local/lib/ollama/llama-server, ...)
```

**Root cause:** The initial release tarball only contained `bin/ollama` (the
Go CLI binary). Ollama requires a second binary — `llama-server` — plus
several shared libraries in `lib/ollama/`. These are produced by the CMake
build and land in `build/lib/ollama/` but were not included in the tarball.

**Fix:** Rebuild and repackage to include the full `lib/ollama/` tree:

```sh
cd /workspace/ollama-s390x

# Clean rebuild
rm -rf build dist
cmake -B build .
cmake --build build --parallel $(nproc)

# Package bin/ollama AND lib/ollama/*
mkdir -p dist/bin dist/lib/ollama
cp ./ollama dist/bin/ollama
cp -r build/lib/ollama/. dist/lib/ollama/

# Create the tarball
tar -czf /workspace/ollama-linux-s390x.tgz -C dist bin lib
```

The tarball must have this internal structure:
```
bin/ollama                   ← Go CLI binary
lib/ollama/llama-server      ← inference server (was missing)
lib/ollama/libggml-base.so
lib/ollama/libggml.so
lib/ollama/libllama.so
lib/ollama/libggml-cpu*.so   ← CPU SIMD variants
```

---

## Publishing a Release Without GitHub CLI

The Spyre container (s390x) has no `apt-get`, no `dpkg`, and GitHub CLI (`gh`)
does not publish an s390x binary. The release was created using plain `curl`
against the GitHub REST API.

### Step 1 — Create a GitHub Personal Access Token

Go to **Settings → Developer Settings → Personal access tokens → Fine-grained
tokens** on GitHub. Grant it `Contents: Read and write` on the
`Brice12347/ollama-s390x` repository.

### Step 2 — Create the release

```sh
GITHUB_TOKEN="YOUR_GITHUB_PAT"

RELEASE=$(curl -s -X POST \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/Brice12347/ollama-s390x/releases \
  -d '{
    "tag_name": "v0.1.1",
    "name": "v0.1.1",
    "body": "Fix: include llama-server and shared libs in release tarball",
    "draft": false,
    "prerelease": false
  }')

echo "$RELEASE"
```

The response JSON contains an `upload_url` field needed for the next step.

### Step 3 — Extract the upload URL

```sh
UPLOAD_URL=$(echo "$RELEASE" | grep '"upload_url"' | cut -d'"' -f4 | sed 's/{.*}//')
echo "Upload URL: $UPLOAD_URL"
```

### Step 4 — Upload the tarball asset

```sh
curl -s -X POST \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  "${UPLOAD_URL}?name=ollama-linux-s390x.tgz" \
  --data-binary @/workspace/ollama-linux-s390x.tgz
```

Once published, the install script's GitHub API call to `/releases/latest`
will resolve to `v0.1.1` automatically — no changes to the script needed.

---

## Final Result

After all fixes, the one-liner works end-to-end on a clean LinuxONE shell.
The following is the actual output recorded on the Spyre container (IBM Z,
s390x) during the first successful end-to-end test:

```
[root@e0ee8c207e86 oneline-test1]# curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
>>> Detected IBM Z (s390x) architecture
>>> Fetching latest s390x release from https://github.com/Brice12347/ollama-s390x...
>>> Resolved release tag: v0.1.1
>>> Cleaning up old version at /usr/local/lib/ollama
>>> Downloading ollama-linux-s390x.tgz (v0.1.1)...
######################################################################## 100.0%
>>> IBM Z (s390x) architecture detected - running in CPU-only mode
>>> Adding current user to ollama group...
>>> Creating ollama systemd service (s390x)...
WARNING: systemd is not running; service will start on next boot
>>> The Ollama API is now available at 127.0.0.1:11434.
>>> Install complete. Run "ollama" from the command line.
```

The `WARNING: systemd is not running` line is expected inside the Spyre
container — systemd is not available in containers. The service unit is written
to disk and will activate on the next host boot or when run directly on
LinuxONE outside a container.

Immediately after installation, without any extra steps:

```
[root@e0ee8c207e86 oneline-test1]# ollama run llama3.2:1b
>>> Hello how are you doing
I'm doing well, thank you for asking. I'm a large language model, so I don't
have feelings or emotions like humans do, but I'm here and ready to help with
any questions or topics you'd like to discuss. How about you? How's your day
going?
```

---

## Long-Term Path

The long-term goal is to merge s390x support into the official upstream Ollama
repository. Once merged, the standard one-liner:

```sh
curl -fsSL https://ollama.com/install.sh | sh
```

will work on s390x automatically without any fork or redirect.
