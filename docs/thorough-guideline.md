# Appendix: Deployment Runbook — Ollama and OpenWebUI on zCX OpenShift AI

This appendix is a hands-on reference, not a narrative — use it to reproduce the deployment described above. It covers two paths: a straightforward Deployment-based approach for quick experimentation, and the full KServe ServingRuntime + InferenceService path used in production. Adjust resource sizes, image tags, and storage classes to match your cluster.

Three points apply throughout this runbook and are stated once here rather than repeated at each step:

Always set both HOME and OLLAMA_MODELS to the same writable, mounted path. Ollama reads its data directory from os/user.Current().HomeDir, not a dedicated OLLAMA_HOME variable. If HOME points somewhere read-only, the process fails silently even when OLLAMA_MODELS is set correctly.
Byte-swap latency dominates cold starts. Every cold load requires swapping GGUF tensor data from little-endian to big-endian. For a 135M-parameter model this takes 5–6 minutes on CPU. Set OLLAMA_LOAD_TIMEOUT=30m and size liveness/readiness probe delays accordingly.
Prefer quantized models (Q4_K, Q5_K, Q8_0) to keep memory usage within typical LPAR bounds. smollm:135mand granite3.3:2b were used for validation during this project and fit comfortably within a 4Gi memory limit.
Prerequisites
Access to a zCX OpenShift AI cluster with sufficient privileges to create projects, PVCs, Deployments, ServingRuntimes, InferenceServices, and Routes
OpenShift CLI (oc) installed and logged in
An s390x-compatible Ollama container image, produced by Dockerfile.kserve and pushed to quay.io/<your-org>/ollama-s390x:kserve
An s390x-compatible OpenWebUI image (quay.io/<your-org>/open-webui:s390x-v25 or later) — necessary because the upstream ghcr.io/open-webui/open-webui image does not ship an onnxruntime wheel for s390x
Basic familiarity with PersistentVolumeClaims and environment variables under OpenShift’s restricted security context
Building the Image (Dockerfile.kserve)
The image is built in four stages:

base-s390x — a UBI 9 toolchain layer with GCC, OpenBLAS, CMake, and Ninja, pulled from registry.redhat.io/ubi9/ubi:latest
llama-server-cpu_s390x — compiles llama-server against the cpu_s390x CMake preset, enabling the OpenBLAS backend with no GPU dependency
build — downloads the matching Go toolchain for linux/s390x, then compiles the Ollama binary with CGO_ENABLED=1 and -buildmode=pie
runtime — a minimal UBI 9 image (registry.redhat.io/ubi9/ubi-minimal:latest) with only openblas installed. The Go binary and llama-server libraries are copied in from earlier stages. The image runs as a dedicated non-root user (uid 10001) with g=u permissions so OpenShift's arbitrary-UID SCC can still write to the home directory.
Three environment variables are baked in as defaults and overridden at runtime:

OLLAMA_HOST defaults to 127.0.0.1:11434, overridden to 0.0.0.0:11434 by the ServingRuntime so the KServe proxy can reach the server
OLLAMA_MODELS defaults to /home/ollama/.ollama/models, overridden to the PVC mount path at runtime
OLLAMA_LOAD_TIMEOUT is set to 30m (see point 2 above)
To build and push:

podman build --platform linux/s390x --format docker \
  -f Dockerfile.kserve \
  -t quay.io/<your-org>/ollama-s390x:kserve .
podman push quay.io/<your-org>/ollama-s390x:kserve
1. Log In and Create a Project
oc login --token=<YOUR_TOKEN> --server=<YOUR_SERVER>
oc new-project project-ollama
2. Create Persistent Storage for Models
Under OpenShift’s restricted SCC, the container cannot write to arbitrary paths, so a PVC is mandatory.

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
oc apply -f ollama-pvc.yaml
oc get pvc -n project-ollama
Tip: If your cluster has a pre-provisioned shared NFS PVC, you can skip creating a dedicated PVC and instead mount a subPath of the shared volume — the KServe manifests below illustrate this pattern.

3a. Deploy Ollama — Deployment-Based Path
A straightforward Deployment works well for initial experimentation and for connecting OpenWebUI before committing to the full KServe path.

