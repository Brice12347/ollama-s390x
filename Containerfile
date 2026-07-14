# vim: filetype=dockerfile
# Containerfile — Ollama for IBM Z / LinuxONE (s390x)
#
# Build:
#   podman build --platform linux/s390x --format oci \
#     -f Containerfile \
#     -t quay.io/brice_patchou/ollama-s390x:latest .
#
# Run:
#   podman run -d --name ollama \
#     -p 127.0.0.1:11434:11434 \
#     -v ollama-data:/home/ollama/.ollama \
#     quay.io/brice_patchou/ollama-s390x:latest
#
# Push:
#   podman push quay.io/brice_patchou/ollama-s390x:latest

ARG CMAKEVERSION=3.31.2
ARG NINJAVERSION=1.12.1

# ---------------------------------------------------------------------------
# Stage 1 — base-s390x
#   Toolchain layer: GCC + OpenBLAS + CMake + Ninja on Ubuntu 24.04 s390x.
#   Ubuntu 24.04 (Noble) ships gcc-13, clang-18, and libopenblas-dev for s390x
#   directly in the ports mirror — no extra repos required.
# ---------------------------------------------------------------------------
FROM --platform=linux/s390x ubuntu:24.04 AS base-s390x

ARG CMAKEVERSION
ARG NINJAVERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        git \
        ccache \
        gcc \
        g++ \
        make \
        libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

# Install CMake from upstream (Ubuntu 24.04 ships 3.28; we need 3.24+ — already
# satisfied, but pin to the same version used in the existing Dockerfile for
# reproducibility).
RUN curl -fsSL \
        https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz \
    | tar xz -C /usr/local --strip-components 1

# Install Ninja
RUN curl -fsSL -o /tmp/ninja.zip \
        https://github.com/ninja-build/ninja/releases/download/v${NINJAVERSION}/ninja-linux.zip \
    && unzip /tmp/ninja.zip -d /usr/local/bin \
    && rm /tmp/ninja.zip

ENV CMAKE_GENERATOR=Ninja
ENV LDFLAGS=-s

# ---------------------------------------------------------------------------
# Stage 2 — llama-server-cpu_s390x
#   Builds llama-server using the cpu_s390x CMake preset, which enables:
#     OLLAMA_S390X_BIGENDIAN=ON  — big-endian GGUF byte-swap support
#     GGML_VXE=ON               — IBM z Vector Extensions (VXE/VXE2, z15+)
#     GGML_BLAS=ON / OpenBLAS   — BLAS matrix acceleration
#     GGML_CPU_ALL_VARIANTS=ON  — ships all CPU dispatch variants
# ---------------------------------------------------------------------------
FROM base-s390x AS llama-server-cpu_s390x

COPY LLAMA_CPP_VERSION .
COPY llama/server llama/server
COPY llama/compat llama/compat

RUN --mount=type=cache,target=/root/.ccache \
    cmake -S llama/server --preset cpu_s390x \
        && cmake --build build/llama-server-cpu_s390x -- -l $(nproc) \
        && cmake --install build/llama-server-cpu_s390x --component llama-server --strip

# ---------------------------------------------------------------------------
# Stage 3 — Go build
#   Compiles the ollama Go binary for linux/s390x with CGO enabled.
# ---------------------------------------------------------------------------
FROM base-s390x AS build

WORKDIR /go/src/github.com/ollama/ollama

COPY go.mod go.sum .

# Download the correct Go toolchain for s390x (uname -m returns s390x).
RUN curl -fsSL \
        https://golang.org/dl/go$(awk '/^go/ { print $2 }' go.mod).linux-s390x.tar.gz \
    | tar xz -C /usr/local

ENV PATH=/usr/local/go/bin:$PATH

RUN go mod download

COPY . .

ARG GOFLAGS="'-ldflags=-w -s'"
ENV CGO_ENABLED=1

RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildmode=pie -o /bin/ollama .

# ---------------------------------------------------------------------------
# Stage 4 — Final runtime image
#   Minimal Ubuntu 24.04 s390x image with:
#     - Non-root user (ollama, uid 10001)
#     - Healthcheck via the Ollama HTTP API
#     - No GPU libraries (s390x is CPU-only)
# ---------------------------------------------------------------------------
FROM --platform=linux/s390x ubuntu:24.04

# Runtime dependencies only — libopenblas0 for the BLAS-accelerated llama-server
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libopenblas0 \
    && rm -rf /var/lib/apt/lists/*

# Copy the ollama binary and the native runtime libraries
COPY --from=build        /bin/ollama              /usr/bin/ollama
COPY --from=llama-server-cpu_s390x \
                         dist/lib/ollama          /usr/lib/ollama

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/lib/ollama

# Non-root user — uid 10001 keeps it outside the standard system uid range
# (IBM container security policy: MUST NOT run as root).
RUN useradd -r -s /sbin/nologin -u 10001 -m -d /home/ollama ollama \
    && mkdir -p /home/ollama/.ollama \
    && chown -R ollama:ollama /home/ollama/.ollama

# Bind to localhost inside the container; callers map it with -p.
# Override with OLLAMA_HOST at runtime if cross-container access is needed.
ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_MODELS=/home/ollama/.ollama/models

EXPOSE 11434

# Healthcheck — polls the Ollama REST API root endpoint.
# start-period gives the model server time to initialise before checks begin.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -sf http://127.0.0.1:11434/ || exit 1

USER ollama

ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]
