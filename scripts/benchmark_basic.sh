#!/usr/bin/env bash
# =============================================================================
# benchmark_basic.sh — Ollama LLM benchmark for IBM Z (s390x)
# =============================================================================
#
# Measures six key performance metrics against a running Ollama server:
#
#   1. Server Startup Time  — wall-clock from `ollama serve` launch to /api/version 200
#   2. Model Load Time      — load_duration from /api/generate (cold vs warm)
#   3. Time to First Token  — wall-clock from streaming request start to first chunk
#   4. Prompt Eval TPS      — prompt_eval_count / (prompt_eval_duration / 1e9)
#   5. Generation Throughput— eval_count / (eval_duration / 1e9)
#   6. Memory Usage         — /api/ps model size + /proc/<pid>/status VmRSS/VmPeak
#
# S390x notes:
#   - AIU JIT-compiles on first 1-2 inferences; WARMUP_RUNS=2 is the minimum.
#   - Big-endian tensor byte-swap adds load time; cold model load time is key.
#   - /proc/PID/status is the authoritative memory source; pgrep may be absent.
#
# Usage:
#   ./benchmark_basic.sh [OPTIONS]
#
# Options:
#   --model   MODEL   Model tag to benchmark        (default: llama3.2:1b)
#   --runs    N       Number of benchmark runs       (default: 10)
#   --warmup  N       Number of warmup runs          (default: 2)
#   --output  DIR     Directory for result files     (default: ./benchmark_results)
#   --host    URL     Ollama server base URL         (default: http://localhost:11434)
#   --startup         Measure server startup time (launches ollama serve)
#   --cold            Force cold model load before benchmark (unload between runs)
#   --help            Print this help and exit
#
# Examples:
#   ./benchmark_basic.sh
#   ./benchmark_basic.sh --model smollm:360m --runs 15
#   ./benchmark_basic.sh --model granite3.3:2b --startup --cold
#   ./benchmark_basic.sh --host http://192.168.1.10:11434 --output ./results
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION — override via environment variables or CLI flags
# =============================================================================

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
MODEL="${MODEL:-llama3.2:1b}"
WARMUP_RUNS="${WARMUP_RUNS:-2}"
BENCH_RUNS="${BENCH_RUNS:-10}"
NUM_PREDICT="${NUM_PREDICT:-80}"
OUTPUT_DIR="${OUTPUT_DIR:-./benchmark_results}"

# Fixed prompt — consistent with logs/model_test_001.md methodology
PROMPT="List 3 facts about the ocean."

# Standard inference options — temperature=0 and seed=42 for reproducibility
INFER_OPTIONS='{"num_predict":'"${NUM_PREDICT}"',"temperature":0,"seed":42}'

# Timestamp for output directory naming (set once at script start)
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Feature flags (set by CLI parsing below)
MEASURE_STARTUP=false
COLD_LOAD=false

# =============================================================================
# COLOURS — only if connected to a terminal
# =============================================================================

if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# =============================================================================
# HELPERS
# =============================================================================

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# Floating-point division via awk, 3 decimal places
awk_div() {
  # awk_div <numerator> <denominator>
  awk -v n="$1" -v d="$2" 'BEGIN { if (d==0) print "0"; else printf "%.3f\n", n/d }' 2>/dev/null || echo "0"
}

# Nanoseconds → milliseconds (3 dp)
ns_to_ms() {
  awk_div "$1" "1000000"
}

# Nanoseconds → tokens-per-second given a token count
# tps <count> <duration_ns>
tps() {
  local count="$1"
  local dur_ns="$2"
  if [ "${dur_ns:-0}" -le 0 ] 2>/dev/null; then
    echo "0"
    return
  fi
  awk -v c="${count}" -v d="${dur_ns}" 'BEGIN { if (d==0) print "0"; else printf "%.3f\n", c / (d / 1000000000) }' 2>/dev/null || echo "0"
}