oc apply -f ollama-deployment.yaml
oc get pods -n project-ollama -w
oc get svc -n project-ollama
oc apply -f ollama-deployment.yaml
oc get pods -n project-ollama -w
oc get svc -n project-ollama
3b. Deploy Ollama — KServe ServingRuntime + InferenceService Path
This is the production path used in the project, integrating Ollama directly with OpenShift AI’s model-serving layer. It requires two objects.

ServingRuntime
ollama-servingruntime.yaml registers Ollama as a named runtime inside the OpenShift AI dashboard, with several s390x-specific tuning decisions:

An initContainer running as root corrects /home/ollama permissions before the main container starts — necessary because OpenShift's arbitrary-UID SCC can assign a UID with no write access to the directory created by useraddinside the image
OLLAMA_NUM_PARALLEL and OLLAMA_MAX_LOADED_MODELS are both set to 1 to prevent concurrent model slots from exhausting CPU memory on a typical LPAR
OPENBLAS_NUM_THREADS and OMP_NUM_THREADS are pinned to 8 to dedicate all cores to a single request
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
oc apply -f ollama-servingruntime.yaml
InferenceService
ollama-inferenceservice.yaml instantiates the runtime. Two design choices are worth noting:

RawDeployment mode is set via the serving.kserve.io/deploymentMode annotation, bypassing KServe's serverless Knative path — which proved problematic for long-running, CPU-bound inference on s390x, since it scales pods to zero and compounds cold-start latency
No storageUri is specified. KServe mounts storageUri as a read-only volume, which would prevent Ollama from writing its key and configuration files under the models directory. Models are instead pulled manually via oc execafter the pod is running
The pod securityContext pins runAsUser: 10001 to match the useradd -u 10001 line in Dockerfile.kserve. Without this, OpenShift's arbitrary-UID SCC assigns a random UID with no write access to /home/ollama
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
oc apply -f ollama-inferenceservice.yaml
oc get inferenceservice -n project-ollama -w
Note: the KServe webhook forbids mixing spec.predictor.containers with spec.predictor.model in the same InferenceService spec, so declarative env-var injection there isn't available. To add environment variables after deployment, set them directly on the generated Deployment instead:

oc set env deployment/ollama-predictor-predictor -c kserve-container \
  OLLAMA_LOAD_TIMEOUT=30m OLLAMA_KEEP_ALIVE=-1 OLLAMA_MODELS=/mnt/models \
  -n project-ollama
4. Verify Ollama and Pull a Model
# Deployment path - wait until Running and Ready
oc get pods -l app=ollama -n project-ollama
# KServe path
oc get pods -n project-ollama -w
# Optional: port-forward for local testing
oc port-forward svc/ollama 11434:11434 -n project-ollama
# Smoke test
curl http://localhost:11434
# Pull a model - Deployment path
oc exec -it deploy/ollama -n project-ollama -- ollama pull <model-name>
oc exec -it deploy/ollama -n project-ollama -- ollama list
# Pull a model - KServe path
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama pull smollm:135m
oc exec -n project-ollama deployment/ollama-predictor-predictor \
  -c kserve-container -- ollama list
5. Deploy OpenWebUI
The upstream ghcr.io/open-webui/open-webui image doesn't run on s390x — it depends on chromadb, which requires an onnxruntime wheel that isn't published for linux/s390x. A dedicated s390x build was produced for this project with the vector-database and RAG stack disabled.

Key design decisions baked into the deployment below:

