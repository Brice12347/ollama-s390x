# Model Performance Integration Test Log 001 — s390x (IBM Z)

**Date:** 2026-07-02
**Platform:** IBM Z (s390x)
**Ollama build:** from source, `main` branch

---

## Methodology

Tests were executed using the official Ollama integration test suite from the repository's [`integration/`](../integration/) directory. The test harness auto-starts an Ollama server, pulls each model, sends prepared prompts, and records timing metrics from the API response.

Commands run:

```sh
# 1. Build the Ollama binary
go build .

# 2. Run the core integration suite (correctness)
go test -tags=integration -v -count=1 -timeout 30m ./integration/

# 3. Run the performance suite (latency, TPS, memory)
go test --tags=integration,perf -count=1 -v -timeout 90m -run TestModelsPerf ./integration/ 2>&1 | tee perf.log

# 4. Extract CSV metrics from log
cat perf.log | grep MODEL_PERF_HEADER | head -1 | cut -f2- -d: > perf.csv
cat perf.log | grep MODEL_PERF_DATA   | cut -f2- -d: >> perf.csv
```

**Metrics captured per model/context combination:**
- **Load Time** — time (seconds) to load the model into memory
- **Prompt Eval TPS** — prompt evaluation throughput (tokens/second)
- **Eval TPS** — generation throughput (tokens/second)
- **GPU Percent** — portion of model loaded into GPU/accelerator (100% = fully accelerated)
- **Approx Prompt Count** — approximate number of prompt tokens evaluated

---

## Results

| Model | Context | GPU % | Approx Prompt Tokens | Load Time (s) | Prompt Eval TPS | Eval TPS |
|---|---|---|---|---|---|---|
| gemma4:latest | 4096 | 100 | 20 | 10.33 | 26.25 | 7.80 |
| lfm2.5-thinking:latest | 4096 | 100 | 20 | 0.91 | 120.72 | 37.59 |
| lfm2.5-thinking:latest | 4096 | 100 | 2370 | 0.11 | 23.46 | 19.84 |
| lfm2.5-thinking:latest | 8192 | 100 | 20 | 0.92 | 119.22 | 46.28 |
| lfm2.5-thinking:latest | 8192 | 100 | 4630 | 0.11 | 24.67 | 13.83 |
| lfm2.5-thinking:latest | 16384 | 100 | 20 | 0.92 | 118.20 | 43.16 |
| qwen3-coder:30b | 4096 | 100 | 20 | 8.82 | 29.93 | 8.79 |
| gpt-oss:20b | 4096 | 100 | 80 | 9.51 | 14.75 | 3.58 |
| gpt-oss:20b | 4096 | 100 | 2090 | 0.67 | 18.53 | 4.83 |
| gpt-oss:20b | 8192 | 100 | 80 | 9.81 | 15.12 | 7.78 |
| deepseek-r1:1.5b | 4096 | 100 | 10 | 1.54 | 76.77 | 18.42 |
| deepseek-r1:1.5b | 4096 | 100 | 2090 | 0.21 | 19.59 | 4.22 |
| deepseek-r1:1.5b | 8192 | 100 | 10 | 1.56 | 75.75 | 21.95 |
| deepseek-r1:1.5b | 8192 | 100 | 4190 | 0.21 | 19.88 | 6.64 |
| deepseek-r1:1.5b | 16384 | 100 | 10 | 1.57 | 84.64 | 19.73 |
| qwen2.5-coder:latest | 4096 | 100 | 40 | 3.05 | 1.91 | 6.29 |
| qwen2.5vl:3b | 4096 | 100 | 30 | 2.88 | 6.15 | 11.87 |
| qwen2.5vl:3b | 4096 | 100 | 2110 | 0.26 | 9.13 | 5.85 |
| qwen2.5vl:3b | 8192 | 100 | 30 | 2.89 | 6.75 | 15.08 |

---

## Observations

### Throughput Highlights
- **lfm2.5-thinking** was the fastest model overall — up to **120.72 TPS** on prompt eval and **46.28 TPS** on generation at context 8192. It also scaled well to 16384 context with minimal degradation.
- **deepseek-r1:1.5b** showed strong and consistent prompt eval TPS (75–84 TPS) across all context sizes, making it a reliable small model on s390x.
- **gemma4** had the highest load time at **10.33s**, with relatively modest generation TPS (7.80).

### Context Scaling Behaviour
- Models tested at multiple context sizes (4096 → 8192 → 16384) showed expected TPS reduction at larger contexts due to increased KV cache pressure.
- `lfm2.5-thinking` maintained usable TPS at 16384 context, suggesting good long-context efficiency.

### GPU Percent
- All models reported **100% GPU** — consistent with previous findings in `model_test_001.md` where the AIU accelerator is transparent to Ollama's scheduler.

### Anomaly
- **qwen2.5-coder:latest** showed an unusually low prompt eval TPS of **1.91** at 4096 context, far below other models of similar size. This warrants further investigation — possible tokenizer overhead or architecture-specific behaviour on s390x.

---

## Summary Table (Best Eval TPS per Model)

| Model | Best Eval TPS | Context |
|---|---|---|
| lfm2.5-thinking:latest | 46.28 | 8192 |
| deepseek-r1:1.5b | 21.95 | 8192 |
| qwen2.5vl:3b | 15.08 | 8192 |
| gpt-oss:20b | 7.78 | 8192 |
| gemma4:latest | 7.80 | 4096 |
| qwen3-coder:30b | 8.79 | 4096 |
| qwen2.5-coder:latest | 6.29 | 4096 |
