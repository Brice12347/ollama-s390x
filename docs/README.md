# Ollama on IBM Z (s390x) — Documentation

This fork of Ollama ports the local LLM runtime to IBM Z and LinuxONE (s390x architecture).
The guides below follow the article _"Ollama on IBM Z & LinuxONE (s390x): Enabling Local LLM Inference on the Mainframe"_
by Brice Patchou and Justin Veltri (IBM Poughkeepsie, 2026 summer internship).

---

## Step-by-step guides

| # | Guide | What you'll accomplish |
|---|---|---|
| 1 | [Install (one-liner)](1-install.md) | Install Ollama on a bare-metal or VM s390x system in one command |
| 2 | [Build from source](2-build-from-source.md) | Compile Ollama + llama.cpp with endianness patches applied automatically |
| 3 | [Container build](3-container-build.md) | Build and push the UBI 9 s390x image (`Containerfile` / `Dockerfile.kserve`) |
| 4 | [OpenShift AI deploy](4-openshift-deploy.md) | Deploy on zCX OpenShift AI via Deployment or KServe ServingRuntime |
| 5 | [OpenWebUI](5-open-webui.md) | Add a ChatGPT-style UI connected to the s390x Ollama backend |
| 6 | [Endianness fix](6-endianness-fix.md) | Deep-dive: why GGUF byte-swapping is needed and how the patches work |
| 7 | [Model selection](7-models.md) | Compatibility matrix, RAM requirements, and quantization guidance |

---

## Quick reference

**One-line installer (IBM Z / s390x):**
```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

**First model:**
```sh
ollama run smollm:135m "Hello"         # 178 MiB, ~105 tok/s
ollama run granite3.3:2b "What is IBM Z?"  # 1.9 GiB, ~12 tok/s — recommended for enterprise
```

**Health check:**
```sh
curl http://localhost:11434/
# Ollama is running
```

---

## Background

| Document | Description |
|---|---|
| [handoff.md](handoff.md) | E2E / FFDC team integration guide with API contract and example patterns |
| [api_contract.md](api_contract.md) | Full API surface reference for dependent teams |
| [model_compatibility_matrix.md](model_compatibility_matrix.md) | Detailed compatibility matrix (superset of docs/7-models.md) |
| [openshift_feasibility.md](openshift_feasibility.md) | Feasibility report and sizing guidance for OpenShift AI |
| [s390x-big-endian-inference.md](s390x-big-endian-inference.md) | Original engineering notes on the tensor byteswap (superseded by docs/6-endianness-fix.md) |
| [development.md](development.md) | Upstream Ollama build prerequisites and platform notes |

---

## Upstream Ollama documentation

- [Quickstart](https://docs.ollama.com/quickstart)
- [API Reference](https://docs.ollama.com/api)
- [Modelfile Reference](https://docs.ollama.com/modelfile)
- [OpenAI Compatibility](https://docs.ollama.com/api/openai-compatibility)
- [Troubleshooting](https://docs.ollama.com/troubleshooting)
