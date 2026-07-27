#!/usr/bin/env bash
################################################################################
# dev_install_env.sh
#
# Purpose: Install debugging tools inside a running pod (zCX or OpenShift)
#          to isolate and debug a broken Ollama inference endpoint.
#
# Usage (run inside a pod via oc exec):
#   oc exec -it <pod-name> -c <container> -- bash -c \
#     "curl -fsSL https://raw.githubusercontent.com/Brice12347/ollama-s390x/main/scripts/dev_install_env.sh | bash"
#
# What it installs:
#   - curl, jq, netcat (nc) — HTTP and network diagnostics
#   - ps, ss/netstat       — process and port inspection
#
# What it tests automatically:
#   - Is the Ollama process running?
#   - Is port 11434 listening?
#   - Does GET / return 200?
#   - Does /api/tags respond?
#   - Does /api/generate return a valid response?
################################################################################
set -euo pipefail

OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
BASE_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
MODEL="${DEBUG_MODEL:-smollm:135m}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_fail()    { echo -e "${RED}[FAIL]${NC}    $1"; }
log_section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

################################################################################
# 1. Install dependencies (works on UBI/RHEL and Debian/Ubuntu)
################################################################################
install_deps() {
    log_section "Installing debug tools"

    if command -v microdnf >/dev/null 2>&1; then
        log_info "Using microdnf (UBI minimal)"
        microdnf install -y curl jq procps-ng iproute nmap-ncat 2>/dev/null || \
            microdnf install -y curl jq procps iproute 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        log_info "Using dnf (UBI/RHEL)"
        dnf install -y --nodocs curl jq procps-ng iproute nmap-ncat 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        log_info "Using apt-get (Debian/Ubuntu)"
        apt-get update -qq
        apt-get install -y -qq curl jq procps iproute2 netcat-openbsd 2>/dev/null || true
    else
        log_warn "No known package manager found — skipping tool installation"
    fi

    log_ok "Tool installation complete"
}

################################################################################
# 2. Check: Is the ollama process running?
################################################################################
check_process() {
    log_section "Process check"
    if command -v ps >/dev/null 2>&1; then
        if ps aux 2>/dev/null | grep -q '[o]llama'; then
            log_ok "ollama process is running:"
            ps aux 2>/dev/null | grep '[o]llama' || true
        else
            log_fail "ollama process NOT found in process list"
            log_info "All processes:"
            ps aux 2>/dev/null || true
        fi
    else
        log_warn "ps not available — skipping process check"
    fi
}

################################################################################
# 3. Check: Is port 11434 listening?
################################################################################
check_port() {
    log_section "Port check (${OLLAMA_PORT})"
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep -q ":${OLLAMA_PORT}"; then
            log_ok "Port ${OLLAMA_PORT} is listening:"
            ss -tlnp 2>/dev/null | grep ":${OLLAMA_PORT}" || true
        else
            log_fail "Port ${OLLAMA_PORT} is NOT listening"
            log_info "All listening ports:"
            ss -tlnp 2>/dev/null || true
        fi
    elif command -v nc >/dev/null 2>&1; then
        if nc -z "${OLLAMA_HOST}" "${OLLAMA_PORT}" 2>/dev/null; then
            log_ok "Port ${OLLAMA_PORT} is reachable via nc"
        else
            log_fail "Port ${OLLAMA_PORT} is NOT reachable via nc"
        fi
    else
        log_warn "Neither ss nor nc available — skipping port check"
    fi
}

################################################################################
# 4. Check: HTTP root endpoint
################################################################################
check_root() {
    log_section "HTTP root endpoint (GET /)"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${BASE_URL}/" 2>/dev/null || echo "000")
    if [ "${HTTP_STATUS}" = "200" ]; then
        log_ok "GET / returned HTTP ${HTTP_STATUS}"
        curl -s --max-time 5 "${BASE_URL}/" 2>/dev/null || true
        echo ""
    else
        log_fail "GET / returned HTTP ${HTTP_STATUS} (expected 200)"
        log_info "Full response:"
        curl -sv --max-time 5 "${BASE_URL}/" 2>&1 || true
    fi
}

################################################################################
# 5. Check: /api/tags (model list)
################################################################################
check_tags() {
    log_section "Model list (GET /api/tags)"
    HTTP_STATUS=$(curl -s -o /tmp/tags_response.json -w "%{http_code}" --max-time 5 "${BASE_URL}/api/tags" 2>/dev/null || echo "000")
    if [ "${HTTP_STATUS}" = "200" ]; then
        log_ok "GET /api/tags returned HTTP ${HTTP_STATUS}"
        cat /tmp/tags_response.json 2>/dev/null | (command -v jq >/dev/null 2>&1 && jq . || cat)
        echo ""
    else
        log_fail "GET /api/tags returned HTTP ${HTTP_STATUS}"
        cat /tmp/tags_response.json 2>/dev/null || true
    fi
}

################################################################################
# 6. Check: /api/generate (inference)
################################################################################
check_generate() {
    log_section "Inference endpoint (POST /api/generate)"
    log_info "Testing model: ${MODEL}"

    HTTP_STATUS=$(curl -s -o /tmp/generate_response.json -w "%{http_code}" \
        --max-time 60 \
        -X POST "${BASE_URL}/api/generate" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${MODEL}\",\"prompt\":\"Reply with one word: hello\",\"stream\":false}" \
        2>/dev/null || echo "000")

    if [ "${HTTP_STATUS}" = "200" ]; then
        log_ok "POST /api/generate returned HTTP ${HTTP_STATUS}"
        cat /tmp/generate_response.json 2>/dev/null | (command -v jq >/dev/null 2>&1 && jq '.response' || cat)
        echo ""
    else
        log_fail "POST /api/generate returned HTTP ${HTTP_STATUS}"
        log_info "Full response body:"
        cat /tmp/generate_response.json 2>/dev/null || true
        echo ""
        log_info "Verbose curl output:"
        curl -sv --max-time 60 \
            -X POST "${BASE_URL}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{\"model\":\"${MODEL}\",\"prompt\":\"Reply with one word: hello\",\"stream\":false}" \
            2>&1 || true
    fi
}

################################################################################
# 7. Check: environment variables
################################################################################
check_env() {
    log_section "Environment variables"
    env | grep -i ollama || log_warn "No OLLAMA_* environment variables found"
}

################################################################################
# 8. Check: model files on disk
################################################################################
check_models_dir() {
    log_section "Model files on disk"
    MODEL_DIR="${OLLAMA_MODELS:-/home/ollama/.ollama/models}"
    log_info "OLLAMA_MODELS = ${MODEL_DIR}"
    if [ -d "${MODEL_DIR}" ]; then
        log_ok "Model directory exists: ${MODEL_DIR}"
        find "${MODEL_DIR}" -type f 2>/dev/null | head -20 || true
    else
        log_fail "Model directory NOT found: ${MODEL_DIR}"
        log_info "Contents of /home/ollama (if it exists):"
        ls -la /home/ollama 2>/dev/null || true
        log_info "Contents of /mnt/models (KServe storage mount):"
        ls -la /mnt/models 2>/dev/null || true
    fi
}

################################################################################
# Main
################################################################################
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Ollama Inference Endpoint Debugger                  ║"
    echo "║   Target: ${BASE_URL}"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    install_deps
    check_env
    check_process
    check_port
    check_models_dir
    check_root
    check_tags
    check_generate

    log_section "Debug complete"
    log_info "If all checks above passed, the endpoint is healthy."
    log_info "If /api/generate failed, check model files and OLLAMA_MODELS path."
}

main
