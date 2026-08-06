# Step 9 — Replication from a Clean Machine

Start here if you have never touched this project before.
Pick one path and follow it top to bottom. Each step has a checkpoint — an expected output
that confirms the step worked before you move on.

---

## Which path?

| Path | Time | When to use |
|---|---|---|
| [A — One-liner install](#path-a--one-liner-install) | ~15 min | You have an s390x VM and just want Ollama running |
| [B — Build from source](#path-b--build-from-source) | ~60 min | You need to modify the code or can't use the pre-built binary |
| [C — OpenShift AI deploy](#path-c--openshift-ai-deploy) | ~30 min | You want Ollama running as a KServe InferenceService on a cluster |
| [D — Add OpenWebUI](#path-d--add-openwebui) | ~10 min | You have Path C running and want a chat UI |

---

## Prerequisites (all paths)

- An IBM Z / LinuxONE system running **Ubuntu 22.04** or **Debian 12** (`s390x`)
- At minimum **4 GiB RAM** (8 GiB recommended for 2B+ models)
- Outbound HTTPS access to `github.com` and `ollama.com`
- You are logged in as a user with `sudo` access

Check your architecture first:
```sh
uname -m
# Must print: s390x
```

---

## Path A — One-liner install

### Step 1 — Install

```sh
curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/install.sh | sh
```

**Checkpoint:** You should see output ending with:
```
>>> The Ollama API is now available at 127.0.0.1:11434.
>>> Install complete. Run "ollama" from the command line.
```

If you see `curl: command not found`, install it first: `sudo apt install -y curl`

---

### Step 2 — Verify the service is running

```sh
systemctl status ollama
```

**Checkpoint:** Status should show `active (running)`.

```sh
curl http://localhost:11434/
```

**Checkpoint:** Response should be exactly: `Ollama is running`

If the service failed to start:
```sh
journalctl -u ollama -n 30 --no-pager
```

---

### Step 3 — Pull a model

```sh
ollama pull smollm:135m
```

This downloads ~89 MiB. Takes 1–2 minutes on a typical connection.

**Checkpoint:**
```sh
ollama list
# Should show: smollm:135m
```

---

### Step 4 — Run inference

```sh
ollama run smollm:135m "What is IBM Z?"
```

**Checkpoint:** You should receive a coherent text response — not dots (`......`) and not silence.
The first response after a cold start takes **5–6 minutes** while the model byte-swaps from
LE→BE. Subsequent responses on the same loaded model are fast (~105 tok/s).

If you get dots or garbage output, the byteswap patch is not active — the binary was not
built from this repo. Uninstall and reinstall using the URL above.

---

### Step 5 — Verify via API

```sh
curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"smollm:135m","prompt":"Reply with the word OK","stream":false,"options":{"temperature":0,"seed":1,"num_predict":5}}' \
  | jq .response
```

**Checkpoint:** Response contains `"OK"` (may have surrounding whitespace).

Path A complete. ✅

---

## Path B — Build from source

### Step 1 — Install dependencies

```sh
sudo apt update && sudo apt install -y \
  build-essential cmake ninja-build git \
  golang-go libopenblas-dev
```

**Checkpoint:**
```sh
cmake --version   # must be ≥ 3.24
go version        # must be ≥ go1.22
gcc --version     # must be ≥ 11
```

---

### Step 2 — Clone the repo

```sh
git clone https://github.com/Brice12347/ollama-s390x.git
cd ollama-s390x
```

---

### Step 3 — Build

```sh
cmake -B build .
cmake --build build --parallel 8
```

This takes **30–50 minutes** on a typical s390x VM. CMake fetches llama.cpp at the pinned
commit and applies the three endianness patches automatically during configure.

**Checkpoint:** Build ends with a line like:
```
[100%] Linking CXX executable llama-server
```
And the `ollama` binary exists in the repo root:
```sh
ls -lh ./ollama
```

---

### Step 4 — Start the server

```sh
./ollama serve &
```

**Checkpoint:** You should see startup logs. Pull and run a model:
```sh
./ollama pull smollm:135m
./ollama run smollm:135m "What is IBM Z?"
```

When the model loads, look for this line in the server output:
```
compat patch disabled mmap for transformed text tensors
```

**This line confirms the byteswap path is active.** If you don't see it, the patches
did not apply — check `cmake -B build .` output for patch errors.

Path B complete. ✅

---

## Path C — OpenShift AI deploy

### Prerequisites

- `oc` CLI installed and logged into your cluster
- `podman` 4.0+ installed
- A [quay.io](https://quay.io) account with a public repository created
- The cluster has a `project-ollama` namespace (or substitute your own throughout)

---

### Step 1 — Log in and create the namespace

```sh
oc login --token=<YOUR_TOKEN> --server=<YOUR_SERVER>
oc new-project project-ollama
```

**Checkpoint:**
```sh
oc project
# Should print: Using project "project-ollama"
```

---

### Step 2 — Build and push the container image

From the repo root on an **s390x machine** (or with QEMU cross-build):

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  -f Dockerfile.kserve \
  -t quay.io/<your-quay-username>/ollama-s390x:kserve \
  .
```

This takes **45–90 minutes** on CPU.

```sh
podman login quay.io
podman push quay.io/<your-quay-username>/ollama-s390x:kserve
```

**Checkpoint:**
```sh
podman run --rm \
  -e OLLAMA_HOST=0.0.0.0:11434 \
  quay.io/<your-quay-username>/ollama-s390x:kserve \
  /usr/bin/ollama --version
# Should print a version string without error
```

Make the repository **public** in the quay.io web UI before continuing.

---

### Step 3 — Update the image reference

Edit [`ollama-servingruntime.yaml`](../ollama-servingruntime.yaml) — replace the image on line 25:

```yaml
image: quay.io/<your-quay-username>/ollama-s390x:kserve
```

---

### Step 4 — Create the PVC

```sh
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: project-ollama
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
EOF
```

**Checkpoint:**
```sh
oc get pvc -n project-ollama
# STATUS should be Bound (may take a moment)
```

---

### Step 5 — Apply ServingRuntime then InferenceService

```sh
oc apply -f ollama-servingruntime.yaml
oc apply -f ollama-inferenceservice.yaml
```

**Checkpoint:**
```sh
oc get pods -n project-ollama -w
# Wait until you see a pod named ollama-predictor-predictor-* with STATUS Running
```

This can take **3–5 minutes** for the pod to start (image pull + startup).

---

### Step 6 — Pull a model into the pod

```sh
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama pull smollm:135m
```

**Checkpoint:**
```sh
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama list
# Should show smollm:135m
```

---

### Step 7 — Verify inference

```sh
# Port-forward to test locally
oc port-forward -n project-ollama svc/ollama-predictor-predictor 11434:11434 &

curl -s http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"smollm:135m","prompt":"What is IBM Z?","stream":false}' \
  | jq .response
```

**Checkpoint:** Coherent text response. First call after a cold start takes ~5–6 minutes.

Path C complete. ✅

---

## Path D — Add OpenWebUI

Requires Path C to be running first.

### Step 1 — Generate a secret key

```sh
python3 -c "import secrets; print(secrets.token_hex(32))"
```

Copy the output. You'll need it in the next step.

---

### Step 2 — Set the secret key in the deployment manifest

Edit [`open-webui-deployment.yaml`](../open-webui-deployment.yaml) — find `REPLACE_WITH_GENERATED_SECRET`
and replace it with the value you just generated.

Also update the image tag if you built your own:
```yaml
image: quay.io/<your-quay-username>/open-webui:s390x-v25
```

---

### Step 3 — Deploy

```sh
oc apply -f open-webui-deployment.yaml
```

**Checkpoint:**
```sh
oc get pods -l app=open-webui -n project-ollama -w
# Wait for Running
```

---

### Step 4 — Get the URL

```sh
oc get route open-webui -n project-ollama
# Copy the HOST value
```

Open `https://<HOST>` in a browser.

**Checkpoint:** You should see the OpenWebUI login page. Create an account — the first
account becomes admin. Select `smollm:135m` from the model picker and send a message.

> **Note:** The first message after a cold start will take ~5–6 minutes before any
> response appears. This is normal — the model is byte-swapping on load. Subsequent
> messages are fast. Do not refresh the page.

Path D complete. ✅

---

## If something goes wrong

| Symptom | Where to look |
|---|---|
| Model output is dots `......` or garbage | Byteswap not active — binary not from this repo. See [docs/6-endianness-fix.md](6-endianness-fix.md) |
| `exit status 127` on model load | Shared libraries not found. See `journalctl -u ollama` and [docs/1-install.md](1-install.md) uninstall/reinstall |
| First response takes 5+ minutes | Expected — this is the LE→BE byte-swap. Not a bug. Set `OLLAMA_KEEP_ALIVE=-1` |
| Pod stuck in `Pending` | PVC not bound or image pull failing. Check `oc describe pod <name> -n project-ollama` |
| Pod stuck in `CrashLoopBackOff` | Usually a permission error on `/home/ollama`. Check `oc logs <pod> -n project-ollama` — look for "permission denied" |
| OpenWebUI shows "Connection error" | `OLLAMA_BASE_URL` namespace segment wrong, or Ollama pod not ready yet. Check the URL in the deployment YAML |
| OpenWebUI times out on first message | HAProxy route timeout too short. Confirm the Route has `haproxy.router.openshift.io/timeout: 30m` |
| `qwen2.5:0.5b` crashes the server | Known broken model on s390x. Use `granite3.3:2b` or `llama3.2:1b` instead. See [docs/7-models.md](7-models.md) |
