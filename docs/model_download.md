# Downloading and Using Models on s390x (IBM Z / LinuxONE)

This guide covers everything a new user needs to download, run, and manage AI models with Ollama on IBM Z and LinuxONE hardware.

## Prerequisites

Ollama must be installed. If you have not done that yet:

```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

Then start the server:

```sh
ollama serve
```

---

## Pulling and Running Models

### Basic usage

```sh
# Pull a model
ollama pull llama3.2:1b

# Run it interactively
ollama run llama3.2:1b

# Run with a single prompt
ollama run llama3.2:1b "Explain what IBM Z is in one sentence."
```

### Recommended models for s390x

These models have been tested and confirmed working on IBM Z hardware. Start with these.

| Model | Pull command | RAM required | Notes |
|-------|-------------|-------------|-------|
| SmolLM 135M | `ollama pull smollm:135m` | ~180 MB | Fastest; good for testing |
| SmolLM 360M | `ollama pull smollm:360m` | ~340 MB | Small and fast |
| Llama 3.2 1B | `ollama pull llama3.2:1b` | ~1.5 GB | Best general-purpose starter |
| Granite 3.3 2B | `ollama pull granite3.3:2b` | ~1.9 GB | IBM model; recommended for demos |
| Llama 3.2 3B | `ollama pull llama3.2:3b` | ~2.4 GB | Better quality, needs more RAM |
| Mistral 7B | `ollama pull mistral:7b` | ~4.6 GB | Largest tested; needs 8 GB+ RAM |

> **LinuxONE Community Cloud (4 GB RAM):** Use `smollm:135m`, `smollm:360m`, or `llama3.2:1b` only.  
> **32 GB+ systems (triframe, dedicated VMs):** All models in the table above work.

### IBM Granite — recommended for IBM Z demos

Granite is IBM's own model family, optimized for enterprise use cases:

```sh
ollama pull granite3.3:2b
ollama run granite3.3:2b "Summarize the benefits of IBM Z for enterprise workloads."
```

---

## Quantization Formats

Models come in different quantization formats that trade off quality vs. size vs. speed.

| Format | Quality | Size | Speed | s390x status |
|--------|---------|------|-------|-------------|
| F16 | Best | Largest | Slow | ✅ Working |
| Q8_0 | Very good | Large | Moderate | ✅ Working |
| Q5_K_M | Good | Medium | Good | ✅ Working |
| Q4_K_M | Good | Small | Fast | ✅ Working (default) |
| Q4_0 | Acceptable | Small | Fast | ✅ Working |
| Q2_K | Poor | Smallest | Variable | ⚠️ Unstable (1–11 tok/s variance) |
| IQ4_XS | — | — | — | ❌ Fails |

To pull a specific quantization:

```sh
# Default (Q4_K_M)
ollama pull llama3.2:1b

# Higher quality (Q8_0)
ollama pull llama3.2:1b-instruct-q8_0

# Balanced (Q5_K_M)
ollama pull llama3.2:1b-instruct-q5_k_m

# Full precision (F16) — needs 2× RAM
ollama pull llama3.2:1b-instruct-fp16
```

**Recommendation:** Start with the default `Q4_K_M` tag. It gives the best balance of speed and quality on s390x.

---

## Models That Don't Work

Some models are known to fail on s390x. Do not spend time debugging these:

| Model | Issue |
|-------|-------|
| `qwen2.5:0.5b` | Garbage output and server crash after first inference |
| Any `IQ4_XS` quantization | Fails to load |

---

## Endianness — Why Most Models Just Work

IBM Z is **big-endian**. All GGUF models on Ollama.com and HuggingFace are stored in **little-endian** format.

You do **not** need to convert models manually. The s390x build of Ollama includes big-endian byte-swap patches (`gguf-big-endian-byteswap.patch`) that automatically convert tensors at load time. You will see this in the logs:

```
handle_bigendian_bswap: big-endian host detected with little-endian GGUF; registering per-tensor bswap LoadOps
compat tensor transform: op=little-endian -> big-endian bswap tensor=token_embd.weight ...
```

This is normal and expected — not an error.

---

## Converting Custom Models (Advanced)

If you have a model from HuggingFace that is not on Ollama.com, you can convert it to GGUF and import it.

### Step 1 — Convert to GGUF using llama.cpp

```sh
# Install dependencies
pip install transformers torch

# Clone llama.cpp (use the version bundled with your Ollama build)
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
pip install -r requirements.txt

# Convert a HuggingFace model to GGUF (Q4_K_M)
python convert_hf_to_gguf.py \
    --model path/to/your/model \
    --outtype q4_k_m \
    --outfile model.gguf
```

### Step 2 — Create a Modelfile

```sh
cat > Modelfile << 'EOF'
FROM ./model.gguf
EOF
```

### Step 3 — Import into Ollama

```sh
ollama create my-model -f Modelfile
ollama run my-model "Hello!"
```

> **Note:** Conversion should be done on an x86 or arm64 machine. The resulting GGUF (little-endian) will be automatically byte-swapped when loaded on s390x.

---

## Managing Models

```sh
# List downloaded models
ollama list

# Show model details
ollama show llama3.2:1b

# Remove a model
ollama rm llama3.2:1b

# Check how much disk space models are using
du -sh ~/.ollama/models/
```

---

## Checking Inference is Working

After `ollama serve` is running:

```sh
# Quick health check
curl http://localhost:11434/api/tags

# Run a test generation
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2:1b",
  "prompt": "Say hello.",
  "stream": false
}'
```

---

## Troubleshooting

### `llama-server process has terminated: exit status 127`

The shared libraries are not registered with the system linker. Fix:

```sh
sudo bash -c '
  cd /usr/local/lib/ollama
  for f in *.so; do ln -sf "$f" "${f}.0"; done
  echo "/usr/local/lib/ollama" > /etc/ld.so.conf.d/ollama.conf
  ldconfig
'
sudo systemctl restart ollama
```

### `version 0.0.0` shown in logs

This is a known issue with dev builds from source. Inference still works correctly — the version string is not injected at build time.

### `llama-server --list-devices failed`

This is benign on s390x. There are no GPU devices to enumerate; Ollama falls back to CPU mode automatically.

### Model output is garbled / server crashes

Check the [known incompatible models](#models-that-dont-work) list. `qwen2.5:0.5b` and `IQ4_XS` quantizations are known to fail.

---

## See Also

- [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) — full benchmark results with tok/s and RAM usage
- [`docs/gguf_s390x_notes.md`](gguf_s390x_notes.md) — deep dive on GGUF endianness and quantization formats
- [`scripts/install.sh`](../scripts/install.sh) — one-liner installer
