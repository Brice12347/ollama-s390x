# Step 1 — Install Ollama on IBM Z (s390x)

This is the fastest path from a fresh Linux system to a running Ollama server.
One command handles everything: binary download, library registration, and systemd service setup.

---

## Requirements

| Requirement | Minimum |
|---|---|
| Architecture | `s390x` (IBM Z / LinuxONE) |
| OS | Ubuntu 22.04 / Debian 12 (glibc ≥ 2.36) |
| RAM | 2 GiB (4 GiB recommended) |
| Disk | 5 GiB free (models are downloaded separately) |
| Network | Outbound HTTPS to `github.com` and `ollama.com` |

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

The installer automatically:
1. Detects `s390x` and downloads the pre-built binary from [GitHub Releases](https://github.com/Brice12347/ollama-s390x/releases)
2. Extracts `ollama` to `/usr/local/bin/`
3. Extracts shared libraries to `/usr/local/lib/ollama/` and runs `ldconfig`
4. Creates and starts a `systemd` service (`ollama.service`)
5. Adds the current user to the `ollama` group

> **Pin a specific release** (optional):
> ```sh
> OLLAMA_VERSION=v0.2.0 curl -fsSL \
>   https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
> ```

> **Debug mode** — prints every step:
> ```sh
> OLLAMA_DEBUG=1 curl -fsSL \
>   https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
> ```

---

## Verify the service

```sh
systemctl status ollama
curl http://localhost:11434/
# Expected: Ollama is running
```

---

## Pull and run your first model

```sh
# Lightweight smoke test (~178 MiB, ~105 tok/s)
ollama run smollm:135m "Hello, what platform are you running on?"

# IBM Granite — recommended for enterprise use (~1.9 GiB, ~12 tok/s)
ollama pull granite3.3:2b
ollama run granite3.3:2b "What is IBM Z?"
```

> See [docs/7-models.md](7-models.md) for the full model compatibility matrix with RAM and throughput numbers.

---

## Verify via API

```sh
# Health check
curl http://localhost:11434/

# List downloaded models
curl http://localhost:11434/api/tags | jq .

# Single-turn generation
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"granite3.3:2b","prompt":"What is IBM Z?","stream":false}' \
  | jq .response
```

---

## Uninstall

To remove Ollama completely as if it was never installed:

```sh
sudo systemctl stop ollama
sudo systemctl disable ollama
sudo rm /etc/systemd/system/ollama.service
sudo rm $(which ollama)
sudo rm -rf /usr/share/ollama
sudo userdel ollama
sudo groupdel ollama
sudo systemctl daemon-reload
```

---

## Next steps

| Goal | Guide |
|---|---|
| Build from source | [docs/2-build-from-source.md](2-build-from-source.md) |
| Run in a container | [docs/3-container-build.md](3-container-build.md) |
| Deploy on OpenShift AI | [docs/4-openshift-deploy.md](4-openshift-deploy.md) |
| Add OpenWebUI | [docs/5-open-webui.md](5-open-webui.md) |
| Understand the endianness fix | [docs/6-endianness-fix.md](6-endianness-fix.md) |
| Choose a model | [docs/7-models.md](7-models.md) |