# Compute median of a bash array of numbers
# Usage: median_of <val1> <val2> ...
median_of() {
  local sorted
  # Read all args, sort numerically, pick the middle element
  IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "$@" | sort -n && printf '\0') || true
  local n="${#sorted[@]}"
  if [ "$n" -eq 0 ]; then echo "0"; return; fi
  local mid=$(( n / 2 ))
  echo "${sorted[$mid]}"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
  grep '^#' "$0" | grep -A100 'Usage:' | grep -B100 '^# ====' | grep '^#' \
    | sed 's/^# \{0,1\}//' | head -n 40
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)   MODEL="$2";      shift 2 ;;
    --runs)    BENCH_RUNS="$2"; shift 2 ;;
    --warmup)  WARMUP_RUNS="$2"; shift 2 ;;
    --output)  OUTPUT_DIR="$2"; shift 2 ;;
    --host)    OLLAMA_HOST="$2"; shift 2 ;;
    --startup) MEASURE_STARTUP=true; shift ;;
    --cold)    COLD_LOAD=true;   shift ;;
    --help|-h) usage ;;
    *) die "Unknown option: $1  (try --help)" ;;
  esac
done

# Sanitise model name for use in directory/file names (replace : and / with -)
MODEL_SAFE="${MODEL//:/-}"
MODEL_SAFE="${MODEL_SAFE//\//-}"

# =============================================================================
# PRE-FLIGHT CHECKS — tools
# =============================================================================

log_info "Running pre-flight checks..."

for cmd in curl jq awk; do
  if ! command -v "$cmd" &>/dev/null; then
    die "Required tool '${cmd}' not found. Install it and retry."
  fi
done
log_ok "curl, jq, awk all available."

# =============================================================================
# PRE-FLIGHT CHECKS — Ollama server reachable
# =============================================================================

log_info "Checking Ollama server at ${OLLAMA_HOST} ..."

OLLAMA_VERSION=""
if OLLAMA_VERSION=$(curl -sf --max-time 5 "${OLLAMA_HOST}/api/version" 2>/dev/null); then
  VER=$(echo "${OLLAMA_VERSION}" | jq -r '.version // "unknown"')
  log_ok "Ollama server is up — version: ${VER}"
else
  die "Cannot reach Ollama server at ${OLLAMA_HOST}/api/version.
  Make sure 'ollama serve' is running, or pass --host to specify the address.
  If you want to measure startup time, use the --startup flag."
fi

# =============================================================================
# PRE-FLIGHT CHECKS — Model available locally
# =============================================================================

log_info "Checking that model '${MODEL}' is pulled..."

TAGS_RESPONSE=$(curl -sf --max-time 10 "${OLLAMA_HOST}/api/tags" 2>/dev/null) || true
if [ -n "${TAGS_RESPONSE}" ]; then
  if echo "${TAGS_RESPONSE}" | jq -e --arg m "${MODEL}" \
      '.models[] | select(.name == $m)' &>/dev/null; then
    log_ok "Model '${MODEL}' found locally."
  else
    log_warn "Model '${MODEL}' not found in /api/tags. It may need to be pulled first."
    log_warn "  Run: ollama pull ${MODEL}"
    log_warn "Continuing — if the model is absent, generate requests will fail."
  fi
else
  log_warn "Could not fetch /api/tags — skipping model availability check."
fi

# =============================================================================
# OUTPUT DIRECTORY SETUP
# =============================================================================

RUN_DIR="${OUTPUT_DIR}/${TIMESTAMP}_${MODEL_SAFE}"
mkdir -p "${RUN_DIR}"
log_ok "Output directory: ${RUN_DIR}"

METRICS_CSV="${RUN_DIR}/metrics.csv"
SUMMARY_TXT="${RUN_DIR}/summary.txt"
RAWJSONL="${RUN_DIR}/raw_responses.jsonl"

