# Ollama s390x — E2E / FFDC Team Handoff

**Date:** 2026-07-10  
**Prepared by:** IBM Z AI Platform team (Justin Veltri, Brice Patchou)  
**For:** E2E test team, FFDC integration team, dependent service owners  
**Release:** `v0.2.0`  
**Status:** ✅ Ready for integration

---

## What Was Delivered

Ollama — the open-source local LLM runtime — ported to IBM Z (s390x) architecture. This release provides:

- A one-liner installer that works on Ubuntu 22.04 and Debian 12 (glibc ≥ 2.36)
- Pre-built `ollama` binary + shared libraries + `llama-server` for s390x
- CPU-only inference with VXE2 SIMD acceleration
- Automatic big-endian byte-swap for standard GGUF model files
- Full Ollama HTTP API surface on `localhost:11434`
- A confirmed-working set of models for FFDC log analysis use cases

---

## Quick Start (5 Minutes)

### 1. Install

On any Ubuntu 22.04 / Debian 12 s390x system:

```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

The installer:
- Downloads the `v0.2.0` release tarball from GitHub
- Extracts `ollama` binary to `/usr/local/bin/`
- Extracts shared libraries to `/usr/local/lib/ollama/`
- Creates `.so.0` symlinks and runs `ldconfig`
- Installs and starts a systemd service (`ollama.service`)

### 2. Verify the service is running

```sh
systemctl status ollama
curl http://localhost:11434/
# Expected: Ollama is running
```

### 3. Pull the recommended model

```sh
ollama pull granite3.3:2b
```

This downloads ~1.5 GB. Requires network access to `ollama.com`.

### 4. Verify inference works

```sh
ollama run granite3.3:2b "What is IBM Z?"
```

Or via the API:

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model": "granite3.3:2b", "prompt": "What is IBM Z?", "stream": false}' \
  | jq .response
```

---

## API Summary

Full documentation: [`docs/api_contract.md`](api_contract.md)

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/` | Health check — returns `Ollama is running` |
| `GET` | `/api/tags` | List downloaded models |
| `POST` | `/api/generate` | Single-turn completion |
| `POST` | `/api/chat` | Multi-turn chat |
| `POST` | `/api/embed` | Generate embeddings |
| `GET` | `/api/ps` | List currently loaded models |
| `GET` | `/api/version` | Server version (returns `0.0.0` on s390x dev builds) |
| `POST` | `/api/pull` | Pull a model from Ollama registry |
| `POST` | `/api/show` | Show model metadata |
| `DELETE` | `/api/delete` | Delete a model |
| `POST` | `/v1/chat/completions` | OpenAI-compatible chat endpoint |

**Base URL:** `http://localhost:11434`  
**Auth:** None required  
**Format:** `Content-Type: application/json` on all POST requests

---

## Recommended Models

| Model | Pull command | RAM | tok/s | Best for |
|-------|-------------|-----|-------|---------|
| `granite3.3:2b` | `ollama pull granite3.3:2b` | 1.9 GiB | 12.25 | FFDC log analysis, incident summaries |
| `llama3.2:1b` | `ollama pull llama3.2:1b` | 1.5 GiB | 17.6 | E2E test baseline, deterministic outputs |
| `smollm:135m` | `ollama pull smollm:135m` | 178 MiB | 104.6 | Health checks, CI smoke tests |

> For systems with only 4 GB RAM (e.g. LinuxONE Community Cloud): use `llama3.2:1b` or `smollm:135m`.

Do **not** use `qwen2.5:0.5b` (crashes) or `IQ4_XS` quantizations (fail to load).

---

## FFDC Integration — Key Patterns

### Pattern 1: Structured log parsing (machine-readable output)

