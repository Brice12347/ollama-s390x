# Bottleneck Analysis — s390x Ollama Port

## Scope

This document captures current bottleneck hypotheses for the s390x Ollama port across CPU, memory, model load, quantization, and library-path/runtime layout behavior.

## Current Bottleneck Hypotheses

## Hypothesis 1

**Big-endian model-load handling is the first bottleneck to investigate.**

Working statement:
- First-load latency and peak memory usage on s390x are likely dominated by tensor byte-swapping plus the forced fallback from `mmap` to buffered reads.

Why start here:
- It affects every model load.
- The mechanism is already documented in [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md) and [`llama/compat/README.md`](../llama/compat/README.md).
- The expected user-visible effect is already captured in [`docs/api_contract.md`](api_contract.md).

Evidence and supporting references:
- `mmap` is intentionally disabled on big-endian hosts so tensor data can be read into writable buffers before byte-swapping; see [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md) and [`disable_mmap_for()`](../llama/compat/README.md:158).
- Tensor byte-swapping is inserted directly into the llama.cpp model-load path; see [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md).
- The published contract already notes `~0.5–2s` extra load time on first run; see [`docs/api_contract.md`](api_contract.md:630).
- Existing benchmark logs show meaningful first-load variation across models; see [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) and [`logs/model_test_001.md`](../logs/model_test_001.md).

Measurement angles:
- Compare first-load time versus warm-load time across the same model.
- Separate byte-swap cost from non-`mmap` copy cost where possible.
- Compare peak RSS during load against steady-state RSS after the model is ready.
- Check whether quantization format changes the load penalty materially.

## Hypothesis 2

**Prompt evaluation and tokenization overhead may be the next major runtime bottleneck.**

Working statement:
- Some models likely spend a disproportionate amount of time in tokenizer or prompt-processing paths, producing large prompt-evaluation throughput swings that quantization alone does not explain.

Why this is next:
- It affects user-visible latency after load completes.
- Existing benchmark data already shows a strong prompt-eval anomaly for at least one model.
- The architecture notes document VXE2 string/search capabilities, while the tokenizer docs identify regex processing as the main bottleneck, suggesting a mismatch between available hardware features and current implementation paths.

Evidence and supporting references:
- [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md) records an unusually low prompt-eval throughput for `qwen2.5-coder:latest`, explicitly called out as an anomaly at [`logs/model_perf_test_001.md:80`](../logs/model_perf_test_001.md:80).
- The tokenizer README says the current pretokenizer regex is the main encode bottleneck at [`x/imagegen/tokenizer/README.md:67`](../x/imagegen/tokenizer/README.md:67).
- [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) notes that compiler-generated vector code may underperform architecture-aware implementations and that mixed scalar/vector execution reduces effective SIMD use; see [`docs/s390x_architecture_notes.md:288`](s390x_architecture_notes.md:288) and [`docs/s390x_architecture_notes.md:294`](s390x_architecture_notes.md:294).
- VXE2 includes substring/search-oriented instructions relevant to prompt preprocessing; see [`docs/s390x_architecture_notes.md:197`](s390x_architecture_notes.md:197) and [`docs/s390x_architecture_notes.md:204`](s390x_architecture_notes.md:204).

Measurement angles:
- Compare prompt-eval throughput across models with similar size but different tokenizers.
- Break out tokenizer time from prompt-eval time where possible.
- Check whether long prompts amplify the gap more than generation does.
- Compare prompt-eval behavior before and after any tokenizer-path optimizations.

## Hypothesis 3

**Quantization format behavior may be a platform-level bottleneck on s390x.**

Working statement:
- Some quantization formats appear to map poorly to the current s390x execution path, causing unstable throughput or counterintuitive performance where larger or higher-precision formats outperform smaller ones.

Why this is next:
- It affects steady-state inference throughput, not just load time.
- Existing benchmark data already shows format-specific anomalies that simple model-size explanations do not fit.
- The big-endian tensor layout notes show that quantization formats have materially different block layouts and scale-field positions.