# Write CSV header
echo "run,model,prompt_eval_tps,eval_tps,load_duration_ms,total_duration_ms,ttft_ms,memory_vmrss_mib" \
  > "${METRICS_CSV}"

# Truncate/create JSONL file
: > "${RAWJSONL}"

# =============================================================================
# METRIC 1 — SERVER STARTUP TIME
# Only measured when --startup flag is passed. The script launches `ollama serve`
# as a background process and polls /api/version until it responds (or times out).
# This measures wall-clock startup latency, which on s390x includes library
# initialisation and AIU device discovery.
# =============================================================================

STARTUP_TIME_MS="N/A"

if [ "${MEASURE_STARTUP}" = true ]; then
  log_info "=== METRIC 1: Server Startup Time ==="
  log_info "Killing any existing ollama serve process first..."
  pkill -f 'ollama serve' 2>/dev/null || true
  sleep 1

  log_info "Launching 'ollama serve' in background..."
  ollama serve &>/tmp/ollama_serve_startup.log &
  SERVE_PID=$!

  POLL_INTERVAL_MS=100
  TIMEOUT_MS=30000
  ELAPSED_MS=0
  STARTUP_TIME_MS=""

  log_info "Polling ${OLLAMA_HOST}/api/version (max 30s, 100ms intervals)..."
  while [ "${ELAPSED_MS}" -lt "${TIMEOUT_MS}" ]; do
    if curl -sf --max-time 1 "${OLLAMA_HOST}/api/version" &>/dev/null; then
      STARTUP_TIME_MS="${ELAPSED_MS}"
      break
    fi
    sleep 0.1
    ELAPSED_MS=$(( ELAPSED_MS + POLL_INTERVAL_MS ))
  done

  if [ -z "${STARTUP_TIME_MS}" ]; then
    log_warn "Server did not respond within 30 seconds. Startup time: TIMEOUT"
    STARTUP_TIME_MS="TIMEOUT"
  else
    log_ok "Server startup time: ${STARTUP_TIME_MS} ms"
  fi

  echo "startup_time_ms=${STARTUP_TIME_MS}" >> "${RUN_DIR}/startup.txt"
fi

# =============================================================================
# METRIC 2 — MODEL LOAD TIME (cold vs warm)
# The first generate request loads the model into memory. On s390x, the
# big-endian tensor byte-swap occurs during this load, making it substantially
# longer than on x86. We capture load_duration from the JSON response.
#
# Cold load: unload model via keep_alive=0, then reload on next request.
# Warm load: model already in memory; load_duration reflects cache behaviour.
# =============================================================================

log_info "=== METRIC 2: Model Load Time (cold) ==="

# Helper — unload model by posting with keep_alive=0
unload_model() {
  log_info "Unloading model '${MODEL}' from memory (keep_alive=0)..."
  curl -sf --max-time 60 -X POST "${OLLAMA_HOST}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"\",\"keep_alive\":0}" \
    &>/dev/null || log_warn "Unload request failed (model may not have been loaded)."
  # Wait for server to fully evict the model before proceeding
  sleep 3
}

# Helper — run a single non-streaming generate request and return the full JSON.
# The server may return multiple NDJSON lines even with stream:false; the final
# line is the one with "done":true and all duration fields populated.
# Usage: run_generate  →  prints the done:true JSON object to stdout
run_generate() {
  curl -sf --max-time 300 -X POST "${OLLAMA_HOST}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{
          \"model\": \"${MODEL}\",
          \"prompt\": \"${PROMPT}\",
          \"stream\": false,
          \"options\": ${INFER_OPTIONS}
        }" \
  | awk 'END{print}'
}

# Cold load measurement — ensure model is NOT in memory first
unload_model

COLD_RESP=$(run_generate) \
  || die "Cold generate request failed. Is the model pulled? (ollama pull ${MODEL})"

