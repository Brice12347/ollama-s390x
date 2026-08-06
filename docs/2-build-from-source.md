# Step 2 — Build Ollama from Source on s390x

Build Ollama directly on an IBM Z (s390x) machine when you need a customised binary,
want to test a patch, or cannot use the pre-built installer.

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Go | 1.22 | `apt install golang-go` or [go.dev/doc/install](https://go.dev/doc/install) |
| CMake | 3.24 | `apt install cmake` |
| GCC / G++ | 11 | `apt install build-essential` |
| Ninja | any | `apt install ninja-build` (recommended) |
| Git | any | `apt install git` |
| OpenBLAS | any | `apt install libopenblas-dev` |

Install all at once on Ubuntu 22.04 / Debian 12:

```sh
sudo apt update && sudo apt install -y \
  build-essential cmake ninja-build git \
  golang-go libopenblas-dev
```

---

## Clone the repo

```sh
git clone https://github.com/Brice12347/ollama-s390x.git
cd ollama-s390x
```

---

## Full build (C++ inference engine + Go binary)

Run this from the repository root for a fresh checkout or after changing any native C++ code.
The CMake configure step applies the three endianness patches automatically before compiling llama.cpp.

```sh
cmake -B build .
cmake --build build --parallel 8
```

After a successful build:
- The `ollama` binary is at the repository root
- Shared libraries are under `build/lib/ollama/`

Start the server:

```sh
./ollama serve
```

In a second terminal, run a model:

```sh
./ollama run smollm:135m "Hello"
```

---

## Quick Go-only iteration

If you already have a native payload from a previous full build (or from the installer),
you can skip the CMake step for Go-only changes:

```sh
go build .
go run . serve
```

> **Note:** If native code and Go data structures get out of sync, clean the cache first:
> ```sh
> go clean -cache && cmake -B build . && cmake --build build --parallel 8
> ```

---

## Install from your build

To install into a standard prefix layout (e.g. `/usr/local`):

```sh
cmake --install build --prefix /usr/local
```

This puts the binary at `/usr/local/bin/ollama` and libraries under `/usr/local/lib/ollama/`.

---

## How the endianness patches are applied

The three patches in [`llama/compat/`](../llama/compat/) are applied automatically
by `apply-patch.cmake` during `cmake -B build .` via CMake's FetchContent `PATCH_COMMAND`.
They are applied in filename order against the pinned llama.cpp commit (`LLAMA_CPP_VERSION`):

| Patch | Purpose |
|---|---|
| `001-llama-cpp-hooks.patch` | Compat layer call-site insertions |
| `002-gguf-big-endian-byteswap.patch` | GGUF metadata byteswap |
| `003-tensor-data-big-endian-byteswap.patch` | Tensor weight byteswap (the key fix) |

The patches are idempotent — re-running `cmake -B build .` does not re-apply already-applied patches.

See [docs/6-endianness-fix.md](6-endianness-fix.md) for a full explanation of why these patches are needed.

---

## Verify the build works

Start the server in one terminal:

```sh
./ollama serve
```

When a model loads you should see this line in the server log, confirming the byteswap path is active:

```
compat patch disabled mmap for transformed text tensors
```

In a second terminal:

```sh
./ollama run smollm:135m "Hello, how are you?"
```

Before the fix this returned `.....................`. After the fix it returns coherent text.

---

## Run tests

```sh
go test ./...
```

---

## Next steps

| Goal | Guide |
|---|---|
| Build a container image | [docs/3-container-build.md](3-container-build.md) |
| Deploy on OpenShift AI | [docs/4-openshift-deploy.md](4-openshift-deploy.md) |
| Understand the endianness fix | [docs/6-endianness-fix.md](6-endianness-fix.md) |