Evidence and supporting references:
- [`logs/model_test_001.md`](../logs/model_test_001.md) shows `Q8_0` outperforming `Q4_K_M` for the same 1B model at [`logs/model_test_001.md:59`](../logs/model_test_001.md:59).
- [`logs/model_test_001.md`](../logs/model_test_001.md) flags `Q2_K` as unstable at [`logs/model_test_001.md:60`](../logs/model_test_001.md:60).
- [`logs/model_test_001.md`](../logs/model_test_001.md) notes `F16` underperforming `Q8_0`, likely because larger memory footprint reduces AIU cache efficiency, at [`logs/model_test_001.md:61`](../logs/model_test_001.md:61).
- [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md) shows that quantization formats use different block sizes and different scale-field offsets, including the tail-positioned `Q2_K` layout at [`docs/s390x-big-endian-inference.md:43`](s390x-big-endian-inference.md:43).

Measurement angles:
- Compare tokens/second across quantization formats for the same base model.
- Check whether unstable formats correlate with particular block layouts or scale-field offsets.
- Compare memory footprint and throughput together rather than treating them separately.
- Separate format-specific execution effects from general host-load or accelerator-contention effects.

## Hypothesis 4

**Generic CPU kernel execution and thread auto-selection may be leaving significant throughput on the table.**

Working statement:
- The current s390x path likely depends too heavily on generic compiler-generated kernels and default thread auto-detection, which may underuse VXE/VXE2 and misfit the platform's CPU topology.

Why this is next:
- It directly affects steady-state inference throughput across many models.
- The architecture notes explicitly warn that generic vector code may underperform architecture-aware kernels.
- The current launch path leaves thread count to llama-server auto-detection unless the user overrides it.

Evidence and supporting references:
- [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) states that compiler-generated vector code may not match architecture-aware kernels at [`docs/s390x_architecture_notes.md:288`](s390x_architecture_notes.md:288).
- [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md) also notes mixed scalar/vector execution can reduce effective SIMD utilization at [`docs/s390x_architecture_notes.md:294`](s390x_architecture_notes.md:294).
- [`llm/llama_server.go`](../llm/llama_server.go) shows thread count is only passed when explicitly set; otherwise llama-server auto-detects it at [`llm/llama_server.go:425`](../llm/llama_server.go:425).
- Existing quantization results already suggest execution-path sensitivity across formats, reinforcing the possibility of kernel or threading inefficiency; see [`logs/model_test_001.md`](../logs/model_test_001.md).

Measurement angles:
- Compare default thread auto-detection against explicit thread-count sweeps.
- Compare throughput on representative models before and after any s390x-specific kernel tuning.
- Use profiling to identify scalar fallbacks, short-vector tails, or poor instruction selection in hot paths.
- Check whether throughput scales cleanly with threads or stalls early due to topology or bandwidth limits.

## Hypothesis 5

**Runtime library and backend path discovery may add avoidable startup overhead and layout-sensitive behavior.**

Working statement:
- Runner startup may spend unnecessary time probing multiple build, dist, and installed layouts for binaries and backend libraries, with repeated `Glob` and `Stat` work that can vary by environment.

Why this is next:
- It affects startup and runner initialization rather than steady-state token throughput.
- The current code explicitly searches many candidate paths across development and packaged layouts.
- This is especially relevant when s390x builds use multiple alternate output directories such as `build-*` variants.

Evidence and supporting references:
- [`llm/llama_binary.go`](../llm/llama_binary.go) probes multiple candidate binary locations and checks them one by one at [`llm/llama_binary.go:50`](../llm/llama_binary.go:50).
- [`llm/llama_binary.go`](../llm/llama_binary.go) also searches named build directories such as `build-*` at [`llm/llama_binary.go:119`](../llm/llama_binary.go:119) and build output directories at [`llm/llama_binary.go:146`](../llm/llama_binary.go:146).
- [`llm/llama_server.go`](../llm/llama_server.go) builds library-path lists at [`llm/llama_server.go:499`](../llm/llama_server.go:499) and performs backend selection at [`llm/llama_server.go:535`](../llm/llama_server.go:535).