COLD_LOAD_NS=$(echo "${COLD_RESP}" | jq -r '.load_duration // 0')
COLD_LOAD_MS=$(ns_to_ms "${COLD_LOAD_NS}")
log_ok "Cold model load time: ${COLD_LOAD_MS} ms"

# Warm load measurement — model should now be in memory
WARM_RESP=$(run_generate) \
  || die "Warm generate request failed."

WARM_LOAD_NS=$(echo "${WARM_RESP}" | jq -r '.load_duration // 0')
WARM_LOAD_MS=$(ns_to_ms "${WARM_LOAD_NS}")
log_ok "Warm model load time: ${WARM_LOAD_MS} ms"

echo "cold_load_time_ms=${COLD_LOAD_MS}" >> "${RUN_DIR}/load_times.txt"
echo "warm_load_time_ms=${WARM_LOAD_MS}" >> "${RUN_DIR}/load_times.txt"

# =============================================================================
# METRIC 3 — TIME TO FIRST TOKEN (TTFT)
# Uses a streaming request (stream:true). curl's --no-buffer causes it to
# flush each NDJSON chunk as it arrives. We record wall-clock time from the
# moment the request is sent until the first non-empty line is received.
#
# This is important on s390x / AIU because AIU JIT latency can add hundreds
# of milliseconds before the first token appears, even on warm models.
# =============================================================================

log_info "=== METRIC 3: Time to First Token (TTFT) ==="

# Ensure model is warm for TTFT measurement (avoids conflating load with TTFT)
run_generate &>/dev/null || true

TTFT_MS="N/A"

# Write the streaming response to a temp FIFO so we can time first-line arrival
TTFT_TMPFILE=$(mktemp /tmp/ollama_ttft_XXXXXX)

# Record start time in nanoseconds using date %N (available on Linux/GNU date)
if date +%N &>/dev/null 2>&1 && [ "$(date +%N)" != "%N" ]; then
  # GNU date with nanosecond support available
  T_START_NS=$(date +%s%N)

  # Stream into temp file; the subshell exits after first successful read
  curl -sf --no-buffer --max-time 60 -X POST "${OLLAMA_HOST}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{
          \"model\": \"${MODEL}\",
          \"prompt\": \"${PROMPT}\",
          \"stream\": true,
          \"options\": ${INFER_OPTIONS}
        }" \
    > "${TTFT_TMPFILE}" 2>/dev/null &
  CURL_PID=$!

  # Poll the temp file for the first non-empty line that contains a token chunk
  TTFT_ELAPSED=0
  TTFT_TIMEOUT=60000  # 60s timeout
  while [ "${TTFT_ELAPSED}" -lt "${TTFT_TIMEOUT}" ]; do
    FIRST_LINE=$(head -n1 "${TTFT_TMPFILE}" 2>/dev/null || true)
    if [ -n "${FIRST_LINE}" ]; then
      T_FIRST_NS=$(date +%s%N)
      TTFT_MS=$(awk -v a="${T_FIRST_NS}" -v b="${T_START_NS}" 'BEGIN { printf "%.3f\n", (a - b) / 1000000 }' 2>/dev/null || echo "N/A")
      break
    fi
    sleep 0.01
    TTFT_ELAPSED=$(( TTFT_ELAPSED + 10 ))
  done

  # Let curl finish streaming in the background (so we don't leave zombies)
  wait "${CURL_PID}" 2>/dev/null || true

  if [ "${TTFT_MS}" = "N/A" ] || [ -z "${TTFT_MS}" ]; then
    log_warn "TTFT measurement timed out or failed."
    TTFT_MS="N/A"
  else
    log_ok "Time to first token: ${TTFT_MS} ms"
  fi
else
  log_warn "GNU date with nanosecond support not available — skipping TTFT measurement."
  TTFT_MS="N/A"
fi

rm -f "${TTFT_TMPFILE}"

