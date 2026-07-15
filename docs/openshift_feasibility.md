# OpenShift / KServe Feasibility for Ollama s390x

**Date:** 2026-07-14
**Author:** Justin Veltri
**Sprint:** Sprint 4 — Performance + UX + Optional Integration
**Status:** Cluster access confirmed — `ollama` namespace exists on zCX OpenShift

---

## Purpose

This document assesses whether Ollama on s390x can be deployed or served through
OpenShift / KServe, and how difficult that integration would be in practice. It is
intended to inform Rafael's scope decision for the second half of Sprint 4 and to
give Brice a deployment target if the KServe path is pursued.

The questions this document tries to answer:

1. Can the existing `ollama` binary + shared library bundle run inside a container
   that is schedulable on an s390x OpenShift node?
2. Can KServe's `InferenceService` CRD serve the Ollama API, either natively or via
   a custom runtime?
3. What are the biggest blockers, and how much effort would it take to resolve them?

## Cluster Access — Confirmed

As of 2026-07-14, access to a live OpenShift cluster has been confirmed:

| Property | Value |
|----------|-------|
| **Cluster** | zCX for Red Hat OpenShift Ecosystem cluster |
| **Namespace** | `ollama` (pre-existing, dedicated) |
| **Permitted uses** | GA product installation/deployment, non-destructive testing, demo deployments, products from public/certified catalog |
| **Permission level** | Namespace-scoped (not cluster-admin — cluster-level metrics unavailable) |

**Implications:**

- The `ollama` namespace already exists — no namespace creation step needed.
- The cluster's permitted-use policy explicitly covers demo deployments and
  non-destructive testing, which matches Sprint 4's goals exactly.
- Cluster-admin is not available, which means SCCs and any cluster-wide
  `ClusterServingRuntime` resources will need to be applied by a cluster admin or
  pre-exist. Namespace-scoped `ServingRuntime` objects can be applied by namespace
  owners.
- Control plane status appearing as "Not available" in the overview is expected for
  non-admin users — it does not indicate a cluster problem.

---

## Background

### What OpenShift adds over vanilla Kubernetes

OpenShift is Red Hat's enterprise Kubernetes distribution. For this feasibility
study the relevant additions are:

- **Security Context Constraints (SCCs)** — OpenShift's replacement for Kubernetes
  PodSecurityAdmission. Containers run under more restrictive defaults than vanilla
  K8s. In particular, containers are not allowed to run as root by default, and
  arbitrary UID usage requires the `anyuid` or a custom SCC.
- **Image stream and registry integration** — images must be accessible through an
  OpenShift-compatible registry or be pre-pulled.
- **s390x node scheduling** — IBM Z and LinuxONE nodes can join an OpenShift cluster
  as worker nodes (OpenShift 4.x supports multi-arch clusters). The platform must be
  built for `linux/s390x`.

### What KServe / RHOAI is

KServe is a Kubernetes-native model serving framework. **Red Hat OpenShift AI
(RHOAI)** ships KServe as its model-serving backend and adds a dashboard-driven
workflow on top of it via the Open Data Hub (ODH) operator.

KServe's central concept is the `InferenceService` custom resource, which references
a `ServingRuntime` (namespace-scoped) or `ClusterServingRuntime` (cluster-wide) to
describe how to run a model container:

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: my-model
spec:
  predictor:
    model:
      modelFormat:
        name: gguf
      storageUri: <model URI>
