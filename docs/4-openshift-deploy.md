# Step 4 — Deploy Ollama on zCX OpenShift AI

Two deployment paths are covered:

- **Path A — Deployment** (quick experimentation, easy to iterate)
- **Path B — KServe ServingRuntime + InferenceService** (production integration with OpenShift AI dashboard)

Both paths were validated during the 2026 summer internship on a `zCX` OpenShift AI cluster running IBM Z (s390x) hardware.

---

## Prerequisites

- Access to a zCX OpenShift AI cluster with privileges to create Projects, PVCs, Deployments, ServingRuntimes, InferenceServices, and Routes
- OpenShift CLI (`oc`) installed and authenticated
- An s390x container image built and pushed per [docs/3-container-build.md](3-container-build.md):
  `quay.io/<your-org>/ollama-s390x:kserve`

---

## 1. Log in and create a project

```sh
oc login --token=<YOUR_TOKEN> --server=<YOUR_SERVER>
oc new-project project-ollama
```

---

## 2. Create persistent storage

Ollama requires a writable directory for its model store. Under OpenShift's restricted SCC the container cannot write to arbitrary paths — a PVC is mandatory.

```yaml
# ollama-pvc.yaml
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
```

```sh
oc apply -f ollama-pvc.yaml
oc get pvc -n project-ollama
```

> **Shared NFS tip:** If your cluster has a pre-provisioned shared NFS PVC, skip creating a dedicated one. Mount a `subPath` of the shared volume instead (see the KServe manifests below).

---

## Path A — Deployment (quick start)

This approach works for initial experimentation and for connecting OpenWebUI before committing to the full KServe path.

**Key s390x decisions encoded in this manifest:**

- Both `HOME` and `OLLAMA_MODELS` point to the PVC mount. Ollama derives its data directory from `os/user.Current().HomeDir`. If `HOME` points to a read-only location the process fails silently with a permission-denied error — even when `OLLAMA_MODELS` is set correctly.
- `OLLAMA_LOAD_TIMEOUT=30m` — GGUF byte-swap on cold start takes 5–6 minutes for a 135M model on CPU-only s390x.
- Generous `initialDelaySeconds` on probes — CPU-only inference on s390x is considerably slower than GPU nodes.

```yaml
# ollama-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: project-ollama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
        - name: ollama
          image: quay.io/<your-org>/ollama-s390x:kserve
          ports:
            - containerPort: 11434
              name: http
          env:
            - name: HOME
              value: /models
            - name: OLLAMA_MODELS
              value: /models
            - name: OLLAMA_HOST
              value: "0.0.0.0:11434"
            - name: OLLAMA_KEEP_ALIVE
              value: "-1"
            - name: OLLAMA_LOAD_TIMEOUT
              value: "30m"
          volumeMounts:
            - name: models
              mountPath: /models
          resources:
            requests:
              cpu: "2"
              memory: 8Gi
            limits:
              memory: 24Gi
          readinessProbe:
            httpGet:
              path: /
              port: 11434
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /
              port: 11434
            initialDelaySeconds: 60
            periodSeconds: 20
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: project-ollama
spec:
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
      name: http
```

```sh
oc apply -f ollama-deployment.yaml
oc get pods -n project-ollama -w
```

Pull a model once the pod is `Running`:

```sh
oc exec -it deploy/ollama -n project-ollama -- ollama pull smollm:135m
oc exec -it deploy/ollama -n project-ollama -- ollama list
```

---

## Path B — KServe ServingRuntime + InferenceService

This is the production path, integrating Ollama directly with OpenShift AI's model serving layer.

### ServingRuntime

This manifest registers Ollama as a named runtime inside the OpenShift AI dashboard.

**s390x-specific decisions:**

- An `initContainer` running as root corrects `/home/ollama` permissions before the main container starts. OpenShift's arbitrary-UID SCC can assign a UID that has no write access to the directory created by `useradd` inside the image.
- `OLLAMA_LOAD_TIMEOUT=30m` — accommodates the LE→BE byte-swap on every cold load.
- `OLLAMA_NUM_PARALLEL=1` and `OLLAMA_MAX_LOADED_MODELS=1` — prevent concurrent model slots from exhausting CPU memory on a typical LPAR.
- `OPENBLAS_NUM_THREADS=8` and `OMP_NUM_THREADS=8` — dedicate all cores to a single request.