# =============================================================================
# METRIC 6 — MEMORY USAGE
# Queried after at least one generate request (model is loaded).
#
# Two sources:
#   a) /api/ps — Ollama reports model size in bytes for loaded models.
#      This is the GGUF file size mapped into memory, not actual RSS.
#
#   b) /proc/<pid>/status — VmRSS (resident set size) and VmPeak (peak virtual).
#      These are the authoritative Linux memory figures for the ollama process.
#      pgrep may not be present on all s390x images; we fall back to scanning
#      /proc directly.
#
# =============================================================================

log_info "=== METRIC 6: Memory Usage ==="

# --- a) /api/ps model size ---
MODEL_SIZE_MIB="N/A"
PS_RESP=$(curl -sf --max-time 10 "${OLLAMA_HOST}/api/ps" 2>/dev/null) || true
if [ -n "${PS_RESP}" ]; then
  MODEL_SIZE_BYTES=$(echo "${PS_RESP}" | \
    jq -r --arg m "${MODEL}" \
      '[.models[] | select(.name == $m)] | first | .size // 0' 2>/dev/null || echo "0")
  if [ "${MODEL_SIZE_BYTES:-0}" -gt 0 ] 2>/dev/null; then
    MODEL_SIZE_MIB=$(awk -v b="${MODEL_SIZE_BYTES}" 'BEGIN { printf "%.1f\n", b / 1048576 }' 2>/dev/null || echo "N/A")
    log_ok "Model size (/api/ps): ${MODEL_SIZE_MIB} MiB"
  else
    log_warn "/api/ps returned no size for model '${MODEL}' — model may not be loaded."
  fi
else
  log_warn "Could not fetch /api/ps."
fi

# --- b) /proc/PID/status ---
MEMORY_VMRSS_MIB="N/A"
MEMORY_VMPEAK_MIB="N/A"

find_ollama_pid() {
  # Try pgrep first (fastest)
  if command -v pgrep &>/dev/null; then
    pgrep -f 'ollama serve' 2>/dev/null | head -n1 && return
  fi
  # Fallback: scan /proc for the process — works even without pgrep
  for pid_dir in /proc/[0-9]*/cmdline; do
    local pid
    pid=$(echo "${pid_dir}" | grep -o '[0-9]*')
    if [ -r "${pid_dir}" ]; then
      cmdline=$(tr '\0' ' ' < "${pid_dir}" 2>/dev/null || true)
      if echo "${cmdline}" | grep -q 'ollama serve'; then
        echo "${pid}"
        return
      fi
    fi
  done
}

OLLAMA_PID=$(find_ollama_pid || true)

if [ -n "${OLLAMA_PID}" ] && [ -r "/proc/${OLLAMA_PID}/status" ]; then
  VMRSS_KB=$(grep '^VmRSS:' "/proc/${OLLAMA_PID}/status" | awk '{print $2}' || echo "0")
  VMPEAK_KB=$(grep '^VmPeak:' "/proc/${OLLAMA_PID}/status" | awk '{print $2}' || echo "0")

  if [ "${VMRSS_KB:-0}" -gt 0 ] 2>/dev/null; then
    MEMORY_VMRSS_MIB=$(awk -v k="${VMRSS_KB}" 'BEGIN { printf "%.1f\n", k / 1024 }' 2>/dev/null || echo "N/A")
    MEMORY_VMPEAK_MIB=$(awk -v k="${VMPEAK_KB}" 'BEGIN { printf "%.1f\n", k / 1024 }' 2>/dev/null || echo "N/A")
    log_ok "VmRSS: ${MEMORY_VMRSS_MIB} MiB  |  VmPeak: ${MEMORY_VMPEAK_MIB} MiB  (PID ${OLLAMA_PID})"
  else
    log_warn "VmRSS read as zero — /proc/${OLLAMA_PID}/status may be stale."
  fi
