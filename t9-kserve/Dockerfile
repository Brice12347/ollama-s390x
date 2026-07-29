# vim: filetype=dockerfile
# t9-kserve/Dockerfile — Ollama for IBM Z / LinuxONE (s390x), UBI 9 runtime
#
# Build targets:
#   CPU-only (existing):
#     podman build --platform linux/s390x --format docker \
#       -f t9-kserve/Dockerfile \
#       -t quay.io/brice_patchou/ollama-s390x:kserve .
#
#   SIMD/VXE-accelerated (IBM z15 / LinuxONE 3+, -DGGML_VXE=ON):
#     podman build --platform linux/s390x --format docker \
#       -f t9-kserve/Dockerfile \
#       --target runtime-vxe \
#       -t quay.io/brice_patchou/ollama-s390x:kserve-vxe .
#
#   zDNN-accelerated (IBM z17 / LinuxONE 5+, -DGGML_ZDNN=ON):
#     podman build --platform linux/s390x --format docker \
#       -f t9-kserve/Dockerfile \
#       --target runtime-zdnn \
#       -t quay.io/brice_patchou/ollama-s390x:kserve-zdnn .
#
# Push:
#   podman push quay.io/brice_patchou/ollama-s390x:kserve
#   podman push quay.io/brice_patchou/ollama-s390x:kserve-vxe
#   podman push quay.io/brice_patchou/ollama-s390x:kserve-zdnn

ARG CMAKEVERSION=3.31.2
ARG NINJAVERSION=1.12.1

# ---------------------------------------------------------------------------
# Stage 1 — base-s390x
#   Toolchain layer: GCC + OpenBLAS + CMake + Ninja on UBI 9 s390x.
#   UBI 9 (ubi9) ships gcc, make, cmake, and openblas-devel via the
#   standard UBI + CodeReady Linux Builder repos.
# ---------------------------------------------------------------------------
FROM --platform=linux/s390x registry.redhat.io/ubi9/ubi:latest AS base-s390x

RUN dnf install -y --nodocs --allowerasing \
        ca-certificates \
        curl \
        unzip \
        git \
        gcc \
        gcc-c++ \
        make \
        cmake \
        ninja-build \
        pkgconfig \
        openblas-devel \
    && dnf clean all

ENV CMAKE_GENERATOR=Ninja
ENV LDFLAGS=-s

# ---------------------------------------------------------------------------
# Stage 2 — llama-server-cpu_s390x
#   Builds llama-server using the cpu_s390x CMake preset.
#   GGML_VXE=ON (default for s390x); scalar fallback on z14 and older.
# ---------------------------------------------------------------------------
FROM base-s390x AS llama-server-cpu_s390x

COPY LLAMA_CPP_VERSION .
COPY llama/server llama/server
COPY llama/compat llama/compat

RUN cmake -S llama/server --preset cpu_s390x \
        && cmake --build build/llama-server-cpu_s390x -- -l $(nproc) \
        && cmake --install build/llama-server-cpu_s390x --component llama-server --strip

# ---------------------------------------------------------------------------
# Stage 2b — llama-server-cpu_s390x_vxe
#   Dedicated SIMD/VXE runner directory so Ollama can load the VXE-optimised
#   backend on IBM z15 / LinuxONE 3+ while the base payload remains the
#   scalar fallback for older hardware.
#   Compile flags: -DGGML_VXE=ON  -DOLLAMA_S390X_VXE=ON
# ---------------------------------------------------------------------------
FROM base-s390x AS llama-server-s390x_vxe

COPY LLAMA_CPP_VERSION .
COPY llama/server llama/server
COPY llama/compat llama/compat

RUN cmake -S llama/server --preset cpu_s390x \
        -B build/llama-server-s390x_vxe \
        -DOLLAMA_RUNNER_DIR=s390x_vxe \
        -DOLLAMA_S390X_VXE=ON \
        -DOLLAMA_S390X_ZDNN=OFF \
    && cmake --build build/llama-server-s390x_vxe -- -l $(nproc) \
    && cmake --install build/llama-server-s390x_vxe --component llama-server --strip

# ---------------------------------------------------------------------------
# Stage 2c — llama-server-cpu_s390x_zdnn
#   Builds llama-server with IBM zDNN/zAIU co-processor acceleration enabled.
#   Requires the IBM zDNN library (libzdnn) from https://github.com/IBM/zDNN
#   to be installed on the build host.
#   Available on IBM z17 / LinuxONE 5 and later.
#   Compile flags: -DGGML_VXE=ON  -DGGML_ZDNN=ON  -DOLLAMA_S390X_ZDNN=ON
# ---------------------------------------------------------------------------
FROM base-s390x AS llama-server-s390x_zdnn

# Install zDNN library.  The RPM package name on UBI 9 is zdnn-devel; adjust
# if your build environment installs zDNN from a different source.
RUN dnf install -y --nodocs zdnn-devel 2>/dev/null || \
    echo "WARNING: zdnn-devel not found via dnf; ensure libzdnn.so is present at link time."

COPY LLAMA_CPP_VERSION .
COPY llama/server llama/server
COPY llama/compat llama/compat

RUN cmake -S llama/server --preset cpu_s390x_zdnn \
        -B build/llama-server-s390x_zdnn \
        -DOLLAMA_RUNNER_DIR=s390x_zdnn \
        -DOLLAMA_S390X_VXE=ON \
        -DOLLAMA_S390X_ZDNN=ON \
    && cmake --build build/llama-server-s390x_zdnn -- -l $(nproc) \
    && cmake --install build/llama-server-s390x_zdnn --component llama-server --strip

