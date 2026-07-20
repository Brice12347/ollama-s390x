# OpenShift / KServe Feasibility Report — Ollama on s390x

**Date:** 2026-07-14  
**Authors:** Justin Veltri  
**Sprint:** Sprint 4 (14–24 July 2026)  
**Status:** Initial Findings

---

## 1. Executive Summary

Deploying Ollama as a KServe `ServingRuntime` on an OpenShift AI cluster running IBM Z
(s390x) hardware is **architecturally feasible** with the artifacts already present in
this repository. The core prerequisites — a UBI 9 container image built for `linux/s390x`,
a `ServingRuntime` manifest, and working REST API endpoints — have all been validated at
the component level.

The remaining work is primarily **operational and integration-level**: wiring persistent
object storage (MinIO/S3), confirming cluster-level `htpasswd` credentials, and completing
an end-to-end `InferenceService` deployment against the live `ocpeco.pok.stglabs.ibm.com`
cluster.

**Verdict:** Recommend proceeding with a Sprint 5 pilot deployment. No fundamental
blockers have been identified.

---

## 2. Scope

| In scope | Out of scope |
|---|---|
| KServe `ServingRuntime` deployment on s390x OpenShift AI | Fine-tuning / training workloads |
| Container image suitability (UBI 9, non-root, healthcheck) | GPU-accelerated inference (no GPU on z16 cluster) |
| S3/MinIO model storage integration | OpenWebUI / Jupyter UI integration (see `docs/openwebui_attempt.md`) |
| REST API endpoint validation | ModelMesh multi-model serving |
| Known limitations on s390x | zAIU (z17) acceleration integration |

---

## 3. Current State of Artifacts

### 3.1 Container Image

| Artifact | Location | Status |
|---|---|---|
| KServe Dockerfile | [`Dockerfile.kserve`](../Dockerfile.kserve) | ✅ Complete |
| UBI 9 runtime base | `registry.access.redhat.com/ubi9/ubi-minimal:latest` | ✅ Verified compatible |
| Published image | `quay.io/brice_patchou/ollama-s390x:kserve` | ✅ Pushed to Quay.io |
| Non-root user | `ollama` uid 10001 | ✅ Present |
| Healthcheck | `curl -sf http://127.0.0.1:11434/` | ✅ Passing on LinuxONE |

The KServe image is a four-stage multi-stage build targeting `linux/s390x`:

1. **`base-s390x`** — Ubuntu 24.04 toolchain (GCC 13, CMake 3.28, OpenBLAS, Ninja)
2. **`llama-server-cpu_s390x`** — C++ inference backend compiled with the `cpu_s390x` CMake
   preset (`OLLAMA_S390X_BIGENDIAN=ON`, `GGML_VXE=ON`, `GGML_BLAS=ON/OpenBLAS`)
3. **`build`** — Go `ollama` binary compiled with `CGO_ENABLED=1` for `linux/s390x`
4. **Final (UBI 9 minimal)** — `microdnf install openblas`, copies binaries, enforces
   non-root execution, adds `HEALTHCHECK`

The final image satisfies OpenShift AI's image policy requirements:
- Red Hat UBI base (security-scanned, RHEL ABI)
- Non-root UID outside system range
- No embedded SSH daemon or privileged utilities
- `EXPOSE 11434` and `HEALTHCHECK` defined

### 3.2 KServe ServingRuntime Manifest

The file [`ollama-servingruntime.yaml`](../ollama-servingruntime.yaml) is ready to apply:

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: ollama
  labels:
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: "Ollama (s390x)"
spec:
  builtInAdapter:
    modelLoadingTimeoutMillis: 90000
  containers:
    - name: kserve-container
      image: quay.io/brice_patchou/ollama-s390x:kserve
      env:
        - name: OLLAMA_MODELS
          value: "/home/ollama/.ollama/models"
        - name: OLLAMA_HOST
          value: "0.0.0.0"
        - name: OLLAMA_KEEP_ALIVE
          value: "-1"
      ports:
        - containerPort: 11434
          name: http1
          protocol: TCP
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
  multiModel: false
  supportedModelFormats:
    - autoSelect: true
      name: any