Use the `format` field with a JSON schema to get typed output directly — no regex post-processing:

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Parse this z/OS abend log entry into structured fields:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=14.23.41 SEQ=03271 CPU=0000 ASID=00AF\n  PSW AT TIME OF ERROR  078D1000 80000000  00000000 00123456\n  REASON CODE = 0C4",
    "format": {
      "type": "object",
      "properties": {
        "message_id":   { "type": "string" },
        "time":         { "type": "string" },
        "asid":         { "type": "string" },
        "reason_code":  { "type": "string" },
        "error_type":   { "type": "string" },
        "severity":     { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["message_id","time","asid","reason_code","error_type","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq .response | jq -r . | jq .
```

Expected output:

```json
{
  "message_id": "IEA995I",
  "time": "14.23.41",
  "asid": "00AF",
  "reason_code": "0C4",
  "error_type": "Protection Exception (ABEND S0C4)",
  "severity": "HIGH",
  "recommended_action": "Investigate memory access at address 00123456 in ASID 00AF."
}
```

### Pattern 2: Incident summary (free-text, human-readable)

```sh
curl -s http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "messages": [
      {
        "role": "system",
        "content": "You are an IBM Z systems expert. Generate concise FFDC incident summaries. Be precise and technical."
      },
      {
        "role": "user",
        "content": "Summarize: 47 abend S0C4 events from 14:20–14:35. ASID 00AF. Memory address 00123456 not accessible. LPAR at 98% utilization."
      }
    ],
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42 }
  }' | jq .message.content
```

### Pattern 3: Long log analysis (multi-thousand token input)

Increase `num_ctx` to fit your log excerpt. Default is 2048 tokens (~100 log lines). Each doubling roughly doubles KV-cache RAM.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Summarize the following z/OS job log and list any errors:\n\n<paste log here>",
    "stream": false,
    "options": {
      "temperature": 0.1,
      "num_ctx": 8192,
      "num_predict": 512
    }
  }' | jq .response
```

---

## E2E Test Setup

### Test configuration

| Setting | Recommended value | Reason |
|---------|------------------|--------|
| `stream` | `false` | Single atomic response; easier to assert |
| `temperature` | `0.0` | Deterministic output |
| `seed` | `42` | Reproducible across runs |
| `num_predict` | `50`–`100` | Caps latency in CI |
| `keep_alive` | `"0"` after teardown | Frees memory between test cases |

### Minimal smoke test

```sh
#!/bin/bash
# smoke_test.sh — Run against a live Ollama s390x instance

BASE_URL="http://localhost:11434"

# 1. Health check
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
[[ "$STATUS" == "200" ]] || { echo "FAIL: health check"; exit 1; }

# 2. Model is loaded
MODELS=$(curl -s "$BASE_URL/api/tags" | jq -r '.models[].name')
echo "$MODELS" | grep -q "llama3.2:1b" || { echo "FAIL: model not present"; exit 1; }

# 3. Inference returns done:true
RESULT=$(curl -s "$BASE_URL/api/generate" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2:1b","prompt":"Reply OK","stream":false,"options":{"temperature":0,"seed":1,"num_predict":5}}')
echo "$RESULT" | jq -e '.done == true' > /dev/null || { echo "FAIL: done not true"; exit 1; }

echo "PASS: all smoke tests passed"
```

### Deterministic assertion test

```sh
RESPONSE=$(curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "Reply with exactly: OK",
    "stream": false,
    "options": { "temperature": 0.0, "seed": 1, "num_predict": 5 }
  }' | jq -r .response)

# Trim whitespace and assert
[[ "$RESPONSE" == *"OK"* ]] && echo "PASS" || echo "FAIL: got '$RESPONSE'"
```

> **Note:** Exact token-level reproducibility requires identical model weights, quantization, and `seed`. The word "OK" should always appear; exact surrounding whitespace may vary.

### OpenAI SDK example (Python)

```python
from openai import OpenAI
import pytest

client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")

def test_basic_inference():
    response = client.chat.completions.create(
        model="llama3.2:1b",
        messages=[{"role": "user", "content": "Reply with exactly: OK"}],
        temperature=0.0,
        seed=1,
        max_tokens=5,
    )
    assert "OK" in response.choices[0].message.content
    assert response.usage.completion_tokens <= 5
```

---

## Known Limitations

| Limitation | Impact | Workaround |
|-----------|--------|-----------|
| `GET /api/version` returns `"0.0.0"` | Cannot version-gate via API | Use GitHub release tag `v0.2.0` instead |
| CPU-only inference | 5–18 tok/s depending on model | Use `llama3.2:1b` or `smollm:135m` in CI |
| `qwen2.5:0.5b` crashes | Model unavailable | Use `llama3.2:1b` instead |
| `IQ4_XS` quant fails to load | Model unavailable | Use `Q4_K_M` or `Q8_0` |
| `Q2_K` quant is unstable | 1–11 tok/s variance | Avoid in production |
| First inference adds ~0.5–2s | Slower first response | Warm up model with a silent request at startup |
| Structured output may produce invalid JSON | Pipeline parse failure | Always validate with `jq`; retry once on failure |
| No TLS on Ollama listener | Plaintext traffic | Use nginx/HAProxy reverse proxy for TLS |
| `keep_alive: "0"` unload is async | Race condition in tests | Poll `GET /api/ps` until empty |

---

## Environment Variables

| Variable | Effect | Example |
|----------|--------|---------|
| `OLLAMA_HOST` | Change bind address | `OLLAMA_HOST=0.0.0.0` to expose on all interfaces |
| `OLLAMA_MODELS` | Change model storage directory | `OLLAMA_MODELS=/data/models` |
| `OLLAMA_KEEP_ALIVE` | Default keep-alive for all requests | `OLLAMA_KEEP_ALIVE=10m` |
| `OLLAMA_NUM_PARALLEL` | Max concurrent requests | `OLLAMA_NUM_PARALLEL=2` |
| `OLLAMA_DEBUG` | Enable verbose logging | `OLLAMA_DEBUG=1` |

Set in the systemd service by creating an override:

```sh
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=10m"
EOF
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

---

## Network Exposure

By default Ollama binds to `127.0.0.1:11434` — not reachable from other hosts.

To expose to a test network:

```sh
# 1. Set OLLAMA_HOST (see above)
# 2. Open the firewall
sudo ufw allow from <test_network_cidr> to any port 11434

# 3. Verify from a remote host
curl http://<host_ip>:11434/
```

For TLS (required before any public exposure), use nginx as a reverse proxy:

```nginx
server {
    listen 443 ssl;
    server_name ollama.internal.example.com;
    ssl_certificate     /etc/ssl/certs/ollama.crt;
    ssl_certificate_key /etc/ssl/private/ollama.key;
    location / {
        proxy_pass http://127.0.0.1:11434;
        proxy_set_header Host $host;
    }
}
```

---

## Troubleshooting

### Server not responding

```sh
systemctl status ollama
journalctl -u ollama -n 50 --no-pager
```

### Model fails to load — exit status 127

Shared libraries not registered. Fix:

```sh
sudo bash -c '
  cd /usr/local/lib/ollama
  for f in *.so; do ln -sf "$f" "${f}.0"; done
  echo "/usr/local/lib/ollama" > /etc/ld.so.conf.d/ollama.conf
  ldconfig
'
sudo systemctl restart ollama
```

### Out of memory

Use a smaller model. Memory footprint by model:

| Model | Min RAM |
|-------|---------|
| `smollm:135m` | 200 MiB |
| `llama3.2:1b` | 1.7 GiB |
| `granite3.3:2b` | 2.1 GiB |
| `llama3.2:3b` | 2.7 GiB |
| `mistral:7b` | 5.0 GiB |

### Model output is garbled or server crashes

See [known incompatible models](#known-limitations) above. `qwen2.5:0.5b` and `IQ4_XS` quantizations are known-broken on s390x.

---

## File Index

| File | Description |
|------|-------------|
| [`docs/api_contract.md`](api_contract.md) | Full API reference with all endpoints, schemas, curl examples |
| [`docs/model_download.md`](model_download.md) | How to pull, run, and manage models |
| [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) | Tested models with tok/s and RAM benchmarks |
| [`docs/gguf_s390x_notes.md`](gguf_s390x_notes.md) | GGUF endianness and quantization deep dive |
| [`docs/open-webui-s390x.md`](open-webui-s390x.md) | Open WebUI s390x port — all changes, disabled features, deployment notes |
| [`scripts/install.sh`](../scripts/install.sh) | One-liner installer |
| [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) | Raw performance test results from triframe (2026-07-02) |
| [`logs/model_test_001.md`](../logs/model_test_001.md) | Model functional test log |

---