OLLAMA_BASE_URL points at the in-cluster DNS name of the KServe InferenceService rather than a Route, avoiding an unnecessary ingress round-trip: http://<inferenceservice-name>-predictor.<namespace>.svc.cluster.local:11434
All timeout variables (AIOHTTP_CLIENT_TIMEOUT, OLLAMA_REQUEST_TIMEOUT, REQUEST_TIMEOUT, UVICORN_TIMEOUT_KEEP_ALIVE) are extended to 1800 seconds, since CPU inference on s390x — especially during the cold-start byte-swap — easily exceeds the defaults
ENABLE_TITLE_GENERATION and ENABLE_AUTOCOMPLETE_GENERATION are disabled. Both fire a second concurrent Ollama request immediately after the main chat request. While the model is still loading (~5 minutes on a cold s390x CPU), that second request times out and surfaces a confusing error in the UI
VECTOR_DB is set to disabled, since chromadb requires the unavailable onnxruntime wheel. Chat and Ollama inference work fully; RAG/knowledge-base features are unavailable
The Route carries a haproxy.router.openshift.io/timeout: 30m annotation, since OpenShift's default HAProxy route timeout (30 seconds) is far too short for streaming responses from a CPU-only LLM
# open-webui-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: open-webui
  namespace: project-ollama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: open-webui
  template:
    metadata:
      labels:
        app: open-webui
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: open-webui
          image: quay.io/<your-org>/open-webui:s390x-v25
          imagePullPolicy: Always
          workingDir: /opt/app-root/src
          command: ["/bin/bash", "-c"]
          args:
            - |
              exec /usr/bin/python3.12 -m uvicorn open_webui.main:app \
                --host "${HOST:-0.0.0.0}" \
                --port "${PORT:-8080}" \
                --forwarded-allow-ips "*" \
                --workers 1
          ports:
            - containerPort: 8080
              protocol: TCP
          env:
            - name: OLLAMA_BASE_URL
              value: "http://ollama-predictor-predictor.project-ollama.svc.cluster.local:11434"
            - name: AIOHTTP_CLIENT_TIMEOUT
              value: "1800"
            - name: AIOHTTP_CLIENT_TIMEOUT_OPENAI_MODEL_LIST
              value: "30"
            - name: OLLAMA_REQUEST_TIMEOUT
              value: "1800"
            - name: REQUEST_TIMEOUT
              value: "1800"
            - name: UVICORN_TIMEOUT_KEEP_ALIVE
              value: "1800"
            - name: WEBUI_SECRET_KEY
              value: "<generate: python3 -c \"import secrets; print(secrets.token_hex(32))\">"
            - name: ENV
              value: "prod"
            - name: PORT
              value: "8080"
            - name: HOST
              value: "0.0.0.0"
            - name: ENABLE_SIGNUP
              value: "true"
            - name: ENABLE_LOGIN_FORM
              value: "true"
            - name: DEFAULT_USER_ROLE
              value: "admin"
            - name: ENABLE_RAG_WEB_SEARCH
              value: "false"
            - name: VECTOR_DB
              value: "disabled"
            - name: ENABLE_TITLE_GENERATION
              value: "false"
            - name: ENABLE_AUTOCOMPLETE_GENERATION
              value: "false"
            - name: SCARF_NO_ANALYTICS
              value: "true"
            - name: DO_NOT_TRACK
              value: "true"
            - name: ANONYMIZED_TELEMETRY
              value: "false"
          resources:
            requests:
              cpu: "200m"
              memory: "512Mi"
            limits:
              cpu: "2"
              memory: "2Gi"
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 90
            periodSeconds: 30
            failureThreshold: 3
          volumeMounts:
            - name: webui-data
              mountPath: /opt/app-root/src/data
              subPath: open-webui
      volumes:
        - name: webui-data
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: open-webui
  namespace: project-ollama
spec:
  selector:
    app: open-webui
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: open-webui
  namespace: project-ollama
  annotations:
    haproxy.router.openshift.io/timeout: 30m
spec:
  to:
    kind: Service
    name: open-webui
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
oc apply -f open-webui-deployment.yaml
oc get pods -l app=open-webui -n project-ollama -w
oc get route open-webui -n project-ollama
Open the reported hostname in a browser. You should see the OpenWebUI interface connected to the s390x Ollama backend.

Press enter or click to view image in full size

6. Notes Specific to s390x / zCX
Use RawDeployment mode in KServe. The serverless Knative path scales pods to zero, and the resulting cold starts compound the byte-swap latency described above. RawDeployment keeps the pod alive and pairs cleanly with OLLAMA_KEEP_ALIVE=-1.
Pin runAsUser: 10001 in the InferenceService pod spec, matching the image's build-time user, or OpenShift's arbitrary-UID SCC will assign a random UID with no write access to /home/ollama.
Size the PVC and memory limits for the largest model you intend to load. Quantized models remain strongly recommended.