```

> ⚠️ `modelLoadingTimeoutMillis: 90000` (90 s) is suitable for PVC-backed deployments where the model is already on-node. For S3 DataConnection deployments, increase to at least `300000` (5 min) for 20 B+ models to account for download time.

Notable design decisions:
- `OLLAMA_KEEP_ALIVE: -1` — any negative value is treated as `MaxInt64` nanoseconds (effectively infinite) by the Ollama scheduler. The model is never evicted while the pod is running.
- `multiModel: false` — one model per pod, consistent with KServe single-model serving.
- `supportedModelFormats: any` — accepts any GGUF model without format-specific routing.
- Port 11434 mapped as `http1` — matches Ollama's default REST API listener.

---

## 4. Deployment Architecture

```
OpenShift AI (ocpeco.pok.stglabs.ibm.com — IBM Z s390x)
│
├── Namespace: ollama
│
├── ServingRuntime: ollama                    ← ollama-servingruntime.yaml
│   └── Container: kserve-container
│       └── quay.io/brice_patchou/ollama-s390x:kserve
│           ├── /usr/bin/ollama serve
│           └── /home/ollama/.ollama/models ←── PVC or S3 via DataConnection
│
├── InferenceService: ollama-model            ← (to be created)
│   └── predictor.model.runtime: ollama
│
├── PersistentVolumeClaim: ollama-models-pvc  ← (to be created)
│   └── 40 Gi ReadWriteOnce
│
├── S3 DataConnection → MinIO                ← optional; for multi-model
│   └── minio-service:9000
│
└── Route: ollama-model-predictor             ← auto-created by KServe
    ├── https://<route>/v2/models/<model>/infer  (KServe V2)
    └── https://<route>/api/generate             (Ollama-native)
```

The OpenShift AI workflow for this deployment:

1. Register the `ServingRuntime` (done — manifest is in repo)
2. Create a `DataConnection` pointing to MinIO or IBM COS S3
3. Create an `InferenceService` referencing the `ollama` runtime and the model's S3 path
4. KServe provisions a pod, mounts the model from S3 into `/home/ollama/.ollama/models`
5. The pod serves requests through the auto-generated Route at port 443 (TLS-terminated)

---

## 5. S3 / Object Storage Integration

Ollama's model registry (`OLLAMA_MODELS`) must be populated before or at pod startup.
Two strategies apply in OpenShift AI:

### Strategy A — PVC-backed model store (simplest)

Pre-populate a PVC with GGUF models (via a Job or init container), then mount it at
`/home/ollama/.ollama/models`. Works without an S3 dependency. Suitable for a single known model.

### Strategy B — MinIO S3 DataConnection (recommended for multi-model)

Deploy MinIO on the same cluster and expose it as an OpenShift AI `DataConnection`.
KServe will stream the model from S3 into the pod's ephemeral storage at startup.

MinIO supports s390x natively. A reference MinIO deployment manifest (40 Gi PVC, secret
for root credentials, Service, and TLS-terminated Route) was shared by the team and is
suitable for the `ocpeco` cluster.

Key values needed to configure the `DataConnection`:
- **Endpoint URL**: exposed by the `minio-api` Route (e.g., `https://minio-api-<ns>.apps.ocpeco.pok.stglabs.ibm.com`)
- **Access key / Secret key**: from the `minio-secret` Kubernetes Secret
- **Bucket name** and **path**: where the GGUF model blob is stored

> ⚠️ **Cluster note:** During Sprint 4 the `minio-api` Route URL was not immediately
> visible to interns. The endpoint can be retrieved from the cluster's **Networking → Routes**
> tab in the OpenShift Console, or via `oc get route minio-api -n <namespace>`.

---

## 6. Inference Endpoint

After a successful `InferenceService` deployment KServe exposes four URL patterns:

| Endpoint | Path | Protocol |
|---|---|---|
| KServe V2 | `/v2/models/<model>/infer` | HTTP/gRPC |
| Ollama-native | `/api/generate` | HTTP POST |
| Ollama-native | `/api/chat` | HTTP POST |
| Model list | `/api/tags` | HTTP GET |

The Ollama API is accessible at the pod's internal port 11434. The KServe sidecar proxy
forwards external traffic from the OpenShift Route to the container.

**Python example (via KServe Route):**

```python
import requests

KSERVE_URL = "https://<route>/api/generate"

resp = requests.post(KSERVE_URL, json={
    "model": "smollm:135m",
    "prompt": "Summarise this FFDC log: ...",
    "stream": False
})
print(resp.json()["response"])
```

**curl example:**

```sh
curl -s https://<route>/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"smollm:135m","prompt":"What is 2+2?","stream":false}'
```

---

## 7. Performance Baseline (s390x)