Measurement angles:
- Time binary lookup and backend-path discovery during runner startup.
- Compare startup cost across clean install layouts versus multi-build development trees.
- Count `Glob` and `Stat` calls during startup on representative environments.
- Check whether path ordering changes backend selection or startup consistency.

## Hypothesis 6

**Accelerator warmup and shared AIU VF contention may be a distinct source of performance variability on s390x.**

Working statement:
- Some observed latency and throughput variance may come less from the model itself and more from AIU JIT warmup and contention for shared AIU virtual functions on the host.

Why this is worth separating:
- It can distort both load-time and steady-state measurements.
- Existing benchmark methodology already had to exclude early runs because of warmup effects.
- Host-level contention can make model-to-model comparisons look worse or less stable than they really are.

Evidence and supporting references:
- [`logs/model_test_001.md`](../logs/model_test_001.md) excludes the first 1–2 runs due to AIU JIT warmup at [`logs/model_test_001.md:18`](../logs/model_test_001.md:18).
- The same log states that AIU JIT-compiles or caches the compute graph on the first 1–2 inferences at [`logs/model_test_001.md:53`](../logs/model_test_001.md:53).
- It also notes that throughput is non-deterministic because other workloads contend for AIU virtual functions at [`logs/model_test_001.md:54`](../logs/model_test_001.md:54).
- [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md) likewise documents warmup exclusion and host-load sensitivity at [`docs/model_compatibility_matrix.md:3`](model_compatibility_matrix.md:3) and [`docs/model_compatibility_matrix.md:57`](model_compatibility_matrix.md:57).

Measurement angles:
- Separate cold-run, warm-run, and restarted-server measurements.
- Record variance across repeated runs at the same model and quantization.
- Correlate low-throughput outliers with shared-host activity where possible.
- Distinguish accelerator warmup effects from model-load, tokenizer, and quantization effects.

### CPU
- Big-endian tensor byte-swap work likely adds extra CPU time during model load.
- Some inference paths are probably memory-bandwidth-limited rather than compute-limited.
- VXE/VXE2 may be enabled, but generic kernels may still leave CPU throughput on the table.
- Mixed scalar/vector paths may reduce effective SIMD utilization.
- Thread auto-detection may not be optimal for s390x topology.
- Tokenizer or prompt-processing overhead may be a disproportionate CPU cost for some models.

### Memory
- Disabling `mmap` on big-endian hosts likely increases peak RSS and copy overhead.
- Writable staging buffers likely introduce extra transient memory pressure during load.
- Larger quantization or FP16 formats likely amplify cache and memory-bandwidth pressure.
- Repeated load/unload cycles may expose allocator or fragmentation costs.

### Model load
- First-load latency likely includes byte-swap cost, copy cost, validation cost, and accelerator warmup effects.
- Large models appear to have noticeably higher load times than small models.
- Load-time overhead is likely sensitive to quantization format and whether data passes through host-buffer or staging-buffer paths.

### Quantization
- `Q4_0` currently appears to be the fastest class in observed testing.
- `Q8_0` may outperform `Q4_K_M` for some 1B-class models on this platform.
- `Q2_K` appears unstable and is a likely performance risk.
- `IQ4_XS` / iQuant-family gaps are a compatibility and performance bottleneck.
- Some quantization layouts may map poorly to current s390x execution paths.

### Library paths and runtime layout
- Binary and backend library discovery may be sensitive to build layout (`build`, `build-*`, `dist`, installed paths).
- Incorrect or suboptimal `LD_LIBRARY_PATH` / backend path ordering could affect runner startup behavior.
- Multiple backend/library locations may introduce avoidable startup probing overhead.

## Benchmark Data
- [`logs/model_perf_test_001.md`](../logs/model_perf_test_001.md)
- [`logs/model_test_001.md`](../logs/model_test_001.md)
- [`docs/model_compatibility_matrix.md`](model_compatibility_matrix.md)
- [`docs/api_contract.md`](api_contract.md)
- [`docs/s390x-big-endian-inference.md`](s390x-big-endian-inference.md)
- [`docs/s390x_architecture_notes.md`](s390x_architecture_notes.md)
