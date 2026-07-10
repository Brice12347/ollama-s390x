# Ollama s390x — API Contract & Integration Guide

**Audience:** E2E test teams, FFDC integration teams, dependent service owners  
**Base URL:** `http://127.0.0.1:11434` (local) or `http://<host>:11434` (network)  
**Protocol:** HTTP/1.1, JSON request/response bodies  
**Auth:** None (unauthenticated by default; network exposure controlled by `OLLAMA_HOST`)  
**Content-Type:** `application/json` on all POST requests

---

## Table of Contents

1. [Health Check](#1-health-check)
2. [List Available Models](#2-list-available-models)
3. [Generate Completion](#3-generate-completion)
4. [Chat Completion](#4-chat-completion)
5. [Structured Output (JSON Schema)](#5-structured-output-json-schema)
6. [Show Model Info](#6-show-model-info)
7. [Pull a Model](#7-pull-a-model)
8. [Generate Embeddings](#8-generate-embeddings)
9. [List Running Models](#9-list-running-models)
10. [Version](#10-version)
11. [Additional Endpoints](#11-additional-endpoints)
12. [OpenAI-Compatible Endpoint](#12-openai-compatible-endpoint)
13. [Error Responses](#13-error-responses)
14. [FFDC-Style Prompts](#14-ffdc-style-prompts)
15. [Known Limitations on s390x](#15-known-limitations-on-s390x)
16. [Integration Checklist](#16-integration-checklist)

---

## 1. Health Check

Verify the server is up before sending requests.

```sh
curl -s http://localhost:11434/
```

**Expected response:**
```
Ollama is running
```

**HTTP status:** `200 OK`

---

## 2. List Available Models

```sh
curl -s http://localhost:11434/api/tags | jq .
```

**Response schema:**
```json
{
  "models": [
    {
      "name": "llama3.2:1b",
      "model": "llama3.2:1b",
      "modified_at": "2026-07-10T12:00:00Z",
      "size": 1321205248,
      "digest": "sha256:74701a8c35f6...",
      "details": {
        "parent_model": "",
        "format": "gguf",
        "family": "llama",
        "families": ["llama"],
        "parameter_size": "1.2B",
        "quantization_level": "Q4_K_M"
      }
    }
  ]
}
```

---

## 3. Generate Completion

```
POST /api/generate
```

### Non-streaming (recommended for E2E tests)

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "What is IBM Z?",
    "stream": false
  }' | jq .response
```

**Response schema:**
```json
{
  "model": "llama3.2:1b",
  "created_at": "2026-07-10T12:00:00Z",
  "response": "IBM Z is a family of mainframe computers...",
  "done": true,
  "done_reason": "stop",
  "context": [1, 2, 3],
  "total_duration": 4500000000,
  "load_duration": 500000000,
  "prompt_eval_count": 8,
  "prompt_eval_duration": 200000000,
  "eval_count": 42,
  "eval_duration": 3800000000
}
```

> **Note:** All durations are in nanoseconds.  
> **tok/s formula:** `eval_count / eval_duration * 1_000_000_000`

### Streaming

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "What is IBM Z?",
    "stream": true
  }'
```

Returns newline-delimited JSON objects. Each chunk has `"done": false`. The final object has `"done": true` and includes the full timing stats.

### Key parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `model` | string | required | Model name e.g. `llama3.2:1b` |
| `prompt` | string | required | Input prompt |
| `stream` | bool | `true` | Set `false` for single JSON response |
| `format` | string \| object | — | `"json"` for JSON mode, or a JSON schema object for structured output |
| `system` | string | — | Override the system prompt defined in the Modelfile |
| `keep_alive` | string | `"5m"` | How long to keep model loaded after request (e.g. `"0"` to unload immediately, `"-1"` to keep forever) |
| `options.temperature` | float | `0.8` | Sampling temperature (0 = deterministic) |
| `options.num_predict` | int | `-1` | Max tokens to generate (-1 = unlimited) |
| `options.num_ctx` | int | `2048` | Context window size in tokens |
| `options.seed` | int | `0` | Random seed for reproducible output |
| `options.stop` | string[] | — | Stop sequences that halt generation |
| `options.top_k` | int | `40` | Limits next-token selection to top K |
| `options.top_p` | float | `0.9` | Nucleus sampling threshold |

---

## 4. Chat Completion

```
POST /api/chat
```

### Non-streaming

```sh
curl -s http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "messages": [
      { "role": "user", "content": "Summarize what Ollama does in one sentence." }
    ],
    "stream": false
  }' | jq .message.content
```

### Multi-turn conversation

```sh
curl -s http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "messages": [
      { "role": "system", "content": "You are a helpful IBM Z assistant." },
      { "role": "user",   "content": "What workloads run well on IBM Z?" },
      { "role": "assistant", "content": "IBM Z excels at transaction processing, databases, and security workloads." },
      { "role": "user",   "content": "Can it run AI inference too?" }
    ],
    "stream": false
  }' | jq .message.content
```

**Response schema:**
```json
{
  "model": "llama3.2:1b",
  "created_at": "2026-07-10T12:00:00Z",
  "message": {
    "role": "assistant",
    "content": "Ollama makes it easy to run large language models locally."
  },
  "done": true,
  "done_reason": "stop",
  "total_duration": 3200000000,
  "eval_count": 18,
  "eval_duration": 2900000000
}
```

### Key parameters

Accepts all the same `options` and `keep_alive` fields as `/api/generate`. The `messages` array supports roles `system`, `user`, and `assistant`.

---

## 5. Structured Output (JSON Schema)

Use the `format` parameter to constrain the model response to a specific JSON structure. This is the recommended approach for FFDC log parsing where machine-readable output is required.

### JSON mode (`"format": "json"`)

Forces output to be valid JSON. Instruct the model in the prompt to produce JSON.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Extract the error code and ASID from this log entry and return as JSON. Log: IEA995I SYMPTOM DUMP TIME=14.23.41 ASID=00AF REASON CODE=0C4",
    "format": "json",
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq .response | jq -r . | jq .
```

**Example output:**
```json
{
  "error_code": "0C4",
  "asid": "00AF",
  "time": "14.23.41"
}
```

### Structured output with JSON schema

Pass a JSON schema object as `format` to enforce exact field names and types:

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Analyze this log entry: IEA995I SYMPTOM DUMP TIME=14.23.41 ASID=00AF REASON CODE=0C4. Fill in all fields.",
    "format": {
      "type": "object",
      "properties": {
        "error_code":   { "type": "string" },
        "asid":         { "type": "string" },
        "severity":     { "type": "string", "enum": ["LOW", "MEDIUM", "HIGH", "CRITICAL"] },
        "description":  { "type": "string" },
        "action":       { "type": "string" }
      },
      "required": ["error_code", "asid", "severity", "description", "action"]
    },
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq .response | jq -r . | jq .
```

**Example output:**
```json
{
  "error_code": "0C4",
  "asid": "00AF",
  "severity": "HIGH",
  "description": "Protection exception — program attempted to access storage it does not own.",
  "action": "Review memory access patterns in ASID 00AF around address 00123456."
}
```

> **Note:** Structured output requires `stream: false`. Not all models follow schemas reliably at low temperatures — validate output before parsing.

---

## 6. Show Model Info

```sh
curl -s http://localhost:11434/api/show \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:1b"}' | jq '{family: .details.family, params: .details.parameter_size, quant: .details.quantization_level}'
```

Returns full model metadata including the Modelfile, template, parameters, and model card.

---

## 7. Pull a Model

```sh
curl -s http://localhost:11434/api/pull \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:1b", "stream": false}' | jq .status
```

Returns `"success"` when complete. Use `"stream": true` (default) to observe download progress:

```sh
curl -s http://localhost:11434/api/pull \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:1b"}' | grep '"status"'
```

---

## 8. Generate Embeddings

```
POST /api/embed
```

```sh
curl -s http://localhost:11434/api/embed \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "input": "IBM Z is a mainframe architecture."
  }' | jq '.embeddings[0] | length'
```

Batch input is also supported:

```sh
curl -s http://localhost:11434/api/embed \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "input": [
      "IBM Z is a mainframe architecture.",
      "LinuxONE runs Linux on IBM Z hardware."
    ]
  }' | jq '.embeddings | length'
```

**Response schema:**
```json
{
  "model": "llama3.2:1b",
  "embeddings": [[0.123, -0.456, ...]],
  "total_duration": 120000000,
  "prompt_eval_count": 8
}
```

---

## 9. List Running Models

```sh
curl -s http://localhost:11434/api/ps | jq .
```

Returns currently loaded models and their memory usage. Empty when no inference is active. Useful in E2E tests to assert model unload after `keep_alive: "0"`.

---

## 10. Version

```sh
curl -s http://localhost:11434/api/version | jq .
```

**Response:**
```json
{ "version": "0.0.0" }
```

> **s390x note:** Dev builds from source always return `"0.0.0"`. This is cosmetic — inference is unaffected. Pin the release tag (`v0.2.0`) from the GitHub release metadata instead of relying on this endpoint.

---

## 11. Additional Endpoints

These endpoints follow the same base URL pattern and are available but not the primary integration surface for E2E/FFDC use.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/copy` | Copy a model to a new name |
| `DELETE` | `/api/delete` | Delete a model |
| `POST` | `/api/push` | Push a model to the Ollama registry |
| `HEAD` | `/api/blobs/:digest` | Check if a blob exists |
| `POST` | `/api/blobs/:digest` | Push a raw blob |
| `POST` | `/api/create` | Create a model from a Modelfile |

### Delete example

```sh
curl -s -X DELETE http://localhost:11434/api/delete \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3.2:1b"}'
```

Returns HTTP `200` with empty body on success.

### Copy example

```sh
curl -s http://localhost:11434/api/copy \
  -H "Content-Type: application/json" \
  -d '{"source": "llama3.2:1b", "destination": "llama3.2:1b-test"}'
```

---

## 12. OpenAI-Compatible Endpoint

Ollama exposes an OpenAI-compatible chat completions endpoint. Teams already using the OpenAI Python SDK or `openai`-compatible HTTP clients can point them at Ollama without code changes.

```
POST /v1/chat/completions
```

```sh
curl -s http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ollama" \
  -d '{
    "model": "granite3.3:2b",
    "messages": [
      { "role": "user", "content": "What is IBM Z?" }
    ]
  }' | jq .choices[0].message.content
```

**Response shape** follows the OpenAI chat completions spec (`choices[].message.content`, `usage.total_tokens`, etc.).

**Python SDK example:**

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")

response = client.chat.completions.create(
    model="granite3.3:2b",
    messages=[{"role": "user", "content": "What is IBM Z?"}],
)
print(response.choices[0].message.content)
```

---

## 13. Error Responses

All error responses use standard HTTP status codes with a JSON body:

```json
{ "error": "model 'doesnotexist' not found, try pulling it first" }
```

| HTTP Status | Meaning |
|-------------|---------|
| `200 OK` | Success |
| `400 Bad Request` | Malformed JSON or missing required fields |
| `404 Not Found` | Model not found (needs `ollama pull`) |
| `500 Internal Server Error` | llama-server crash or out-of-memory |

### Common error: model not loaded

```sh
# Triggers 404
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model": "notamodel", "prompt": "hi", "stream": false}'
# {"error":"model 'notamodel' not found, try pulling it first"}
```

### Checking server stderr for crashes

On s390x, OOM or model-crash errors appear in the systemd journal:

```sh
journalctl -u ollama -n 50 --no-pager
```

---

## 14. FFDC-Style Prompts

These prompts are designed for First Failure Data Capture (FFDC) and log analysis use cases on IBM Z. Recommended model: `granite3.3:2b` (IBM model, tuned for enterprise text, best structured-output compliance on s390x).

### Log anomaly detection

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Analyze this IBM Z system log entry and identify the error type and likely cause:\n\nIEA995I SYMPTOM DUMP OUTPUT\n  TIME=14.23.41 SEQ=03271 CPU=0000 ASID=00AF\n  PSW AT TIME OF ERROR  078D1000 80000000  00000000 00123456\n  REASON CODE = 0C4\n\nProvide: 1) Error type 2) Likely cause 3) Recommended action",
    "stream": false,
    "options": { "temperature": 0.1 }
  }' | jq .response
```

### Structured log parsing (recommended for FFDC pipelines)

Returns machine-readable JSON directly from the model — no post-processing regex needed:

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

**Example output:**
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

### Incident summary generation

```sh
curl -s http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "messages": [
      {
        "role": "system",
        "content": "You are an IBM Z systems expert. Generate concise FFDC incident summaries from log data. Be precise and technical."
      },
      {
        "role": "user",
        "content": "Generate a 3-line incident summary for: System experienced 47 abend S0C4 events between 14:20 and 14:35. Affected ASID 00AF. Memory address 00123456 not accessible. LPAR utilization was at 98% during the event window."
      }
    ],
    "stream": false,
    "options": { "temperature": 0.1, "seed": 42 }
  }' | jq .message.content
```

### Root cause analysis

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Given these IBM Z performance metrics, identify the bottleneck and suggest remediation:\n\nCPU utilization: 94%\nMemory utilization: 87%\nI/O wait: 42%\nPage faults/sec: 1200\nTransaction response time: 8.3s (SLA: 2.0s)\n\nAnalyze and recommend.",
    "stream": false,
    "options": { "temperature": 0.0 }
  }' | jq .response
```

### Context window — handling long logs

For log excerpts longer than a few hundred lines, increase `num_ctx`. The default is 2048 tokens. Each log line is roughly 20–40 tokens.

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite3.3:2b",
    "prompt": "Summarize the following z/OS job log and identify any errors:\n\n<paste log here>",
    "stream": false,
    "options": {
      "temperature": 0.1,
      "num_ctx": 8192,
      "num_predict": 512
    }
  }' | jq .response
```

> **RAM impact:** Doubling `num_ctx` roughly doubles the KV-cache size. For `granite3.3:2b` at `num_ctx=8192` expect ~3.5 GB RSS on s390x.

### Deterministic outputs for regression testing

For E2E tests that need reproducible outputs, set `temperature: 0` and a fixed `seed`:

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.2:1b",
    "prompt": "Reply with exactly: OK",
    "stream": false,
    "options": {
      "temperature": 0.0,
      "seed": 1,
      "num_predict": 5
    }
  }' | jq .response
```

---

## 15. Known Limitations on s390x

| Limitation | Impact | Workaround |
|-----------|--------|-----------|
| `version` endpoint returns `"0.0.0"` | Cosmetic only | Pin release tag from GitHub release metadata |
| `llama-server --list-devices` exits 127 | Logged as warning at startup | Benign; CPU fallback is automatic |
| No GPU acceleration (CPU-only) | Lower tok/s vs x86+GPU | Use smaller models; VXE2 SIMD is active |
| `qwen2.5:0.5b` crashes after first inference | Model unusable | Use `llama3.2:1b` or `granite3.3:2b` instead |
| `IQ4_XS` quantization fails to load | Model unusable | Use `Q4_K_M` or `Q8_0` instead |
| `Q2_K` quantization is unstable | Variable 1–11 tok/s | Avoid for production; use `Q4_K_M` |
| Big-endian byte-swap at load time | ~0.5–2s extra load on first run | Expected; subsequent loads use cached tensors |
| No TLS on the Ollama listener | Plaintext on the wire | Use nginx/HAProxy for TLS termination |
| Structured output compliance varies by model | JSON may not always be valid | Validate with `jq` before parsing; retry once |
| `keep_alive: "0"` unload is async | `/api/ps` may still show model briefly | Poll `/api/ps` until empty before asserting unload |

### Performance reference (s390x z15, CPU-only)

| Model | Quantization | tok/s | RAM |
|-------|-------------|-------|-----|
| SmolLM 135M | Q4_0 | 104.6 | 178 MiB |
| SmolLM 360M | Q4_0 | 77.9 | 340 MiB |
| Llama 3.2 1B | Q4_K_M | 17.6 | 1.5 GiB |
| Llama 3.2 1B | Q8_0 | 22.75 | 1.5 GiB |
| Granite 3.3 2B | Q4_K_M | 12.25 | 1.9 GiB |
| Llama 3.2 3B | Q4_K_M | 12.2 | 2.4 GiB |
| Mistral 7B | Q4_K_M | 5.8 | 4.6 GiB |

---

## 16. Integration Checklist

Use this checklist before handing off to a dependent team.

### Server readiness

- [ ] `curl http://localhost:11434/` returns `Ollama is running`
- [ ] `curl http://localhost:11434/api/tags` returns at least one model
- [ ] `curl http://localhost:11434/api/version` responds (value `0.0.0` is expected on s390x)
- [ ] `ollama run llama3.2:1b "ping"` returns a response

### E2E test setup

- [ ] Use `"stream": false` for all test assertions
- [ ] Use `"options": {"temperature": 0.0, "seed": 42}` for deterministic outputs
- [ ] Use `"options": {"num_predict": 50}` to cap response length in tests
- [ ] Assert on `"done": true` in response before reading `.response`
- [ ] Assert HTTP `200` before parsing body
- [ ] Use `keep_alive: "0"` after test runs to free memory between test cases

### FFDC integration

- [ ] Confirm model `granite3.3:2b` is pulled — `ollama list | grep granite`
- [ ] Validate structured output prompt returns parseable JSON — pipe through `jq .`
- [ ] Test with `"temperature": 0.0` and `"format": "json"` for pipeline-safe output
- [ ] Record model version used in FFDC reports — `ollama show granite3.3:2b | grep -i param`
- [ ] Set `num_ctx` to cover your longest expected log excerpt (default 2048 tokens ≈ ~100 log lines)

### Network access (if exposing beyond localhost)

- [ ] Set `OLLAMA_HOST=0.0.0.0` in the systemd service environment (`/etc/systemd/system/ollama.service.d/override.conf`)
- [ ] Reload: `systemctl daemon-reload && systemctl restart ollama`
- [ ] Firewall rules allow port `11434` from intended clients only
- [ ] Use a reverse proxy for TLS termination before exposing to other teams

---

## See Also

- [`docs/handoff.md`](handoff.md) — standalone handoff package for the E2E/FFDC team
- [`docs/model_download.md`](model_download.md) — how to pull and manage models
- [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) — tested models and benchmark data
- [`scripts/install.sh`](../scripts/install.sh) — one-liner installer
- [Ollama API reference](https://docs.ollama.com/api) — full upstream API docs
- [`docs/openapi.yaml`](openapi.yaml) — machine-readable OpenAPI 3.1 spec