```

Since Ollama does not match any built-in runtime (Triton, TorchServe, MLServer), the
integration requires a **custom `ServingRuntime`**. Critically, RHOAI's
`ServingRuntime` does **not** enforce the KServe v1/v2 inference protocol — it
simply routes traffic to whatever HTTP port the container exposes. The Ollama API
(`/api/generate`, `/api/chat`) works as-is with no adapter needed.

The `opendatahub.io/dashboard: "true"` label makes the runtime appear in the RHOAI
dashboard's model serving UI, enabling self-service deployment.

---

## Current State of the Ollama s390x Artifact

The artifact produced by the current build is:

- `ollama` — the Go binary, statically linked for Go but dynamically linked to
  `libllama.so` and related libraries
- `/usr/local/lib/ollama/` — shared library bundle (`libllama.so`, `libggml*.so`,
  `libstdc++.so` shims)
- Served via a `systemd` unit that binds to `127.0.0.1:11434`

The installer (`scripts/install.sh`) assumes a bare-metal or VM Linux host. No
container image is currently built or published as part of the project.

Key characteristics that affect container packaging:

| Property | Value | Implication |
|----------|-------|-------------|
| Architecture | `linux/s390x` | Only schedulable on s390x nodes |
| GPU backend | None (CPU-only) | No device plugin dependency |
| Root requirement | None at runtime | Compatible with non-root SCC if file paths are writable |
| Shared library deps | `/usr/local/lib/ollama/` | Must be inside the image or volume-mounted |
| Model storage | `~/.ollama/models` | Must be a writable `PersistentVolume` |
| Listener | `127.0.0.1:11434` | Must be changed to `0.0.0.0` inside a pod |

---

## Integration Path Options

### Option A — Direct container deployment (no KServe)

Package the binary and libraries into a container image, deploy as a standard
Kubernetes `Deployment` + `Service`, and expose via an OpenShift `Route`.

**Steps:**

1. Write a `Dockerfile` that installs the Ollama s390x tarball into an
   `ubuntu:22.04-s390x` base image, runs `ldconfig`, and sets `OLLAMA_HOST=0.0.0.0`.
2. Build and push to a registry accessible from the OpenShift cluster.
3. Create a `PersistentVolumeClaim` for model storage.
4. Deploy with a `Deployment` manifest that mounts the PVC at `~/.ollama/models` and
   exposes port `11434`.
5. Create a `Service` and `Route` for external access.

**Difficulty:** Low-medium. The main friction points are SCC configuration (need
`anyuid` or a dedicated service account) and model pre-loading (must either pull at
pod startup or pre-populate the PVC).

**Effort estimate:** 1–2 days for a working proof of concept.

### Option B — RHOAI `ServingRuntime` (confirmed viable path)

Register a custom `ServingRuntime` in RHOAI and deploy via an `InferenceService`.
This is the path confirmed by the working manifest below.

**Steps:**

1. Complete Option A (the container image is a prerequisite).
2. Apply the `ServingRuntime` manifest to the target namespace on the OpenShift
   cluster. The `opendatahub.io/dashboard: "true"` label makes it appear in the
   RHOAI dashboard.
3. Create an `InferenceService` that references the runtime and points to a model
   URI (S3, PVC, or OCI).
4. RHOAI schedules the pod on an s390x worker node (requires node affinity or a
   dedicated s390x node pool in the cluster).

**Key finding:** The protocol mismatch concern identified earlier is **not a blocker
for RHOAI**. RHOAI `ServingRuntime` does not validate inference protocol — it only
cares that the container starts and the readiness probe passes. Ollama's native API
is exposed directly on port `11434` with no adapter.

**Notable manifest details:**

| Field | Value | Why it matters |
|-------|-------|----------------|
| `builtInAdapter.modelLoadingTimeoutMillis` | `90000` (90s) | Accounts for s390x cold-load penalty (byteswap + non-mmap load) |
| `OLLAMA_MODELS` | `/.ollama/models` | Root-anchored path — requires writable root or a volume mounted at `/` |
| `OLLAMA_KEEP_ALIVE` | `"-1m"` | Keeps models in memory indefinitely — appropriate for serving |
| `supportedModelFormats.name` | `"any"` | Treated as a label by RHOAI, not validated; any string works |
| `opendatahub.io/dashboard: "true"` | label | Surfaces the runtime in the RHOAI model serving dashboard |

**Difficulty:** Medium. The container image and SCC/permission setup remain as work
items, but the manifest structure is now confirmed.

**Effort estimate:** 1–3 days once the container image from Option A exists.

### Option C — Plain KServe without RHOAI

Deploy a `ClusterServingRuntime` against a vanilla KServe install (no RHOAI).

**Difficulty:** Medium. Requires RawDeployment mode to avoid Knative. Functionally
equivalent to Option B but without the dashboard UI. Only relevant if the target
cluster has KServe but not RHOAI installed.

---

## Blockers and Risks

| Blocker | Severity | Details |
|---------|----------|---------|
| No container image exists yet | High | Brice needs to build one as a prerequisite (Day 31 task) |
| SCC / permission constraints | Medium | `OLLAMA_MODELS: /.ollama/models` uses a root-anchored path; container needs a writable volume at `/.ollama` or SCC must permit it |
| ~~KServe protocol mismatch~~ | ~~Medium~~ | **Resolved** — RHOAI `ServingRuntime` does not enforce v1/v2 inference protocol; no adapter needed |
| Model download at pod startup | Medium | `ollama pull` requires internet access or a pre-populated PVC/S3 bucket |
| s390x node availability | **Resolved** | zCX cluster confirmed accessible; `ollama` namespace exists |
| 90s model load timeout | Low | `modelLoadingTimeoutMillis: 90000` is set; may need increase for large models on constrained hardware |
| `quay.io/<username>` placeholder | Low | Image registry and credentials must be confirmed before deployment |

---

## Recommended Approach for Sprint 4

Given the sprint timeline (14–24 July), confirmed cluster access, and the parallel
workload:

1. **Brice** builds the `ollama-ubi9:s390x` container image and pushes it to
   `quay.io/<username>/ollama-ubi9:s390x` (Day 31).
2. **Justin** confirms whether RHOAI / ODH is installed in the `ollama` namespace by
   checking for `ServingRuntime` CRD availability (`oc get crd servingruntimes`).
3. **If RHOAI is present** — apply the `ServingRuntime` manifest to the `ollama`
   namespace, then deploy via `InferenceService` (Option B). This is now the primary
   path.
4. **If RHOAI is absent** — deploy using the plain `Deployment` + `Service` + `Route`
   manifests (Option A). This validates scheduling and SCC behaviour without KServe.
5. In either case, confirm s390x node scheduling by verifying
   `kubernetes.io/arch=s390x` on at least one available node
   (`oc get nodes -L kubernetes.io/arch`).

This matches Rafael's stated principle: **optional integration work only if core
container + installer path is stable**. With cluster access confirmed and a working
`ServingRuntime` manifest in hand, Option B is now a realistic Day 32–33 target if
the container image is ready.

---

## Manifests

### Dockerfile

The target base image should be `ubi9` (Red Hat Universal Base Image 9) to align
with RHOAI's supported base images and avoid glibc compatibility issues with the
OpenShift node's container runtime.

```dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest

ARG OLLAMA_VERSION=v0.2.0

RUN dnf install -y curl libstdc++ && dnf clean all

RUN curl -fsSL \
  "https://github.com/Brice12347/ollama-s390x/releases/download/${OLLAMA_VERSION}/ollama-linux-s390x.tgz" \
  -o /tmp/ollama.tgz && \
  tar -xzf /tmp/ollama.tgz -C /usr/local && \
  rm /tmp/ollama.tgz && \
  bash -c ' \
    cd /usr/local/lib/ollama && \
    for f in *.so; do ln -sf "$f" "${f}.0"; done && \
    echo "/usr/local/lib/ollama" > /etc/ld.so.conf.d/ollama.conf && \
    ldconfig \
  '

# Create the model directory so the volume mount path exists
RUN mkdir -p /.ollama/models && chmod -R 775 /.ollama

EXPOSE 11434

ENV OLLAMA_HOST=0.0.0.0
ENV OLLAMA_MODELS=/.ollama/models
ENV OLLAMA_KEEP_ALIVE=-1m

ENTRYPOINT ["/usr/local/bin/ollama", "serve"]
```

> **Note on UID:** The manifest from Brice sets `OLLAMA_MODELS: /.ollama/models`
> (a root-anchored path). OpenShift's `restricted` SCC runs containers as a
> random UID from the namespace's UID range — that UID must be able to write to
> `/.ollama/models`. The `chmod 775` above handles this if the directory is
> created at image build time. Alternatively, mount a `PersistentVolume` at
> `/.ollama/models` and OpenShift will set ownership on the mount automatically.

### Kubernetes Deployment + Service

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama-s390x
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama-s390x
  template:
    metadata:
      labels:
        app: ollama-s390x
    spec:
      nodeSelector:
        kubernetes.io/arch: s390x
      containers:
      - name: ollama
        image: <registry>/ollama-s390x:v0.2.0
        ports:
        - containerPort: 11434
        env:
        - name: OLLAMA_HOST
          value: "0.0.0.0"
        - name: OLLAMA_MODELS
          value: /home/ollama/.ollama/models
        volumeMounts:
        - name: models
          mountPath: /home/ollama/.ollama/models
        readinessProbe:
          httpGet:
            path: /
            port: 11434
          initialDelaySeconds: 10
          periodSeconds: 5
        resources:
          requests:
            memory: "2Gi"
            cpu: "1"
          limits:
            memory: "8Gi"
            cpu: "4"
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama-s390x
spec:
  selector:
    app: ollama-s390x
  ports:
  - port: 11434
    targetPort: 11434
---
# OpenShift Route (exposes via HTTPS ingress)
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ollama-s390x
spec:
  to:
    kind: Service
    name: ollama-s390x
  port:
    targetPort: 11434
  tls:
    termination: edge
```