Performance data was collected on IBM Z hardware using the integration test suite
([`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md)).

| Model | Context | Prompt Eval TPS | Eval (Gen) TPS | Load Time (s) |
|---|---|---|---|---|
| `lfm2.5-thinking:latest` | 4096 | 120.72 | 37.59 | 0.91 |
| `lfm2.5-thinking:latest` | 8192 | 119.22 | **46.28** | 0.92 |
| `lfm2.5-thinking:latest` | 16384 | 118.20 | 43.16 | 0.92 |
| `deepseek-r1:1.5b` | 8192 | 75.75 | 21.95 | 1.56 |
| `deepseek-r1:1.5b` | 16384 | 84.64 | 19.73 | 1.57 |
| `qwen3-coder:30b` | 4096 | 29.93 | 8.79 | 8.82 |
| `gpt-oss:20b` | 8192 | 15.12 | 7.78 | 9.81 |
| `gemma4:latest` | 4096 | 26.25 | 7.80 | 10.33 |
| `qwen2.5-coder:latest` | 4096 | 1.91 ⚠️ | 6.29 | 3.05 |

> ⚠️ The figures above are short-prompt (≈10–80 token) benchmarks. For FFDC log analysis workloads where prompts may be hundreds to thousands of tokens, consult the long-prompt rows in [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) as your planning baseline (e.g. `lfm2.5-thinking`: ~23–24 TPS prompt eval at 2000–4600 tokens).

**Observations for OpenShift deployment planning:**
- Small models in the 1–2 B range (e.g., `deepseek-r1:1.5b`) show sub-2 s load times and generation TPS of 20–22. `lfm2.5-thinking` (a compact reasoning model) reaches up to 46 TPS generation at 8192 context. Models around 3 B load in ~3 s — still well-suited to s390x CPU-only inference. (Full data including 3 B rows is in [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md).)
- Large models (20–30 B) have 9–10 s load times. With `OLLAMA_KEEP_ALIVE=-1`, this is a
  one-time cost; the model stays warm for the pod's entire lifetime.
- `qwen2.5-coder:latest` shows anomalously low prompt eval TPS (1.91) — under investigation.
  Do not use this model in latency-sensitive KServe deployments until resolved.
- All models reported `GPU % = 100`. In a CPU-only Ollama build, this simply means 100% of model layers are handled by the CPU backend — no layers were partially unloaded. There is no GPU or zAIU active on the test cluster; the field label is misleading in this context.

---

## 8. s390x-Specific Technical Considerations

### 8.1 Big-Endian GGUF Byte-Swap

IBM Z is a big-endian architecture. Standard GGUF model files are little-endian. The
`ollama-s390x` fork applies three llama.cpp patches at build time:

| Patch | Purpose |
|---|---|
| `001-llama-cpp-hooks.patch` | Inserts compat layer call sites |
| `002-gguf-big-endian-byteswap.patch` | GGUF metadata header byte-swap |
| `003-tensor-data-big-endian-byteswap.patch` | Tensor weight byte-swap (new, critical) |

This means **any standard GGUF model from the Ollama registry works transparently** on
s390x without manual conversion. The byte-swap happens in-process at model load time.

**Memory implication:** `mmap` is disabled for big-endian tensor loading. Tensors are
copied into a writable heap buffer. This increases peak RSS by approximately the size of
the model's weight data. Plan for headroom beyond the nominal model size in PVC/S3
sizing and pod resource requests.

### 8.2 SIMD Acceleration (VXE / VXE2)

The `cpu_s390x` CMake preset enables `GGML_VXE=ON`, which activates the IBM Z Vector
Extensions (VXE/VXE2). GGML builds multiple dispatch variants:

- `libggml-cpu-VXE.so` — z15+ (128-bit vector registers)
- `libggml-cpu-VXE2.so` — z16+ (extended vector instructions)

The runtime selects the best available variant via CPU feature detection. No pod
configuration is required — this is baked into the container image.

> Exact `.so` filenames are build-output names determined by upstream llama.cpp; verify with `ls /usr/lib/ollama/` inside the running container.

### 8.3 No GPU Backend

The current s390x deployment is CPU-only (OpenBLAS + VXE). There is no CUDA, ROCm, or
Vulkan backend for z/Architecture. The zAIU accelerator (IBM z17) is not yet integrated
into this build — the `cpu_s390x_zdnn` CMake preset exists as groundwork but is untested
on the `ocpeco` cluster.

For OpenShift AI deployments, **do not request GPU resources in the `ServingRuntime`**.
The current manifest correctly omits any `resources.limits.nvidia.com/gpu` field.

### 8.4 Quantization Format Support

Tested and working on s390x:

| Format | Status |
|---|---|
| Q4_K_M | ✅ Tested (most Ollama-default models) |
| Q4_0, Q4_1, Q5_0, Q5_1, Q8_0 | ✅ Byte-swap implemented |
| Q2_K, Q3_K, Q5_K, Q6_K | ✅ Byte-swap implemented |
| FP16, BF16, FP32 | ✅ Byte-swap implemented |
| IQ2_XXS, IQ3_S, IQ4_XS (iQuant) | ⚠️ Not yet in byte-swap handler |

---

## 9. Known Issues and Workarounds

| Issue | Severity | Workaround |
|---|---|---|
| Port 11434 lingering across Podman sessions | Low (container runtime only) | Use `ss -tlnp \| grep 11434` to identify; restart rootless Podman network stack. On OpenShift this is handled by the pod network namespace — not applicable. |
| Podman 3.x `Health` inspect schema mismatch | Low (dev/test only) | Use `podman ps STATUS` column; or upgrade to Podman ≥ 4.0 |
| `mmap` disabled — higher peak RSS | Medium | Add 20–30% headroom to pod `resources.limits.memory`. Example: a 4 B model at Q4_K_M (~2.5 GB) may require ~3.5 GB pod memory limit. |
| iQuant formats not byte-swapped | Medium | Avoid `IQ2_XXS`, `IQ3_S`, `IQ4_XS` quantised models in production. Standard Q4/Q8 formats are safe. |
| `qwen2.5-coder` anomalous low TPS | Low | Under investigation. Use `lfm2.5-thinking` or `deepseek-r1` for demos. |
| MinIO endpoint URL not immediately visible | Low (onboarding) | Navigate to **Networking → Routes** in OpenShift Console, filter by `minio-api`. |
| Cluster access via `htpasswd` only | Low (onboarding) | Log in through OpenShift Console with `htpasswd` credentials from cluster admin (Adis). Red Hat account login does not work for the `ocpeco` cluster. |
| `install.sh` prints completion message twice | Cosmetic | Minor script bug, not functional. |

---

## 10. Integration Points for Dependent Teams

### FFDC / E2E Teams

After a successful `InferenceService` deployment, the Ollama service is consumable as a
standard HTTP REST service through the KServe Route. Teams can:

1. **Call the Ollama HTTP API directly** (see Section 6 examples) — requires no Ollama
   client library, only `requests` or `curl`.
2. **Use the Ollama Python client** pointing to the KServe Route URL as the `host`.
3. **Connect from Jupyter Notebooks** inside OpenShift AI Workbenches by setting
   `OLLAMA_HOST` to the internal service DNS name
   (`http://ollama-model-predictor.<namespace>.svc.cluster.local`).

### OpenShift AI Dashboard

The `ServingRuntime` manifest includes `opendatahub.io/dashboard: "true"` — it will appear
in the OpenShift AI Dashboard under **Model Serving → Serving Runtimes** once applied.

### OpenShift Service Mesh / Routes

Ollama exposes a plain HTTP API. For inter-service communication within the cluster,
use the Kubernetes Service DNS name directly. For external access, use the auto-created
OpenShift `Route` with TLS termination.

---

## 11. Deployment Steps (Next Sprint)

The following sequence represents the minimum path to a working end-to-end deployment:

```sh
# 1. Log in to the ocpeco cluster (htpasswd credentials from cluster admin)
oc login https://api.ocpeco.pok.stglabs.ibm.com:6443

# 2. Switch to (or create) the ollama project
oc new-project ollama || true  # create namespace if it does not exist
oc project ollama

# 3. Apply the ServingRuntime
oc apply -f ollama-servingruntime.yaml

# 4. Create or confirm MinIO DataConnection (via OpenShift AI Dashboard UI)
#    DataConnection → S3-compatible → endpoint from minio-api Route

# 5. Upload model to MinIO bucket
#    First configure the mc alias (replace values with your MinIO credentials):
#    mc alias set minio https://<minio-api-route> <ACCESS_KEY> <SECRET_KEY>
#
#    The bucket must contain Ollama's internal directory structure (blobs/ + manifests/),
#    not a bare .gguf file. The easiest way is to pull the model locally first, then
#    mirror the Ollama model store directory to MinIO:
#
#    ollama pull smollm:135m                          # pull on a dev machine with ollama installed
#    mc mirror ~/.ollama/models minio/ollama-models/  # mirror full store to bucket
#
#    Alternatively copy just the relevant blob and manifest subdirectories:
#    mc cp --recursive ~/.ollama/models/blobs/        minio/ollama-models/blobs/
#    mc cp --recursive ~/.ollama/models/manifests/    minio/ollama-models/manifests/

# 6. Create an InferenceService (example below)
cat <<EOF | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ollama-smollm
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    model:
      modelFormat:
        name: any
      runtime: ollama
      storageUri: s3://ollama-models/smollm/
EOF

# 7. Wait for the pod to become ready
oc get pods -w

# 8. Get the Route URL
oc get route ollama-smollm-predictor

# 9. Smoke test
curl -s https://<route>/api/generate \
  -H "Content-Type: application/json" \
  -d '{"model":"smollm:135m","prompt":"What is 2+2?","stream":false}'
```

---

## 12. Recommendations

| Priority | Recommendation |
|---|---|
| **P0** | Confirm cluster access with `htpasswd` credentials before any deployment work. |
| **P0** | Apply `ollama-servingruntime.yaml` and verify it appears in the OpenShift AI Dashboard. |
| **P1** | Deploy MinIO on the cluster using the reference manifest. Confirm the `minio-api` Route URL resolves. |
| **P1** | Upload `smollm:135m` or `deepseek-r1:1.5b` GGUF to the MinIO bucket and create a test `InferenceService`. |
| **P1** | Validate the full request path: Route → KServe sidecar → Ollama container → response. |
| **P2** | Document pod `resources.limits.memory` recommendations per model size (factor in mmap-disabled overhead). |
| **P2** | Investigate `qwen2.5-coder` low TPS anomaly before recommending it to FFDC team. |
| **P3** | Explore zAIU (`cpu_s390x_zdnn` preset) once z17 hardware is available on cluster. |
| **P3** | Investigate upstream llama.cpp `mmap` re-enable path to reduce memory overhead. |

---

## 13. Open Questions

1. **Storage class**: Which OpenShift storage class on `ocpeco` supports `ReadWriteOnce`
   PVCs for model data? Needs confirmation from cluster admin.
2. **Resource quotas**: Does the `ollama` project have a memory quota large enough for
   20–30 B parameter models (which may require 12–20 GB pod RAM)?
3. **Image pull policy**: Can the cluster pull directly from `quay.io/brice_patchou`
   (public repo), or is a private registry mirror required by cluster policy?
4. **KServe version**: Which version of KServe is installed on `ocpeco`? The
   `InferenceService` API may differ between v0.11 and v0.12.
5. **Network policy**: Are there NetworkPolicy objects restricting pod-to-MinIO traffic
   within the namespace?
6. **V2 inference protocol translation**: Does this cluster's KServe version automatically
   translate `/v2/models/<model>/infer` (KServe V2 protocol) to the Ollama-native API, or
   should external callers use `/api/generate` exclusively? A custom transformer or
   protocol adapter may be required.

---

## 14. References

| Resource | Link |
|---|---|
| KServe Deploy First LLM Guide | https://kserve.github.io/website/latest/modelserving/v1beta1/llm/huggingface/ |
| KServe ServingRuntime API | https://kserve.github.io/website/latest/modelserving/servingruntimes/ |
| Red Hat UBI 9 Minimal Image | https://catalog.redhat.com/software/containers/ubi9/ubi-minimal |
| Quay.io Image (latest) | https://quay.io/repository/brice_patchou/ollama-s390x |
| Quay.io Image (kserve) | `quay.io/brice_patchou/ollama-s390x:kserve` |
| OpenShift AI Dashboard | URL varies by cluster — run: `oc get route rhods-dashboard -n redhat-ods-applications` |
| MinIO s390x Docs | https://min.io/docs/minio/linux/index.html |
| Performance Log | [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) |
| Quay.io Build Log | [`logs/quay_io_experiment_20260702.md`](../logs/quay_io_experiment_20260702.md) |
| LinuxONE Smoke Test | [`logs/linuxone_podman_smoke_test_20260714.md`](../logs/linuxone_podman_smoke_test_20260714.md) |
| s390x Architecture Notes | [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) |
| Big-Endian Inference Notes | [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md) |
| ServingRuntime YAML | [`ollama-servingruntime.yaml`](../ollama-servingruntime.yaml) |
| KServe Dockerfile | [`Dockerfile.kserve`](../Dockerfile.kserve) |