elif [ -z "${OLLAMA_PID}" ]; then
  log_warn "'ollama serve' process not found — skipping /proc memory read."
  log_warn "  (The server may be running under a different process name or in a container.)"
else
  log_warn "/proc/${OLLAMA_PID}/status not readable — skipping VmRSS measurement."
fi

# =============================================================================
# WARMUP RUNS
# On s390x / AIU, the first 1-2 inferences trigger JIT compilation of the
# compute graph. These runs are discarded; their purpose is to bring the AIU
# to steady-state before we measure anything.
# =============================================================================

echo ""
log_info "=== WARMUP (${WARMUP_RUNS} runs — discarded) ==="

for ((w=1; w<=WARMUP_RUNS; w++)); do
  log_info "  Warmup ${w}/${WARMUP_RUNS}..."
  run_generate &>/dev/null \
    || log_warn "  Warmup run ${w} failed — continuing."
done
log_ok "Warmup complete."

# =============================================================================
# MAIN BENCHMARK LOOP
# Runs BENCH_RUNS generate requests. For each run we capture:
#   - load_duration_ns   → load_duration_ms
#   - prompt_eval_count + prompt_eval_duration → prompt_eval_tps
#   - eval_count + eval_duration               → eval_tps
#   - total_duration_ns  → total_duration_ms
#   - TTFT (measured once above; reused here)
#   - VmRSS (measured once above; reused here — memory doesn't change per run)
#
# If --cold is set, the model is unloaded before each run to force a cold load
# on every iteration. This is useful for benchmarking pure load latency.
# =============================================================================

echo ""
log_info "=== BENCHMARK (${BENCH_RUNS} runs) ==="

LOAD_DUR_MS_ARR=()
PROMPT_TPS_ARR=()
EVAL_TPS_ARR=()
TOTAL_DUR_MS_ARR=()

for ((r=1; r<=BENCH_RUNS; r++)); do
  log_info "  Run ${r}/${BENCH_RUNS}..."

  # Optionally force cold load on every run
  if [ "${COLD_LOAD}" = true ]; then
    unload_model
  fi

  RESP=$(run_generate) || {
    log_warn "  Run ${r} failed — skipping."
    continue
  }

  # Append raw JSON to JSONL file (one object per line)
  echo "${RESP}" >> "${RAWJSONL}"

  # Extract raw nanosecond durations and token counts
  R_LOAD_NS=$(echo "${RESP}"       | jq -r '.load_duration         // 0')
  R_PE_COUNT=$(echo "${RESP}"      | jq -r '.prompt_eval_count     // 0')
  R_PE_DUR_NS=$(echo "${RESP}"     | jq -r '.prompt_eval_duration  // 0')
  R_EVAL_COUNT=$(echo "${RESP}"    | jq -r '.eval_count            // 0')
  R_EVAL_DUR_NS=$(echo "${RESP}"   | jq -r '.eval_duration         // 0')
  R_TOTAL_NS=$(echo "${RESP}"      | jq -r '.total_duration        // 0')

  # Convert to human-readable units
  R_LOAD_MS=$(ns_to_ms   "${R_LOAD_NS}")
  R_TOTAL_MS=$(ns_to_ms  "${R_TOTAL_NS}")
  R_PE_TPS=$(tps  "${R_PE_COUNT}"   "${R_PE_DUR_NS}")
  R_EVAL_TPS=$(tps "${R_EVAL_COUNT}" "${R_EVAL_DUR_NS}")

  # Accumulate into arrays for median computation
  LOAD_DUR_MS_ARR+=("${R_LOAD_MS}")
  PROMPT_TPS_ARR+=("${R_PE_TPS}")
  EVAL_TPS_ARR+=("${R_EVAL_TPS}")
  TOTAL_DUR_MS_ARR+=("${R_TOTAL_MS}")

  # Append to CSV — TTFT and memory were measured once and are reused per row
  echo "${r},${MODEL},${R_PE_TPS},${R_EVAL_TPS},${R_LOAD_MS},${R_TOTAL_MS},${TTFT_MS},${MEMORY_VMRSS_MIB}" \
    >> "${METRICS_CSV}"

  log_info "    load=${R_LOAD_MS}ms  pe_tps=${R_PE_TPS}  eval_tps=${R_EVAL_TPS}  total=${R_TOTAL_MS}ms"
