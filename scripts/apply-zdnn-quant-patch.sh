#!/bin/bash
# scripts/apply-zdnn-quant-patch.sh
#
# Applies the zDNN quantized dispatch changes directly to the fetched
# llama.cpp source in build-zdnn/_deps/llama_cpp-src/.
#
# Run this AFTER cmake -B build-zdnn . -DOLLAMA_S390X_ZDNN=ON
# and BEFORE cmake --build build-zdnn.
#
# Once this is verified working, regenerate the proper git patch with:
#   cd build-zdnn/_deps/llama_cpp-src
#   git diff > ../../../llama/compat/004-zdnn-quantized-dispatch.patch
#
# Usage:
#   bash scripts/apply-zdnn-quant-patch.sh [build-dir]
#   Default build-dir: build-zdnn

set -euo pipefail

BUILD_DIR="${1:-build-zdnn}"
ZDNN_SRC="${BUILD_DIR}/_deps/llama_cpp-src/ggml/src/ggml-zdnn"

if [[ ! -d "$ZDNN_SRC" ]]; then
    echo "ERROR: $ZDNN_SRC not found. Run cmake configure first."
    exit 1
fi

echo "=== Patching $ZDNN_SRC ==="

# -----------------------------------------------------------------------
# 1. utils.hpp — declare ggml_zdnn_dequant_and_load
# -----------------------------------------------------------------------
if grep -q "ggml_zdnn_dequant_and_load" "$ZDNN_SRC/utils.hpp"; then
    echo "utils.hpp: already patched, skipping"
else
    # Insert the declaration before ggml_zdnn_load_tensor
    sed -i 's/void ggml_zdnn_load_tensor/\/\/ Dequantize a quantized weight tensor to F16 and stickify it.\n\/\/ Used by ggml_zdnn_init_tensor for quantized weight tensors.\nvoid ggml_zdnn_dequant_and_load(ggml_backend_zdnn_buffer * buffer,\n                                const ggml_tensor        * tensor);\n\nvoid ggml_zdnn_load_tensor/' \
        "$ZDNN_SRC/utils.hpp"
    echo "utils.hpp: patched"
fi

# -----------------------------------------------------------------------
# 2. utils.cpp — add ggml_zdnn_dequant_and_load implementation
# -----------------------------------------------------------------------
if grep -q "ggml_zdnn_dequant_and_load" "$ZDNN_SRC/utils.cpp"; then
    echo "utils.cpp: already patched, skipping"
else
    # Add includes and the new function after the existing includes
    sed -i 's/#include "utils.hpp"/#include "ggml-impl.h"\n#include "utils.hpp"\n#include <vector>/' \
        "$ZDNN_SRC/utils.cpp"

    # Insert the new function before ggml_zdnn_create_tensor
    python3 - "$ZDNN_SRC/utils.cpp" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

new_fn = '''
// Dequantize quantized weight tensor to F16, then stickify into ztensor.
// Called once at model load time for each quantized weight tensor.
// Per-inference cost is zero — the stickified F16 is reused every forward pass.
void ggml_zdnn_dequant_and_load(ggml_backend_zdnn_buffer * buffer,
                                const ggml_tensor        * tensor) {
    const int64_t n_elements = ggml_nelements(tensor);

    // Step 1: dequantize to F32 using ggml\'s own type traits
    std::vector<float> f32_buf(n_elements);
    const ggml_type_traits * tt = ggml_get_type_traits(tensor->type);
    GGML_ASSERT(tt->to_float != nullptr && "quantized type must have to_float trait");
    tt->to_float(tensor->data, f32_buf.data(), n_elements);

    // Step 2: convert F32 → F16
    std::vector<ggml_fp16_t> f16_buf(n_elements);
    for (int64_t i = 0; i < n_elements; i++) {
        f16_buf[i] = ggml_fp32_to_fp16(f32_buf[i]);
    }

    // Step 3: init the ztensor descriptor as FP16 and stickify
    zdnn_init_pre_transformed_desc(
        ZDNN_2D, FP16, &buffer->pre_tfm_desc,
        tensor->ne[1], tensor->ne[0]);
    ZDNN_CHECK(zdnn_generate_transformed_desc(&buffer->pre_tfm_desc, &buffer->tfm_desc));
    ZDNN_CHECK(zdnn_init_ztensor_with_malloc(&buffer->pre_tfm_desc, &buffer->tfm_desc, &buffer->ztensor));
    ZDNN_CHECK(zdnn_transform_ztensor(&buffer->ztensor, f16_buf.data()));
}

'''
marker = 'void ggml_zdnn_create_tensor('
content = content.replace(marker, new_fn + marker, 1)
with open(path, 'w') as f:
    f.write(content)
