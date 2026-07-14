# Bottleneck Analysis for `ollama-s390x`

## Purpose

This document captures the current understanding of likely performance bottlenecks for the `s390x` big-endian port of Ollama, based on the current codebase and existing porting notes. It is intended to guide profiling and validation work, not to claim that every item below has already been measured.

## Scope

This analysis is focused on:

- server-side model loading
- native llama runtime startup
- CPU-only inference behavior
- big-endian compatibility overhead
- scheduler behavior that may amplify load costs

This analysis is not yet a benchmark report. The items below are **insights and hypotheses grounded in the current implementation**.

## System Runtime Map

At a high level, the execution path is:

1. [`main()`](../main.go:11) starts the CLI via [`cmd.NewCLI()`](../cmd/cmd.go:2283)
2. [`ollama serve`](../cmd/cmd.go:2389) enters [`RunServer()`](../cmd/cmd.go:1985)
3. [`RunServer()`](../cmd/cmd.go:1985) binds a listener and calls [`server.Serve()`](../server/routes.go:1945)
4. [`server.Serve()`](../server/routes.go:1945) sets up routes, scheduler, model cache, and runtime defaults
5. inference requests hit handlers such as [`GenerateHandler()`](../server/routes.go:254) and [`ChatHandler()`](../server/routes.go:2445)
6. handlers call [`scheduleRunner()`](../server/routes.go:203) to acquire or load a model runner
7. the scheduler loads GGUF metadata, predicts memory placement, and creates a native runner in [`load()`](../server/sched.go:502)
8. GGUF-backed models are served by a llama-server subprocess created through [`llm.NewLlamaServer()`](../llm/server.go:108) and [`NewLlamaServerRunner()`](../llm/llama_server.go:819)
9. the Go server communicates with that subprocess over localhost HTTP for completion, chat, embedding, tokenization, and template application

This means the system is split into two layers:

- **Go orchestration layer**: request handling, scheduling, subprocess management, streaming
- **native llama runtime layer**: model loading, tensor handling, token generation, embedding computation

For `s390x`, the most important platform-specific bottlenecks are likely in the **native load path** and **native CPU inference kernels**, not in the Go API layer.

## Confirmed Architectural Constraints Relevant to `s390x`

### 1. Big-endian tensor loading requires byteswapping

The port notes in [`docs/s390x-big-endian-inference.md`](./s390x-big-endian-inference.md) and the native patch in [`llama/compat/003-tensor-data-big-endian-byteswap.patch`](../llama/compat/003-tensor-data-big-endian-byteswap.patch) establish that GGUF tensor data needs explicit byteswapping on big-endian systems.

The patch adds:

- [`bswap_buf`](../llama/compat/003-tensor-data-big-endian-byteswap.patch:29)
- [`bswap_tensor_data`](../llama/compat/003-tensor-data-big-endian-byteswap.patch:102)

and applies them in the llama model loader load paths.

### 2. `mmap` is disabled for big-endian transformed loads

The big-endian support notes in [`docs/s390x-big-endian-inference.md`](./s390x-big-endian-inference.md) explain that `mmap()` cannot be used for in-place tensor byteswapping, so the runtime forces model loads through writable buffers.

This is a major architectural difference from little-endian deployments.

### 3. Current `s390x` operation is effectively CPU-only

The same notes state that there is currently no GGML GPU backend for `s390x`, so inference work falls onto the CPU path.

That makes the quality of CPU kernels, vectorization, cache behavior, and memory bandwidth especially important.

## Primary Insights

## Insight 1: cold model load is very likely more expensive on `s390x` than on little-endian hosts

### Why

The native load path on `s390x` includes all of the normal model startup costs plus additional overhead from:

- reading tensors into writable memory rather than relying on `mmap`
- traversing tensor buffers to byteswap endian-sensitive fields
- validating post-swap tensor data

These operations are visible in [`llama/compat/003-tensor-data-big-endian-byteswap.patch`](../llama/compat/003-tensor-data-big-endian-byteswap.patch:121) and [`llama/compat/003-tensor-data-big-endian-byteswap.patch`](../llama/compat/003-tensor-data-big-endian-byteswap.patch:129).

### Hypothesis

For large GGUF models, **cold load latency on `s390x` is likely dominated by tensor read + byteswap + copy behavior**, not by Go-side orchestration.

### Expected symptoms

- much slower first request after model load
- expensive model switching
- significant penalty after eviction/reload cycles
- performance sensitivity to model size and quantization layout

## Insight 2: memory bandwidth may be a larger limiter than compute during model load

### Why

The byteswap logic in [`bswap_buf`](../llama/compat/003-tensor-data-big-endian-byteswap.patch:29) is a buffer-walking transformation over loaded tensor data. Even though only specific fields are swapped, the loader still touches model data block-by-block.

This kind of work tends to be limited by:

- memory bandwidth
- cache efficiency
- buffer traversal overhead

### Hypothesis

On `s390x`, **model load time will scale strongly with total tensor bytes touched**, and may be bottlenecked by data movement more than arithmetic.

### Expected symptoms

- load time grows roughly with model size
- different quant formats show different load costs even before inference begins
- CPU utilization may not fully reflect the real limiting factor if memory traffic is dominant

## Insight 3: steady-state generation performance is likely dominated by native CPU kernel quality

