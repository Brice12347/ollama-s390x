# Step 5 — Deploy OpenWebUI on s390x

OpenWebUI provides a ChatGPT-style web interface that connects to the Ollama inference backend.
The upstream `ghcr.io/open-webui/open-webui` image **does not run on s390x** — it depends on
`chromadb` which requires an `onnxruntime` wheel that is not published for `linux/s390x`.
A dedicated s390x build is required.

---

## Prerequisites

- Ollama is already running on OpenShift AI (see [docs/4-openshift-deploy.md](4-openshift-deploy.md))
- An s390x-compatible OpenWebUI image pushed to your registry:
  `quay.io/<your-org>/open-webui:s390x-v25`
- The PVC `ollama-models` exists in `project-ollama` (created in the Ollama deploy step)

---

## Building the s390x OpenWebUI image

The upstream image must be rebuilt for s390x with the RAG/vector-database stack disabled.
The build is in the `open-webui` repository on the `justin-test-branch` branch.

Two s390x-specific problems are fixed in the build:

### Problem 1 — `lightningcss` has no s390x binary

Open WebUI uses Tailwind v4 which requires `lightningcss`, a Rust-compiled native binary.
`lightningcss-linux-s390x` does not exist on npm and there is no pure-JS fallback.
The build patches the loader before running `vite build`:

```dockerfile
RUN sed -i "s|require('../lightningcss.linux|require('../lightningcss.linux.DISABLED|g" \
        node_modules/lightningcss/node/index.js 2>/dev/null || true \
    && npx vite build
```

### Problem 2 — `onnxruntime` has no s390x wheel

`chromadb` (the default vector DB) requires `onnxruntime`, which has no `linux/s390x` wheel on PyPI.
The build disables the RAG/vector stack entirely so the import never runs.

Build and push (from the `open-webui` repository):

```sh
podman build \
  --platform linux/s390x \
  --format docker \
  -f Dockerfile.s390x \
  -t quay.io/<your-org>/open-webui:s390x-v25 \
  .
podman push quay.io/<your-org>/open-webui:s390x-v25
```

---

## Deploy OpenWebUI

The manifest below encodes several lessons learned during the internship.

**Key s390x decisions:**

| Setting | Value | Why |
|---|---|---|
| `OLLAMA_BASE_URL` | Internal cluster DNS | Avoids an unnecessary Route round-trip; pattern is `http://<inferenceservice-name>-predictor.<namespace>.svc.cluster.local:11434` |
| All timeout variables | `1800` seconds | CPU inference on s390x exceeds default timeouts, especially on cold start |
| `ENABLE_TITLE_GENERATION=false` | disabled | Fires a second concurrent Ollama request immediately after the main chat request; times out during 5-min cold start and surfaces a confusing UI error |
| `ENABLE_AUTOCOMPLETE_GENERATION=false` | disabled | Same reason as above |
| `VECTOR_DB=disabled` | disabled | `chromadb` requires `onnxruntime`, which has no s390x wheel |
| Route annotation `haproxy.router.openshift.io/timeout: 30m` | `30m` | OpenShift's default HAProxy route timeout is 30 seconds — far too short for streaming LLM responses |

```yaml
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
              # Generate with: python3 -c "import secrets; print(secrets.token_hex(32))"
              value: "<your-secret-key>"
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
```

```sh
oc apply -f open-webui-deployment.yaml
oc get pods -l app=open-webui -n project-ollama -w
oc get route open-webui -n project-ollama
```

Open the reported hostname in a browser. You should see the OpenWebUI interface connected to the s390x Ollama backend.

---

## Connecting from a Jupyter Workbench

To create a Jupyter Notebook workbench on RHOAI that talks to the Ollama inference service:

1. Label your PVC so the RHOAI dashboard can discover it:
   ```sh
   oc label pvc ollama-models opendatahub.io/dashboard=true -n project-ollama
   ```

2. In the RHOAI dashboard → your data science project → **Workbenches** → **Create workbench**:
   - Select your notebook image (e.g. Jupyter Minimal CPU Python 3.12)
   - Under **Cluster storage** → **Attach existing storage** → select `ollama-models`
   - Set mount path to e.g. `/opt/app-root/src/data`, sub-path `jupyter-notebooks`

3. Inside the notebook, use the internal cluster DNS:
   ```python
   import requests

   BASE_URL = "http://ollama-predictor-predictor.project-ollama.svc.cluster.local:11434"

   # List available models
   print(requests.get(f"{BASE_URL}/api/tags").json())

   # Single-turn generation (non-streaming)
   resp = requests.post(
       f"{BASE_URL}/api/generate",
       json={"model": "smollm:135m", "prompt": "What is IBM Z?", "stream": False,
             "options": {"num_predict": 512}},
       timeout=1800,
   )
   print(resp.json()["response"])
   ```

---

## Limitations on s390x

| Feature | Status | Reason |
|---|---|---|
| Chat and Ollama inference | ✅ Works | Core functionality |
| RAG / Knowledge base | ❌ Unavailable | `chromadb` requires `onnxruntime` (no s390x wheel) |
| Web search | ❌ Disabled | Disabled to avoid RAG dependency |
| Title auto-generation | ❌ Disabled | Times out during cold-start byte-swap |
| Autocomplete | ❌ Disabled | Same reason as title generation |