print("utils.cpp: inserted ggml_zdnn_dequant_and_load")
PYEOF
fi

# -----------------------------------------------------------------------
# 3. ggml-zdnn.cpp — expand supports_op + call dequant in init_tensor
# -----------------------------------------------------------------------
if grep -q "ggml_zdnn_dequant_and_load" "$ZDNN_SRC/ggml-zdnn.cpp"; then
    echo "ggml-zdnn.cpp: already patched, skipping"
else
    python3 - "$ZDNN_SRC/ggml-zdnn.cpp" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# --- patch 1: expand supports_op to accept quantized types ---
old = '''                switch (weights->type) {
                    case GGML_TYPE_F32:
                    case GGML_TYPE_F16:
                    case GGML_TYPE_BF16:
                        return true;
                    default:
                        return false;
                }'''

new = '''                // Accept F32/F16/BF16 natively.
                // Accept any quantized type that ggml can dequantize to F32.
                // These are dequantized to F16 at init_tensor time.
                switch (weights->type) {
                    case GGML_TYPE_F32:
                    case GGML_TYPE_F16:
                    case GGML_TYPE_BF16:
                        return true;
                    default:
                        {
                            const ggml_type_traits * tt =
                                ggml_get_type_traits(weights->type);
                            return tt != nullptr && tt->to_float != nullptr;
                        }
                }'''

if old not in content:
    print("ERROR: supports_op pattern not found — patch may already be applied or source changed")
    sys.exit(1)
content = content.replace(old, new, 1)

# --- patch 2: call dequant_and_load in init_tensor for quantized weights ---
# Find the MUL_MAT branch in buffer_init_tensor and add a dequant call
old2 = '''    ggml_zdnn_init_tensor(zdnn_buffer.get(), tensor);
    tensor->extra = zdnn_buffer.get();'''

new2 = '''    // For quantized weight tensors: dequantize to F16 and stickify now.
    // The ztensor will contain FP16 data for all subsequent forward passes.
    const ggml_type_traits * _tt = ggml_get_type_traits(tensor->type);
    bool _is_quantized = (_tt != nullptr && _tt->to_float != nullptr &&
                          tensor->type != GGML_TYPE_F32 &&
                          tensor->type != GGML_TYPE_F16 &&
                          tensor->type != GGML_TYPE_BF16);
    if (_is_quantized && tensor->op == GGML_OP_MUL_MAT) {
        ggml_zdnn_dequant_and_load(zdnn_buffer.get(), tensor);
    } else {
        ggml_zdnn_init_tensor(zdnn_buffer.get(), tensor);
    }
    tensor->extra = zdnn_buffer.get();'''

if old2 not in content:
    print("ERROR: init_tensor pattern not found — patch may already be applied or source changed")
    sys.exit(1)
content = content.replace(old2, new2, 1)

with open(path, 'w') as f:
    f.write(content)
print("ggml-zdnn.cpp: expanded supports_op and patched init_tensor")
PYEOF
fi

echo ""
echo "=== Patch complete. Now rebuild: ==="
echo "  cmake --build ${BUILD_DIR} --parallel 8"
echo ""
echo "=== After verifying it works, generate the proper patch: ==="
echo "  cd ${BUILD_DIR}/_deps/llama_cpp-src"
echo "  git diff ggml/src/ggml-zdnn/ > ../../../llama/compat/004-zdnn-quantized-dispatch.patch"
