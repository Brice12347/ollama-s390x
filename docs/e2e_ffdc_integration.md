# Ollama s390x — E2E / FFDC Integration Guide

**Version:** `v0.2.0`  
**Architecture:** IBM Z (s390x), CPU-only (VXE2 SIMD)  
**Audience:** E2E test teams, FFDC pipeline engineers, dependent service owners  
**Related docs:** [`docs/handoff.md`](handoff.md) · [`docs/api_contract.md`](api_contract.md)

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Service Start](#2-service-start)
3. [Health Checks](#3-health-checks)
4. [Model Setup](#4-model-setup)
5. [Sample Prompts & Expected Responses](#5-sample-prompts--expected-responses)
   - 5.1 [E2E Smoke — Deterministic Inference](#51-e2e-smoke--deterministic-inference)
   - 5.2 [FFDC — Log Anomaly Detection](#52-ffdc--log-anomaly-detection)
   - 5.3 [FFDC — Structured Log Parsing](#53-ffdc--structured-log-parsing)
   - 5.4 [FFDC — Incident Summary](#54-ffdc--incident-summary)
   - 5.5 [FFDC — Root Cause Analysis](#55-ffdc--root-cause-analysis)
   - 5.6 [FFDC — Long Log Analysis](#56-ffdc--long-log-analysis)
   - 5.7 [Embeddings](#57-embeddings)
6. [Failure Behavior & Error Reference](#6-failure-behavior--error-reference)
7. [E2E Test Configuration](#7-e2e-test-configuration)
8. [FFDC Pipeline Configuration](#8-ffdc-pipeline-configuration)
9. [Environment Variables](#9-environment-variables)
10. [Known Limitations](#10-known-limitations)
11. [Integration Checklist](#11-integration-checklist)

---

## 1. Prerequisites

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| Architecture | s390x (IBM Z / LinuxONE) | CPU-only; no GPU required |
| OS | Ubuntu 22.04 or Debian 12 | glibc ≥ 2.36 |
| RAM | 2 GB free | For `granite3.3:2b`; 1 GB OK for `llama3.2:1b` |
| Disk | 5 GB free | Model storage in `~/.ollama/models` |
| Network | Outbound HTTPS to `ollama.com` | For initial model pull only |
| Tools | `curl`, `jq` | For CLI verification |

---

## 2. Service Start

### 2.1 Installation (first time)

```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

The installer:
- Downloads and extracts the `v0.2.0` binary to `/usr/local/bin/ollama`
- Places shared libraries in `/usr/local/lib/ollama/` and runs `ldconfig`
- Installs a systemd service (`ollama.service`) and starts it automatically

### 2.2 Start / Stop / Restart (systemd)

```sh
# Start
sudo systemctl start ollama

# Stop
sudo systemctl stop ollama

# Restart (e.g. after config change)
sudo systemctl restart ollama

# Enable at boot
sudo systemctl enable ollama

# View status
systemctl status ollama
```

### 2.3 Manual start (non-systemd / development)

```sh
# Bind to loopback (default)
ollama serve

# Bind to all interfaces (for remote test clients)
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

### 2.4 Container start

```sh
# Docker / Podman
podman run -d --name ollama \
  -p 127.0.0.1:11434:11434 \
  -v ollama-data:/home/ollama/.ollama \
  quay.io/brice_patchou/ollama-s390x:latest
```

### 2.5 Expected startup sequence

```
time=0s    systemd launches /usr/local/bin/ollama serve
time=~0.5s libllama.so loaded; llama-server binary located
time=~1s   HTTP listener active on 127.0.0.1:11434
time=~1s   "Ollama is running" responds to GET /
```

> **s390x cold-start note:** First inference after service start adds 0.5–2 s for big-endian
> byte-swap and 2–5 s for AIU JIT compilation. These costs are one-time per model load.
> To eliminate cold-start latency in tests, send a warm-up request before running assertions
> (see [§7](#7-e2e-test-configuration)).

---

## 3. Health Checks

### 3.1 Root health endpoint

```sh
curl -i http://localhost:11434/
```

**Expected response (200 OK):**
```
HTTP/1.1 200 OK
Content-Type: text/plain; charset=utf-8

Ollama is running
```

This is the canonical liveness probe. Use it for Docker `HEALTHCHECK`, Kubernetes
`livenessProbe`, and CI gate conditions.

### 3.2 Version endpoint

```sh
curl -s http://localhost:11434/api/version
```

**Expected response:**
```json
{"version": "0.0.0"}
```

> `"0.0.0"` is expected on s390x dev/community builds. The actual release is `v0.2.0`.
> Do **not** use this field for version-gating; use the GitHub release tag instead.

### 3.3 Model list (readiness check)

```sh
curl -s http://localhost:11434/api/tags | jq '.models[].name'
```

**Expected response (after model pull):**
```json
"granite3.3:2b"
"llama3.2:1b"
```

An empty `"models": []` means the service is up but no models have been pulled yet.

### 3.4 Running models (load check)

```sh
curl -s http://localhost:11434/api/ps | jq '.models[].name'
```

Returns models currently loaded in memory. Empty array means no model is loaded.
Use this to confirm a model has unloaded after `keep_alive: "0"`.

### 3.5 Kubernetes probe configuration

```yaml
readinessProbe:
  httpGet:
    path: /
    port: 11434
  initialDelaySeconds: 20
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /
    port: 11434
  initialDelaySeconds: 30
  periodSeconds: 30
```

### 3.6 Docker HEALTHCHECK

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl -sf http://127.0.0.1:11434/ || exit 1
```

---

## 4. Model Setup

### 4.1 Recommended models

| Model | Pull command | RAM | tok/s | Primary use |
|-------|-------------|-----|-------|-------------|
| `granite3.3:2b` | `ollama pull granite3.3:2b` | 1.9 GiB | 12.25 | FFDC log analysis, structured output |
| `llama3.2:1b` | `ollama pull llama3.2:1b` | 1.5 GiB | 17.6 | E2E baseline, deterministic assertions |
| `smollm:135m` | `ollama pull smollm:135m` | 178 MiB | 104.6 | CI smoke tests, health-check warm-up |

> **Memory-constrained systems (< 4 GB RAM, e.g. LinuxONE Community Cloud):**
> Use `llama3.2:1b` or `smollm:135m`.

### 4.2 Pull a model

```sh
# CLI
ollama pull granite3.3:2b

# API (non-streaming)
curl -s http://localhost:11434/api/pull \
  -H "Content-Type: application/json" \
  -d '{"model": "granite3.3:2b", "stream": false}'
```

**Expected response:**
```json
{"status": "success"}
```

### 4.3 Do not use

| Model / quantization | Problem |
|---------------------|---------|
| `qwen2.5:0.5b` | Crashes after first inference on s390x |
| `IQ4_XS` quantization | Fails to load |
| `Q2_K` quantization | Throughput variance 1–11 tok/s; unstable for production |

---

## 5. Sample Prompts & Expected Responses

All examples use `"stream": false` (required for atomic test assertions).  
**Base URL:** `http://localhost:11434`

---

### 5.1 E2E Smoke — Deterministic Inference

Use `temperature: 0.0` and `seed: 42` for reproducible outputs in CI pipelines.

**Request:**
```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "Reply with exactly: OK",
    "stream": false,
    "options": {
      "temperature": 0.0,
      "seed": 42,
      "num_predict": 5
    }
  }'
```

**Expected response (trimmed):**
```json
{
  "model": "llama3.2:1b",
  "response": "OK",
  "done": true,
  "done_reason": "stop",
  "eval_count": 2,
  "total_duration": 450000000
}
```

**Assertion guidance:**
- Assert `done == true` before reading `.response`
- Assert `"OK" in response` (substring; exact whitespace may vary)
- Assert `eval_count <= 5`
- `total_duration` is in nanoseconds; expect 300 ms–1 s on s390x

---

### 5.2 FFDC — Log Anomaly Detection

**Request:**
```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Analyze this IBM Z system log entry and identify the error type and likely cause:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=14.23.41 SEQ=03271 CPU=0000 ASID=00AF\n  PSW AT TIME OF ERROR  078D1000 80000000  00000000 00123456\n  REASON CODE = 0C4\n\nProvide: 1) Error type 2) Likely cause 3) Recommended action",
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42 }
  }' | jq .response
```

**Expected response (representative — free-text):**
```
1) Error type: ABEND S0C4 — Protection Exception. A program attempted to access
   a storage location it does not own or that does not exist.

2) Likely cause: Invalid memory reference at address 00123456 in address space
   ASID=00AF. Common causes include a null/dangling pointer, buffer overrun, or
   incorrect base-displacement calculation in an assembler routine.

3) Recommended action: Capture a full SVC dump for ASID 00AF. Review recent
   changes to programs running in that address space. Check for storage overlays
   using IPCS ANALYZE output.
```

**Assertion guidance:**
- Assert `done == true`
- Assert response contains `"0C4"` or `"Protection Exception"` (substring)
- Do **not** assert exact wording; free-text output varies by run

---

### 5.3 FFDC — Structured Log Parsing

Returns machine-readable JSON directly. No regex post-processing required.

**Request:**
```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Parse this z/OS abend log entry into structured fields:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=14.23.41 SEQ=03271 CPU=0000 ASID=00AF\n  PSW AT TIME OF ERROR  078D1000 80000000  00000000 00123456\n  REASON CODE = 0C4",
    "format": {
      "type": "object",
      "properties": {
        "message_id":         { "type": "string" },
        "time":               { "type": "string" },
        "asid":               { "type": "string" },
        "reason_code":        { "type": "string" },
        "error_type":         { "type": "string" },
        "severity":           { "type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"] },
        "recommended_action": { "type": "string" }
      },
      "required": ["message_id","time","asid","reason_code","error_type","severity","recommended_action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq -r .response | jq .
```

> The outer `jq -r .response` unwraps the API envelope; the second `jq .` parses the
> model-generated JSON object.

**Expected structured output:**
```json
{
  "message_id": "IEA995I",
  "time": "14.23.41",
  "asid": "00AF",
  "reason_code": "0C4",
  "error_type": "Protection Exception (ABEND S0C4)",
  "severity": "HIGH",
  "recommended_action": "Investigate memory access at address 00123456 in job associated with ASID 00AF."
}
```

**Assertion guidance:**
- Assert `done == true` on API response
- Parse `.response` with `JSON.parse()` / `json.loads()` — if it throws, retry once
- Assert `severity` is one of `["LOW","MEDIUM","HIGH","CRITICAL"]`
- Assert `message_id == "IEA995I"` (deterministic — taken verbatim from input)
- Assert `reason_code == "0C4"` (deterministic — taken verbatim from input)

---

### 5.4 FFDC — Incident Summary

Multi-turn chat endpoint for human-readable summaries.

**Request:**
```sh
curl -s http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "messages": [
      {
        "role": "system",
        "content": "You are an IBM Z systems expert. Generate concise FFDC incident summaries from log data. Be precise and technical. Limit summaries to 3 sentences."
      },
      {
        "role": "user",
        "content": "Summarize: System experienced 47 abend S0C4 events between 14:20 and 14:35. Affected ASID 00AF. Memory address 00123456 not accessible. LPAR utilization was at 98% during the event window."
      }
    ],
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42 }
  }' | jq .message.content
```

**Expected response (representative):**
```
Between 14:20 and 14:35, 47 ABEND S0C4 (Protection Exception) events occurred in
address space ASID 00AF, indicating repeated attempts to access restricted memory
at address 00123456. The concurrent LPAR utilization of 98% suggests resource
contention may have contributed to the failure cascade. Immediate investigation of
ASID 00AF job activity and a full SVC dump capture are recommended.
```

**Assertion guidance:**
- Response is at `.message.content` (not `.response`) for `/api/chat`
- Assert response contains `"S0C4"` or `"ASID 00AF"` (substring)
- Assert response is non-empty and `done == true`

---

### 5.5 FFDC — Root Cause Analysis

**Request:**
```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Given these IBM Z performance metrics, identify the bottleneck and suggest remediation:\n\nCPU utilization: 94%\nMemory utilization: 87%\nI/O wait: 42%\nPage faults/sec: 1200\nTransaction response time: 8.3s (SLA: 2.0s)\n\nAnalyze and provide root cause and top 3 remediation steps.",
    "stream": false,
    "options": { "temperature": 0.0, "seed": 42, "num_predict": 300 }
  }' | jq .response
```

**Expected response (representative):**
```
Root cause: The primary bottleneck is I/O wait (42%) combined with a high page
fault rate (1200/s), indicating the system is thrashing due to insufficient real
storage for the current workload. CPU at 94% is a secondary effect — the processor
is spinning waiting for paged-out data to be re-read from DASD.

Remediation:
1. Increase real storage allocation for the LPAR or reduce the number of concurrent
   address spaces competing for frames.
2. Review and tune DFSMS HSM recall settings to reduce DASD I/O latency during
   page-in operations.
3. Implement workload caps or WLM policy adjustments to prevent a single service
   class from monopolizing storage frames under peak load.
```

---

### 5.6 FFDC — Long Log Analysis

For log excerpts longer than ~100 lines, increase `num_ctx`. Each log line is roughly
20–40 tokens. The default `num_ctx` is 2048.

**RAM impact by `num_ctx` for `granite3.3:2b` on s390x:**

| `num_ctx` | Approx. log lines | KV-cache RSS |
|-----------|------------------|-------------|
| 2048 (default) | ~80 | ~2.1 GiB |
| 4096 | ~160 | ~2.7 GiB |
| 8192 | ~320 | ~3.5 GiB |

**Request:**
```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Summarize the following z/OS job log and list any errors or warnings:\n\n<paste log here>",
    "stream": false,
    "options": {
      "temperature": 0.1,
      "seed": 42,
      "num_ctx": 8192,
      "num_predict": 512
    }
  }' | jq .response
```

**Assertion guidance:**
- Confirm total log token count before setting `num_ctx` (use `prompt_eval_count` from
  the response to verify tokens were not truncated)
- If `prompt_eval_count` < expected, `num_ctx` was too small — increase and retry

---

### 5.7 Embeddings

For vector similarity or log clustering use cases.

**Request:**
```sh
curl -s http://localhost:11434/api/embed \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "input": "ABEND S0C4 protection exception in ASID 00AF"
  }' | jq '{embedding_dim: (.embeddings[0] | length), first_3: .embeddings[0][:3]}'
```

**Expected response:**
```json
{
  "embedding_dim": 2048,
  "first_3": [0.0123, -0.0456, 0.0789]
}
```

Batch input:
```json
{
  "model": "llama3.2:1b",
  "input": [
    "ABEND S0C4 protection exception",
    "IEA995I symptom dump",
    "System normal operations"
  ]
}
```

---

## 6. Failure Behavior & Error Reference

### 6.1 HTTP status codes

| Status | Meaning | Common cause |
|--------|---------|-------------|
| `200 OK` | Success | Normal |
| `400 Bad Request` | Invalid JSON or missing required field | Malformed request body |
| `404 Not Found` | Unknown endpoint | Typo in path |
| `500 Internal Server Error` | Model not loaded, or inference error | Model not pulled; out of memory |

### 6.2 Model not found (500)

**Trigger:** Requesting a model that has not been pulled.

**Response:**
```json
{
  "error": "model 'granite3.3:2b' not found, try pulling it first"
}
```

**Resolution:**
```sh
ollama pull granite3.3:2b
```

### 6.3 Context length exceeded

**Trigger:** `prompt` + `num_predict` exceeds `num_ctx`.

**Behavior:** The model silently truncates the prompt. No error is returned.

**Detection:** Compare `prompt_eval_count` in the response to the expected token count.
If `prompt_eval_count` is lower than expected, truncation occurred.

**Resolution:** Increase `num_ctx` to cover prompt + response length:
```json
"options": { "num_ctx": 8192 }
```

### 6.4 Invalid structured output JSON

**Trigger:** `format` schema used but model produces non-conformant output (rare with `granite3.3:2b`, more common with smaller models).

**Detection:**
```sh
jq -r .response <response.json> | jq . 2>&1 | grep -q "parse error" && echo "RETRY"
```

**Resolution:** Retry the request once. If it fails twice, fall back to free-text and parse manually.

### 6.5 Service not responding (connection refused)

**Trigger:** `ollama serve` is not running.

**Error:**
```
curl: (7) Failed to connect to localhost port 11434: Connection refused
```

**Resolution:**
```sh
systemctl status ollama
journalctl -u ollama -n 50 --no-pager
sudo systemctl start ollama
```

### 6.6 Shared library error (exit status 127)

**Trigger:** `libllama.so` or related libraries not found by the dynamic linker.

**Symptom:** `ollama serve` starts but model loading fails immediately.

**Resolution:**
```sh
sudo bash -c '
  cd /usr/local/lib/ollama
  for f in *.so; do ln -sf "$f" "${f}.0"; done
  echo "/usr/local/lib/ollama" > /etc/ld.so.conf.d/ollama.conf
  ldconfig
'
sudo systemctl restart ollama
```

### 6.7 Out of memory

**Trigger:** Model RAM footprint exceeds available free memory.

**Symptom:** `ollama serve` exits or model load silently fails; `journalctl` shows OOM kill.

**Resolution:** Use a smaller model or free other processes:

| Model | Min RAM |
|-------|---------|
| `smollm:135m` | 200 MiB |
| `llama3.2:1b` | 1.7 GiB |
| `granite3.3:2b` | 2.1 GiB |
| `mistral:7b` | 5.0 GiB |

### 6.8 Slow first inference (expected)

**Trigger:** First request after model load on s390x.

**Latency overhead:**
- Big-endian byte-swap: +0.5–2 s (one-time, proportional to model size)
- AIU JIT compilation: +2–5 s (one-time per process lifecycle)

**Resolution:** Send one warm-up request before running timed assertions (see [§7.2](#72-warm-up-request)).

### 6.9 `keep_alive: "0"` race condition

**Trigger:** Asserting model is unloaded immediately after `keep_alive: "0"`.

**Symptom:** `GET /api/ps` still shows model for a few seconds.

**Resolution:** Poll `/api/ps` until the model list is empty:
```sh
until [ "$(curl -s http://localhost:11434/api/ps | jq '.models | length')" == "0" ]; do
  sleep 1
done
```

---

## 7. E2E Test Configuration

### 7.1 Recommended settings

| Parameter | Value | Reason |
|-----------|-------|--------|
| `stream` | `false` | Atomic response; simpler assertions |
| `temperature` | `0.0` | Deterministic output |
| `seed` | `42` | Reproducible across runs |
| `num_predict` | `50`–`100` | Caps CI latency |
| `keep_alive` | `"0"` at teardown | Frees memory between test cases |

### 7.2 Warm-up request

Send once before any timed assertion to absorb byte-swap and AIU JIT overhead:

```sh
# Silent warm-up — discard response
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2:1b","prompt":"warmup","stream":false,"options":{"num_predict":1}}' \
  > /dev/null
```

### 7.3 Minimal bash smoke test

```bash
#!/bin/bash
# smoke_test.sh — Run against a live ollama-s390x instance
set -euo pipefail
BASE_URL="http://localhost:11434"

echo "==> [1/3] Health check"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/")
[[ "$STATUS" == "200" ]] || { echo "FAIL: health check returned $STATUS"; exit 1; }
echo "     PASS: 200 OK"

echo "==> [2/3] Model present"
MODELS=$(curl -s "$BASE_URL/api/tags" | jq -r '.models[].name')
echo "$MODELS" | grep -q "llama3.2:1b" \
  || { echo "FAIL: llama3.2:1b not in model list"; exit 1; }
echo "     PASS: llama3.2:1b present"

echo "==> [3/3] Inference returns done:true"
RESULT=$(curl -s "$BASE_URL/api/generate" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2:1b","prompt":"Reply OK","stream":false,"options":{"temperature":0,"seed":1,"num_predict":5}}')
echo "$RESULT" | jq -e '.done == true' > /dev/null \
  || { echo "FAIL: done not true"; exit 1; }
echo "     PASS: done:true"

echo ""
echo "All smoke tests PASSED"
```

### 7.4 Python (pytest + OpenAI SDK)

```python
import pytest
from openai import OpenAI

BASE_URL = "http://localhost:11434/v1"
client = OpenAI(base_url=BASE_URL, api_key="ollama")


def test_health():
    import urllib.request
    with urllib.request.urlopen("http://localhost:11434/") as r:
        assert r.status == 200
        assert b"Ollama is running" in r.read()


def test_deterministic_inference():
    response = client.chat.completions.create(
        model="llama3.2:1b",
        messages=[{"role": "user", "content": "Reply with exactly: OK"}],
        temperature=0.0,
        seed=42,
        max_tokens=5,
    )
    content = response.choices[0].message.content
    assert "OK" in content
    assert response.usage.completion_tokens <= 5


def test_ffdc_structured_parse():
    import json, requests

    payload = {
        "model": "granite3.3:2b",
        "prompt": (
            "Parse this z/OS abend log entry into structured fields:\n\n"
            "IEA995I SYMPTOM DUMP OUTPUT\n"
            "  TIME=14.23.41 SEQ=03271 CPU=0000 ASID=00AF\n"
            "  REASON CODE = 0C4"
        ),
        "format": {
            "type": "object",
            "properties": {
                "message_id":  {"type": "string"},
                "reason_code": {"type": "string"},
                "severity":    {"type": "string", "enum": ["LOW","MEDIUM","HIGH","CRITICAL"]},
            },
            "required": ["message_id", "reason_code", "severity"],
        },
        "stream": False,
        "options": {"temperature": 0.0},
    }
    r = requests.post("http://localhost:11434/api/generate", json=payload)
    assert r.status_code == 200
    body = r.json()
    assert body["done"] is True
    parsed = json.loads(body["response"])
    assert parsed["message_id"] == "IEA995I"
    assert parsed["reason_code"] == "0C4"
    assert parsed["severity"] in ("LOW", "MEDIUM", "HIGH", "CRITICAL")
```

---

## 8. FFDC Pipeline Configuration

### 8.1 Architecture overview

```
z/OS FFDC log collector
        │  (log excerpts via API call or file)
        ▼
ollama-s390x  (localhost:11434)
        │  POST /api/generate  {"format": {schema}}
        ▼
Structured JSON output
        │
        ├──► FFDC incident database (insert)
        └──► Alerting / ticketing system (if severity == HIGH/CRITICAL)
```

### 8.2 Recommended pipeline settings

| Setting | Value | Notes |
|---------|-------|-------|
| Model | `granite3.3:2b` | Best structured-output compliance on s390x |
| `temperature` | `0.0` | Deterministic; required for pipeline repeatability |
| `format` | JSON schema | Machine-readable; no regex post-processing |
| `num_ctx` | `4096`–`8192` | Set based on longest expected log excerpt |
| `keep_alive` | `"10m"` or `-1` | Keep model in memory between log events |
| Retry policy | 1 retry on JSON parse error | Handle rare non-conformant output |

### 8.3 Output validation (shell)

```sh
RESPONSE=$(curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

# Validate API call succeeded
echo "$RESPONSE" | jq -e '.done == true' > /dev/null \
  || { echo "ERROR: inference did not complete"; exit 1; }

# Validate model output is valid JSON
PARSED=$(echo "$RESPONSE" | jq -r '.response' | jq . 2>/dev/null) \
  || { echo "ERROR: model output is not valid JSON — retrying"; exit 2; }

echo "$PARSED"
```

### 8.4 Output validation (Python)

```python
import json, requests

def parse_ffdc_log(log_text: str, schema: dict) -> dict:
    payload = {
        "model": "granite3.3:2b",
        "prompt": f"Parse this z/OS log entry:\n\n{log_text}",
        "format": schema,
        "stream": False,
        "options": {"temperature": 0.0},
    }
    for attempt in range(2):
        r = requests.post("http://localhost:11434/api/generate", json=payload)
        r.raise_for_status()
        body = r.json()
        if not body.get("done"):
            raise RuntimeError("Inference did not complete")
        try:
            return json.loads(body["response"])
        except json.JSONDecodeError:
            if attempt == 1:
                raise RuntimeError(f"Model output not valid JSON after 2 attempts: {body['response']}")
    return {}  # unreachable
```

---

## 9. Environment Variables

| Variable | Effect | Default | Example |
|----------|--------|---------|---------|
| `OLLAMA_HOST` | Bind address and port | `127.0.0.1:11434` | `0.0.0.0:11434` |
| `OLLAMA_MODELS` | Model storage path | `~/.ollama/models` | `/data/models` |
| `OLLAMA_KEEP_ALIVE` | Default model keep-alive duration | `5m` | `10m` or `-1` (never unload) |
| `OLLAMA_NUM_PARALLEL` | Max concurrent inference requests | `1` | `2`–`4` |
| `OLLAMA_DEBUG` | Verbose logging to stderr | (off) | `1` |
| `OLLAMA_NO_PRUNE` | Skip unused-layer pruning at startup | (off) | `1` |

### Systemd override (persistent)

```sh
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_NUM_PARALLEL=2"
EOF
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

---

## 10. Known Limitations

| Limitation | Impact | Workaround |
|-----------|--------|-----------|
| `/api/version` returns `"0.0.0"` | Cannot version-gate via API | Pin `v0.2.0` by GitHub release tag |
| CPU-only inference | 5–18 tok/s (model-dependent) | Use `llama3.2:1b` or `smollm:135m` in CI |
| `qwen2.5:0.5b` crashes | Model unusable | Use `llama3.2:1b` or `granite3.3:2b` |
| `IQ4_XS` quant fails to load | Model unusable | Use `Q4_K_M` or `Q8_0` |
| `Q2_K` quant is unstable | 1–11 tok/s variance | Avoid in production |
| First inference: +0.5–2 s (byte-swap) + 2–5 s (AIU JIT) | Cold-start latency | Send warm-up request before timed tests |
| Structured output not always valid JSON | Pipeline parse failure | Validate with `jq`; retry once |
| No TLS on Ollama listener | Plaintext traffic | Use nginx/HAProxy for TLS termination |
| `keep_alive: "0"` unload is async | Race condition in tests | Poll `GET /api/ps` until empty |
| Big-endian byte-swap adds load time | Slower cold model load | Expected on s390x; mitigate with `keep_alive: -1` |

---

## 11. Integration Checklist

### Service readiness

- [ ] `curl http://localhost:11434/` returns `Ollama is running` (200 OK)
- [ ] `curl http://localhost:11434/api/tags` returns at least one model
- [ ] `curl http://localhost:11434/api/version` responds (value `0.0.0` is expected)
- [ ] `ollama run llama3.2:1b "ping"` returns a response

### E2E test setup

- [ ] `"stream": false` set on all test requests
- [ ] `"temperature": 0.0` and `"seed": 42` set for deterministic tests
- [ ] `"num_predict": 50`–`100` set to cap CI latency
- [ ] Warm-up request sent before timed assertions
- [ ] Assertions check `"done": true` before reading `.response`
- [ ] HTTP 200 asserted before parsing body
- [ ] `keep_alive: "0"` used at test teardown; `/api/ps` polled to confirm unload

### FFDC pipeline

- [ ] `granite3.3:2b` pulled — `ollama list | grep granite`
- [ ] Structured output prompt validated with `jq .` — confirms parseable JSON
- [ ] `"temperature": 0.0` set for pipeline-safe determinism
- [ ] Retry logic (1 retry) implemented for JSON parse failures
- [ ] `num_ctx` sized to cover longest expected log excerpt
- [ ] Model version recorded in FFDC reports — `ollama show granite3.3:2b | grep -i param`

### Network (if exposing beyond localhost)

- [ ] `OLLAMA_HOST=0.0.0.0:11434` set in systemd override
- [ ] `systemctl daemon-reload && systemctl restart ollama` executed
- [ ] Firewall allows port `11434` from intended test clients only
- [ ] TLS reverse proxy configured before any non-localhost exposure

---

## See Also

- [`docs/handoff.md`](handoff.md) — standalone E2E/FFDC handoff package
- [`docs/api_contract.md`](api_contract.md) — full API reference with all endpoints and schemas
- [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) — tested models, tok/s, RAM
- [`examples/ffdc_prompt_examples.md`](../examples/ffdc_prompt_examples.md) — copy-paste prompt catalog
- [`scripts/install.sh`](../scripts/install.sh) — one-liner installer
- [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) — raw performance benchmarks
