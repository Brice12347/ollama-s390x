# Makefile — Ollama s390x
# Targets: image, run, smoke, perf, clean
#
# Usage (s390x Linux / triframe dev container):
#   make image          # build the ollama container image for s390x
#   make run            # start ollama serve (foreground)
#   make smoke          # quick health-check + single inference
#   make perf           # full integration + performance test suite
#   make clean          # remove build artefacts and stopped containers

SHELL := /bin/bash

# ── Configuration ─────────────────────────────────────────────────────────────

IMAGE_NAME   ?= ollama-s390x
IMAGE_TAG    ?= dev
OLLAMA_HOST  ?= 127.0.0.1:11434
SMOKE_MODEL  ?= smollm:135m
PERF_TIMEOUT ?= 90m
BUILD_JOBS   ?= $(shell nproc)

# ── Helpers ───────────────────────────────────────────────────────────────────

.PHONY: image build cmake run smoke perf clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

# ── Targets ───────────────────────────────────────────────────────────────────

build: ## Compile the ollama binary (go build)
	@echo ">>> Building ollama binary"
	go build -o ollama .

cmake: ## Build llama-server via CMake (required for inference)
	@echo ">>> Building llama-server (cpu_s390x preset)"
	cmake -S llama/server --preset cpu_s390x -DGGML_BLAS=OFF
	cmake --build build/llama-server-cpu_s390x --parallel $(BUILD_JOBS)

image: ## Build the ollama s390x container image
	@echo ">>> Building $(IMAGE_NAME):$(IMAGE_TAG)"
	docker build \
	  --platform linux/s390x \
	  --tag $(IMAGE_NAME):$(IMAGE_TAG) \
	  --file Dockerfile \
	  .

run: build ## Start ollama serve (press Ctrl-C to stop)
	@echo ">>> Starting ollama serve on $(OLLAMA_HOST)"
	OLLAMA_HOST=$(OLLAMA_HOST) ./ollama serve

smoke: build ## Health check + single inference (requires ollama serve + llama-server)
	@echo ">>> Smoke test against $(OLLAMA_HOST)"
	@# 1. Health check
	@STATUS=$$(curl -sf http://$(OLLAMA_HOST)/ 2>/dev/null); \
	  if [ "$$STATUS" != "Ollama is running" ]; then \
	    echo "FAIL: server not reachable at $(OLLAMA_HOST)"; exit 1; \
	  fi
	@echo "PASS: health check"
	@# 2. Pull smoke model if not present
	@./ollama pull $(SMOKE_MODEL)
	@# 3. Single inference
	@curl -sf http://$(OLLAMA_HOST)/api/generate \
	  -H "Content-Type: application/json" \
	  -d '{"model":"$(SMOKE_MODEL)","prompt":"Reply with one word: hello","stream":false,"options":{"temperature":0,"num_predict":5}}' \
	  -o /tmp/ollama_smoke.json
	@grep -q '"done":true' /tmp/ollama_smoke.json || { echo "FAIL: inference did not return done:true"; cat /tmp/ollama_smoke.json; exit 1; }
	@echo "PASS: inference smoke test"

perf: ## Run integration + performance test suite (go test)
	@echo ">>> Running performance integration tests (timeout: $(PERF_TIMEOUT))"
	go test \
	  --tags=integration,perf \
	  -count=1 \
	  -v \
	  -timeout $(PERF_TIMEOUT) \
	  -run TestModelsPerf \
	  ./integration/ \
	  2>&1 | tee logs/perf_run_$$(date +%Y%m%d_%H%M%S).log

clean: ## Remove build artefacts and stopped containers
	@echo ">>> Cleaning build artefacts"
	rm -rf build/ dist/
	@echo ">>> Removing stopped containers (if docker available)"
	@docker container prune -f 2>/dev/null || true
	@echo ">>> Done"