### Why

Once a model is loaded, Go mostly packages requests and streams responses. The actual compute occurs in the llama-server subprocess through calls such as [`Completion()`](../llm/llama_server.go:1481) and [`Chat()`](../llm/llama_server.go:1834), which send local HTTP requests to the native runtime.

The Go path does work, but it is relatively thin compared with token generation itself.

### Hypothesis

If warm-run tokens/sec is poor on `s390x`, the main cause is likely **CPU-side llama.cpp / ggml execution**, especially:

- quantized dequantization paths
- matrix multiplication kernels
- attention and KV-cache memory traffic
- architecture-generic fallback code that is not tuned for `s390x`

### Expected symptoms

- warm generation throughput lags other CPU architectures even after load cost is excluded
- prompt eval and decode phases both show CPU-heavy slowdown
- performance varies significantly across quantization formats and model families

## Insight 4: missing or immature `s390x` SIMD specialization is a strong candidate bottleneck

### Why

The architecture summary in [`docs/s390x_architecture_notes.md`](./s390x_architecture_notes.md) shows that `s390x` has meaningful vector capabilities, including endian-aware vector operations. That suggests the hardware can support better optimized data-parallel execution than a pure generic scalar path.

### Hypothesis

Current steady-state CPU inference likely leaves performance on the table if key llama.cpp / ggml kernels are still using generic implementations rather than `s390x`-aware vectorized ones.

### Expected symptoms

- poor CPU efficiency on hot tensor kernels
- noticeable gap between theoretical hardware capability and observed tokens/sec
- large improvement potential from architecture-specific kernel work

## Insight 5: scheduler behavior may amplify `s390x` load penalties

### Why

The scheduler only loads one model at a time, centered around [`activeLoading`](../server/sched.go:70), and model startup flows through [`processPending()`](../server/sched.go:231) and [`load()`](../server/sched.go:502).

When memory pressure forces evictions, the next request may trigger a full reload.

### Hypothesis

On `s390x`, **scheduler reload churn is more expensive than on little-endian systems**, because each reload re-pays the byteswap and non-`mmap` load costs.

### Expected symptoms

- concurrent multi-model usage degrades sharply
- `keepalive` and max-loaded-model policy have outsized impact
- throughput under mixed workloads is worse than single-model warm performance suggests

## Insight 6: local HTTP and tokenization/template round-trips are secondary but real latency contributors

### Why

The runner uses localhost HTTP for more than just generation:

- [`ApplyChatTemplate()`](../llm/llama_server.go:1788)
- [`Tokenize()`](../llm/llama_server.go:2454)
- [`Detokenize()`](../llm/llama_server.go:2459)
- [`Embedding()`](../llm/llama_server.go:2263)

Also, the HTTP client in [`newLlamaServerHTTPClient()`](../llm/llama_server.go:187) disables keep-alives.

### Hypothesis

These overheads are probably **not the primary throughput bottleneck**, but they may meaningfully affect:

- short-prompt latency
- time to first token
- chat-style interactions with frequent prompt preparation

### Expected symptoms

- short requests look disproportionately expensive
- first-token latency remains elevated even when steady-state decode is acceptable
- localhost request overhead becomes more visible with smaller models

## Prioritized Bottleneck Hypotheses

The current best-priority ranking is:

1. **cold model load overhead from non-`mmap` buffered reads plus big-endian byteswapping**
2. **steady-state CPU inference throughput limited by generic or insufficiently optimized native kernels**
3. **scheduler eviction/reload churn multiplying the already-high cold load cost**
4. **memory bandwidth and cache locality limiting large-model load and inference efficiency**
5. **local HTTP/tokenization/template overhead increasing latency for short interactive requests**

## Recommended Validation Areas

To confirm or reject the hypotheses above, the next profiling pass should separate at least these phases:

### 1. cold load time

Measure from subprocess startup in [`startLlamaServer()`](../llm/llama_server.go:345) through readiness in [`WaitUntilRunning()`](../llm/llama_server.go:1234).

### 2. warm first-token latency

Measure after a model is already loaded, so byteswap/load cost is excluded.

### 3. prompt evaluation versus decode

Use the runtime metrics already surfaced by llama-server responses through [`Completion()`](../llm/llama_server.go:1668) and [`Chat()`](../llm/llama_server.go:1969) to distinguish:

- prompt processing cost
- token generation cost

### 4. reload churn frequency

Observe how often the scheduler evicts and reloads models through [`processPending()`](../server/sched.go:231) and [`processCompleted()`](../server/sched.go:373).

### 5. quantization sensitivity

Compare at least a few common GGUF formats because both byteswap cost and steady-state kernel performance may vary by type.

## Bottom Line

The clearest current conclusion is:

- **`s390x` pays a structural model-load penalty because tensor data must be loaded through writable buffers and byteswapped on a big-endian host**
- **after load, overall throughput is likely determined primarily by CPU-native llama.cpp / ggml efficiency rather than by the Go server layer**
- **scheduler reload churn is likely more damaging on `s390x` than on little-endian systems because reload cost is materially higher**

The most likely major bottlenecks are therefore:

- load-time tensor byteswap and copy overhead
- CPU inference kernel performance
- model reload/eviction behavior under constrained memory