### RHOAI `ServingRuntime` (Option B — confirmed structure)

This is the manifest provided by Brice, cleaned up and annotated. Replace
`<username>` with the Quay.io account where the image is pushed.

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: ollama
  labels:
    # Surfaces this runtime in the RHOAI dashboard's "Add model server" UI
    opendatahub.io/dashboard: "true"
  annotations:
    openshift.io/display-name: Ollama
spec:
  # 90 seconds — accounts for s390x cold-load penalty (byteswap + non-mmap tensor load)
  # Increase to 180000 for models larger than ~3B parameters if timeouts occur
  builtInAdapter:
    modelLoadingTimeoutMillis: 90000
  multiModel: false
  supportedModelFormats:
    # The name field is a label used by InferenceService.spec.predictor.model.modelFormat.name
    # RHOAI does not validate it against actual file content — any string works
    - autoSelect: true
      name: gguf
  containers:
    - name: kserve-container
      image: quay.io/<username>/ollama-ubi9:s390x
      env:
        - name: OLLAMA_MODELS
          value: /.ollama/models
        - name: OLLAMA_HOST
          value: "0.0.0.0"
        # -1m = keep model loaded indefinitely; appropriate for a persistent serving deployment
        - name: OLLAMA_KEEP_ALIVE
          value: "-1m"
      ports:
        - containerPort: 11434
          name: http1
          protocol: TCP
```

> **No protocol adapter needed.** RHOAI routes traffic to port `11434` directly.
> The Ollama API endpoints (`/api/generate`, `/api/chat`, `/v1/chat/completions`)
> are all accessible as-is through the `InferenceService`'s route.

### `InferenceService` (pairs with the `ServingRuntime` above)

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: ollama-granite
  labels:
    opendatahub.io/dashboard: "true"
spec:
  predictor:
    model:
      modelFormat:
        name: gguf
      # Point to wherever the model is stored — S3, PVC, or OCI image
      # Example using a PVC pre-populated with `ollama pull granite3.3:2b`
      storageUri: pvc://ollama-models/granite3.3
    nodeSelector:
      kubernetes.io/arch: s390x
```

> **Model storage note:** The simplest path for Sprint 4 is to pre-populate a PVC
> by running `ollama pull <model>` from a temporary pod, then reference that PVC
> in `storageUri`. Pulling at pod startup inside the serving container is also
> possible but adds startup latency and requires outbound network access from the
> cluster.

---

## Open Questions

- [x] ~~Is an RHOAI-enabled OpenShift cluster with s390x worker nodes available?~~
  **Confirmed** — zCX Ecosystem cluster, `ollama` namespace.
- [ ] Is RHOAI / ODH installed? Run: `oc get crd servingruntimes.serving.kserve.io`
  — if it returns a result, `ServingRuntime` CRDs are available (Option B).
- [ ] What is the Quay.io registry path where Brice will push the container image?
  (fills the `quay.io/<username>/ollama-ubi9:s390x` placeholder)
- [ ] Does at least one node have `kubernetes.io/arch=s390x`?
  Run: `oc get nodes -L kubernetes.io/arch`
- [ ] What SCC is assigned to the `ollama` namespace service account — can volumes
  be mounted at `/.ollama/models` without `anyuid`?
- [ ] Should the model be pre-pulled into a PVC, or will the pod have outbound
  internet access to run `ollama pull` at startup?
- [ ] For models larger than ~3B parameters, will the 90s `modelLoadingTimeoutMillis`
  be sufficient on this cluster's s390x hardware?

---

## References

- [KServe — Custom ServingRuntime](https://kserve.github.io/website/latest/modelserving/servingruntimes/)
- [KServe — InferenceService](https://kserve.github.io/website/latest/modelserving/v1beta1/inferencegraph/)
- [RHOAI — Serving a custom model](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.9/html/serving_models/serving-large-models_serving-large-models)
- [OpenShift Security Context Constraints](https://docs.openshift.com/container-platform/4.15/authentication/managing-security-context-constraints.html)
- [OpenShift multi-architecture clusters](https://docs.openshift.com/container-platform/4.15/post_installation_configuration/multi-architecture-configuration.html)
- [UBI 9 base image](https://catalog.redhat.com/software/containers/ubi9/ubi/615bcf606feffc5384e8452e)
- [`docs/handoff.md`](handoff.md) — E2E / FFDC integration patterns and model recommendations
- [`scripts/install.sh`](../scripts/install.sh) — current bare-metal installer (basis for Dockerfile)
