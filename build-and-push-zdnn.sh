#!/bin/bash
# build-and-push-zdnn.sh
#
# Build the zDNN-accelerated Ollama image and push to quay.io
#
# Prerequisites:
#   - podman 4.0+
#   - Running on s390x (or with QEMU user-space emulation)
#   - libzdnn-dev installed (for zDNN build support)
#   - Logged in to quay.io: podman login quay.io
#
# Usage:
#   ./build-and-push-zdnn.sh [registry/user] [tag]
#   ./build-and-push-zdnn.sh brice_patchou latest-zdnn
#   ./build-and-push-zdnn.sh justinveltri latest-zdnn

set -e

REGISTRY_USER="${1:-brice_patchou}"
TAG="${2:-latest-zdnn}"
IMAGE="quay.io/${REGISTRY_USER}/ollama-s390x:${TAG}"

echo "=========================================="
echo "Building Ollama zDNN image for s390x"
echo "=========================================="
echo "Image: $IMAGE"
echo "Platform: linux/s390x"
echo ""

# Build the image
echo "Step 1: Building image (this may take 30-60 minutes)..."
podman build \
  --platform linux/s390x \
  --format docker \
  -f Containerfile.zdnn \
  -t "$IMAGE" \
  .

echo ""
echo "✓ Build complete!"
echo ""

# Push to registry
echo "Step 2: Pushing to quay.io..."
podman push "$IMAGE"

echo ""
echo "=========================================="
echo "✓ Successfully pushed $IMAGE"
echo "=========================================="
echo ""
echo "Next: Update your Kubernetes deployment to use:"
echo "  image: $IMAGE"
echo ""
echo "Then redeploy:"
echo "  oc set image deployment/ollama-zdnn ollama=$IMAGE -n project-ollama"