done

log_ok "Benchmark runs complete."

# =============================================================================
# COMPUTE MEDIANS
# Sort each array numerically and pick the middle element.
# Median is more robust than mean for AIU benchmarks — occasional AIU VF
# contention can produce large outliers that would skew the mean significantly.
# =============================================================================

log_info "Computing medians..."

MEDIAN_LOAD_MS=$(median_of   "${LOAD_DUR_MS_ARR[@]:-0}")
MEDIAN_PE_TPS=$(median_of    "${PROMPT_TPS_ARR[@]:-0}")
MEDIAN_EVAL_TPS=$(median_of  "${EVAL_TPS_ARR[@]:-0}")
MEDIAN_TOTAL_MS=$(median_of  "${TOTAL_DUR_MS_ARR[@]:-0}")

# =============================================================================
# WRITE SUMMARY
# =============================================================================

{
  echo "=========================================================="
  echo "  Ollama s390x Benchmark — Summary"
  echo "=========================================================="
  echo "  Timestamp : ${TIMESTAMP}"
  echo "  Host      : ${OLLAMA_HOST}"
  echo "  Model     : ${MODEL}"
  echo "  Runs      : ${BENCH_RUNS} benchmark  +  ${WARMUP_RUNS} warmup"
  echo "  Prompt    : ${PROMPT}"
  echo "  num_predict: ${NUM_PREDICT}  temperature: 0  seed: 42"
  echo "----------------------------------------------------------"
  echo "  METRIC 1 — Server Startup Time"
  echo "    startup_time_ms         : ${STARTUP_TIME_MS}"
  echo ""
  echo "  METRIC 2 — Model Load Time"
  echo "    cold_load_time_ms       : ${COLD_LOAD_MS}"
  echo "    warm_load_time_ms       : ${WARM_LOAD_MS}"
  echo "    median_load_time_ms     : ${MEDIAN_LOAD_MS}"
  echo ""
  echo "  METRIC 3 — Time to First Token"
  echo "    ttft_ms                 : ${TTFT_MS}"
  echo ""
  echo "  METRIC 4 — Prompt Eval Throughput"
  echo "    median_prompt_eval_tps  : ${MEDIAN_PE_TPS} tok/s"
  echo ""
  echo "  METRIC 5 — Generation Throughput"
  echo "    median_eval_tps         : ${MEDIAN_EVAL_TPS} tok/s"
  echo ""
  echo "  METRIC 6 — Memory"
  echo "    model_size_mib          : ${MODEL_SIZE_MIB}"
  echo "    memory_vmrss_mib        : ${MEMORY_VMRSS_MIB}"
  echo "    memory_vmpeak_mib       : ${MEMORY_VMPEAK_MIB}"
  echo "----------------------------------------------------------"
  echo "  Median total_duration_ms  : ${MEDIAN_TOTAL_MS}"
  echo "=========================================================="
  echo ""
  echo "  Output files:"
  echo "    metrics.csv        : ${METRICS_CSV}"
  echo "    raw_responses.jsonl: ${RAWJSONL}"
  echo "    summary.txt        : ${SUMMARY_TXT}"
  if [ "${MEASURE_STARTUP}" = true ]; then
    echo "    startup.txt        : ${RUN_DIR}/startup.txt"
  fi
  echo "  load_times.txt       : ${RUN_DIR}/load_times.txt"
  echo "=========================================================="
} | tee "${SUMMARY_TXT}"

log_ok "Done. Results saved to ${RUN_DIR}/"