```yaml
# ollama-servingruntime.yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: ollama
  namespace: project-ollama
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: "Ollama on s390x CPU inference only"
    opendatahub.io/recommended-accelerators: '[]'
    enable-route: "false"
    enable-auth: "false"
spec:
  builtInAdapter:
    modelLoadingTimeoutMillis: 90000
  initContainers:
    - name: fix-home-perms
      image: registry.redhat.io/ubi9/ubi-minimal:latest
      command: ["sh", "-c", "chmod -R g=u /home/ollama && chown -R :0 /home/ollama"]
      securityContext:
        runAsUser: 0
      volumeMounts: []
  containers:
    - name: kserve-container
      image: quay.io/<your-org>/ollama-s390x:kserve
      env:
        - name: HOME
          value: "/home/ollama"
        - name: OLLAMA_MODELS
          value: "/home/ollama/.ollama/models"
        - name: OLLAMA_HOST
          value: "0.0.0.0:11434"
        - name: OLLAMA_KEEP_ALIVE
          value: "-1"
        - name: OLLAMA_LOAD_TIMEOUT
          value: "30m"
        - name: OLLAMA_NUM_PARALLEL
          value: "1"
        - name: OLLAMA_MAX_LOADED_MODELS
          value: "1"
        - name: OPENBLAS_NUM_THREADS
          value: "8"
        - name: OMP_NUM_THREADS
          value: "8"
      ports:
        - containerPort: 11434
          name: http1
          protocol: TCP
  multiModel: false
  supportedModelFormats:
    - autoSelect: true
      name: any
```

```sh
oc apply -f ollama-servingruntime.yaml
```

### InferenceService

**s390x-specific decisions:**

- `serving.kserve.io/deploymentMode: RawDeployment` — bypasses the serverless Knative path, which scales pods to zero and compounds byte-swap cold-start latency. RawDeployment keeps the pod alive and pairs with `OLLAMA_KEEP_ALIVE=-1`.
- No `storageUri` — KServe mounts `storageUri` as a **read-only** volume, which prevents Ollama from writing its key and config files. Models are pulled manually via `oc exec` after the pod is running.
- `runAsUser: 10001` — matches the `useradd -u 10001` in `Dockerfile.kserve`. Without this, OpenShift's arbitrary-UID SCC assigns a random UID with no write access to `/home/ollama`.

```yaml
# ollama-inferenceservice.yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ollama-predictor
  namespace: project-ollama
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
  labels:
    opendatahub.io/dashboard: "true"
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 1
    podSpec:
      securityContext:
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
    model:
      modelFormat:
        name: any
      runtime: ollama
      resources:
        requests:
          cpu: "500m"
          memory: "2Gi"
        limits:
          cpu: "4"
          memory: "4Gi"
```

```sh
oc apply -f ollama-inferenceservice.yaml
oc get inferenceservice -n project-ollama -w
```

> **Injecting environment variables after deploy:** The KServe webhook forbids mixing `spec.predictor.containers` with `spec.predictor.model`. To add or override environment variables post-deploy:
> ```sh
> oc set env deployment/ollama-predictor-predictor -c kserve-container \
>   OLLAMA_LOAD_TIMEOUT=30m OLLAMA_KEEP_ALIVE=-1 OLLAMA_MODELS=/mnt/models \
>   -n project-ollama
> ```

---

## 3. Verify and pull a model

```sh
# Wait until Running
oc get pods -n project-ollama -w

# Optional: port-forward for local testing
oc port-forward svc/ollama 11434:11434 -n project-ollama

# Smoke test
curl http://localhost:11434/
# Expected: Ollama is running

# Pull a model — Deployment path
oc exec -it deploy/ollama -n project-ollama -- ollama pull smollm:135m
oc exec -it deploy/ollama -n project-ollama -- ollama list

# Pull a model — KServe path
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama pull smollm:135m
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama list
```

---

## 4. Call the model

**curl (Ollama-native):**
```sh
curl -s https://<route>/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"smollm:135m","prompt":"What is IBM Z?","stream":false}' \
  | jq .response
```

**Python (OpenAI-compatible):**
```python
from openai import OpenAI

client = OpenAI(base_url="https://<route>/v1", api_key="ollama")
response = client.chat.completions.create(
    model="smollm:135m",
    messages=[{"role": "user", "content": "What is IBM Z?"}],
)
print(response.choices[0].message.content)
```

**From a Jupyter Workbench (internal service DNS):**
```python
import requests

resp = requests.post(
    "http://ollama-predictor-predictor.project-ollama.svc.cluster.local:11434/api/generate",
    json={"model": "smollm:135m", "prompt": "What is IBM Z?", "stream": False},
    timeout=1800,
)
print(resp.json()["response"])
```

---

## s390x-specific notes (summary)

| Issue | Fix |
|---|---|
| Permission denied on model directory | Set both `HOME` and `OLLAMA_MODELS` to the PVC mount path |
| Cold start takes 5–6 minutes | Set `OLLAMA_LOAD_TIMEOUT=30m`; size liveness probe `initialDelaySeconds` accordingly |
| Pod scales to zero and adds cold-start latency | Use `RawDeployment` mode + `OLLAMA_KEEP_ALIVE=-1` |
| Arbitrary UID has no write access | Pin `runAsUser: 10001` to match `useradd -u 10001` in the image |
| Memory higher than model's nominal size | `mmap` is disabled for the byte-swap; add 20–30% overhead to `limits.memory` |

---

## Next steps

| Goal | Guide |
|---|---|
| Add OpenWebUI on top of this deployment | [docs/5-open-webui.md](5-open-webui.md) |
| Understand why the load timeout is so long | [docs/6-endianness-fix.md](6-endianness-fix.md) |
| Choose the right model size for your LPAR | [docs/7-models.md](7-models.md) |