# ---------------------------------------------------------------------------
# Stage 3 — Go build
#   Compiles the ollama Go binary for linux/s390x with CGO enabled.
# ---------------------------------------------------------------------------
FROM base-s390x AS build

WORKDIR /go/src/github.com/ollama/ollama

COPY go.mod go.sum .

RUN curl -fsSL \
        https://golang.org/dl/go$(awk '/^go/ { print $2 }' go.mod).linux-s390x.tar.gz \
    | tar xz -C /usr/local

ENV PATH=/usr/local/go/bin:$PATH

RUN go mod download

COPY . .

ENV CGO_ENABLED=1

RUN --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -buildmode=pie -o /bin/ollama .

# ---------------------------------------------------------------------------
# Stage 4 — UBI 9 minimal runtime (KServe / OpenShift AI compatible)
#   Red Hat UBI 9 minimal satisfies OpenShift AI / KServe image policy.
#   microdnf is the package manager in ubi-minimal.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Stage 4 — UBI 9 minimal runtime — CPU-only / scalar fallback (default)
#   Tag: quay.io/brice_patchou/ollama-s390x:kserve
#   Runs on any IBM Z / LinuxONE generation (z14 and later).
#   On z15+ hosts GGML will automatically use VXE SIMD via the standard
#   cpu_s390x payload when the runtime CPU feature detection matches.
# ---------------------------------------------------------------------------
FROM --platform=linux/s390x registry.redhat.io/ubi9/ubi-minimal:latest AS runtime

RUN microdnf install -y openblas --nodocs \
    && microdnf clean all

COPY --from=build                  /bin/ollama       /usr/bin/ollama
COPY --from=llama-server-cpu_s390x dist/lib/ollama   /usr/lib/ollama

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/lib/ollama

# Non-root user — uid 10001 keeps it outside the standard system uid range.
RUN useradd -r -s /sbin/nologin -u 10001 -m -d /home/ollama ollama \
    && mkdir -p /home/ollama/.ollama \
    && chown -R ollama:ollama /home/ollama/.ollama

# Default to localhost; KServe's ServingRuntime overrides OLLAMA_HOST to
# 0.0.0.0 via env so the sidecar proxy can reach the server.
ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_MODELS=/home/ollama/.ollama/models

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -sf http://127.0.0.1:11434/ || exit 1

USER 10001

ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]

# ---------------------------------------------------------------------------
# Stage 5 — VXE-accelerated runtime (IBM z15 / LinuxONE 3+)
#   Tag: quay.io/brice_patchou/ollama-s390x:kserve-vxe
#   Includes the s390x_vxe runner directory alongside the base CPU payload.
#   GGML selects VXE SIMD automatically when running on a z15+ host.
#   On older hardware it silently falls back to the scalar CPU implementation.
#   Compile flag: -DGGML_VXE=ON (via OLLAMA_S390X_VXE=ON)
# ---------------------------------------------------------------------------
FROM --platform=linux/s390x registry.redhat.io/ubi9/ubi-minimal:latest AS runtime-vxe

RUN microdnf install -y openblas --nodocs \
    && microdnf clean all

COPY --from=build                   /bin/ollama      /usr/bin/ollama
# Base CPU payload (llama-server + shared libs in lib/ollama/)
COPY --from=llama-server-cpu_s390x  dist/lib/ollama  /usr/lib/ollama
# VXE runner directory (lib/ollama/s390x_vxe/)
COPY --from=llama-server-s390x_vxe  dist/lib/ollama/s390x_vxe  /usr/lib/ollama/s390x_vxe

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/lib/ollama

RUN useradd -r -s /sbin/nologin -u 10001 -m -d /home/ollama ollama \
    && mkdir -p /home/ollama/.ollama \
    && chown -R ollama:ollama /home/ollama/.ollama

ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_MODELS=/home/ollama/.ollama/models

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -sf http://127.0.0.1:11434/ || exit 1

USER 10001

ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]

# ---------------------------------------------------------------------------
# Stage 6 — zDNN-accelerated runtime (IBM z17 / LinuxONE 5+)
#   Tag: quay.io/brice_patchou/ollama-s390x:kserve-zdnn
#   Includes the s390x_zdnn runner directory alongside the base CPU payload.
#   GGML selects the zAIU co-processor when running on a z17+ host.
#   On older hardware (e.g. z15) it silently falls back to CPU routines.
#   Compile flags: -DGGML_VXE=ON -DGGML_ZDNN=ON (via OLLAMA_S390X_ZDNN=ON)
#   NOTE: the libzdnn runtime library must be present on the target host.
# ---------------------------------------------------------------------------
FROM --platform=linux/s390x registry.redhat.io/ubi9/ubi-minimal:latest AS runtime-zdnn

RUN microdnf install -y openblas --nodocs \
    && microdnf clean all

COPY --from=build                    /bin/ollama      /usr/bin/ollama
# Base CPU payload
COPY --from=llama-server-cpu_s390x   dist/lib/ollama  /usr/lib/ollama
# zDNN runner directory (lib/ollama/s390x_zdnn/)
COPY --from=llama-server-s390x_zdnn  dist/lib/ollama/s390x_zdnn  /usr/lib/ollama/s390x_zdnn

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/lib/ollama

RUN useradd -r -s /sbin/nologin -u 10001 -m -d /home/ollama ollama \
    && mkdir -p /home/ollama/.ollama \
    && chown -R ollama:ollama /home/ollama/.ollama

ENV OLLAMA_HOST=127.0.0.1:11434
ENV OLLAMA_MODELS=/home/ollama/.ollama/models

EXPOSE 11434

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -sf http://127.0.0.1:11434/ || exit 1

USER 10001

ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]
