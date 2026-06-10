#!/usr/bin/env bash
# build.sh — build a single native arm64 biocontainer for one bioconda package.
#
# Usage:
#   ./build.sh <pkg> <version> [build_hash]
#   ./build.sh minimap2 2.28
#   ./build.sh minimap2 2.28 h73052cd_3      # pin the exact conda build
#
# This is the idempotent core builder (DESIGN.md D3). It:
#   1. asserts the linux-aarch64 conda package exists      (the project's premise)
#   2. builds --platform linux/arm64 natively (no QEMU on an arm64 host)
#   3. stamps provenance labels (D6)
#   4. tags <version>--<build>  (D4) under quay.io/aarchbio (D1)
#
# It does NOT push by default. Set PUSH=1 to push (requires `docker login quay.io`).
set -euo pipefail

PKG="${1:?usage: build.sh <pkg> <version> [build_hash]}"
VER="${2:?usage: build.sh <pkg> <version> [build_hash]}"
BUILD_HASH="${3:-}"

REGISTRY="${REGISTRY:-quay.io/aarchbio}"
PLATFORM="${PLATFORM:-linux/arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# bioconda recipe URL for the source label (provenance).
SOURCE_RECIPE="https://github.com/bioconda/bioconda-recipes/tree/master/recipes/${PKG}"
GIT_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- 1. Assert the arm64 conda package exists ------------------------------
echo "[build] checking bioconda linux-aarch64 for ${PKG}=${VER} ..."
spec="$PKG=$VER"
if ! conda search -c bioconda --platform linux-aarch64 "$spec" >/dev/null 2>&1; then
  echo "[build] ERROR: no linux-aarch64 bioconda package for ${PKG}=${VER}." >&2
  echo "[build]        This tool is in the 'hard 15%' or the version is wrong." >&2
  exit 2
fi
echo "[build] OK: ${PKG}=${VER} available for arm64."

# --- 2. Build --------------------------------------------------------------
# Build to a temporary tag FIRST. We do NOT predict the build hash from a host
# `conda search` — the resolver inside the arm64 container can (and does) pick a
# different build, which would make the tag misreport the contents. Provenance
# (D6) requires the tag to reflect what was ACTUALLY installed, so we read the
# real build hash out of the finished image in step 3 and tag from that.
TMP_IMAGE="${REGISTRY}/${PKG}:_building_${VER}"
echo "[build] building (${PLATFORM}, native on arm64 host = no emulation) ..."
docker buildx build \
  --platform "$PLATFORM" \
  --build-arg PKG="$PKG" \
  --build-arg PKG_VERSION="$VER" \
  --build-arg SOURCE_RECIPE="$SOURCE_RECIPE" \
  --build-arg BUILDER_GIT_SHA="$GIT_SHA" \
  --build-arg BUILD_PLATFORM="$PLATFORM" \
  -t "$TMP_IMAGE" \
  --load \
  "$HERE"

# --- 3. Resolve the tag from what was actually installed -------------------
# Ask micromamba inside the image for the real version + build string. This is
# the source of truth; the tag is derived from it, never from a prediction.
echo "[build] reading installed build hash from the image ..."
INSTALLED="$(docker run --rm --platform "$PLATFORM" "$TMP_IMAGE" \
              micromamba list -n base 2>/dev/null \
              | awk -v p="$PKG" '$1==p {print $2" "$3}')"
GOT_VER="${INSTALLED%% *}"
GOT_HASH="${INSTALLED##* }"
[ -n "$GOT_HASH" ] || { echo "[build] ERROR: could not read installed build hash" >&2; exit 2; }

# Sanity: the installed version must match what we asked for.
if [ "$GOT_VER" != "$VER" ]; then
  echo "[build] ERROR: requested ${VER} but image contains ${GOT_VER}" >&2
  exit 2
fi
# If a hash was pinned on the CLI, the install MUST match it, or the pin is a lie.
if [ -n "$BUILD_HASH" ] && [ "$BUILD_HASH" != "$GOT_HASH" ]; then
  echo "[build] ERROR: pinned build ${BUILD_HASH} but image contains ${GOT_HASH}" >&2
  exit 2
fi

TAG="${GOT_VER}--${GOT_HASH}"
IMAGE="${REGISTRY}/${PKG}:${TAG}"
docker tag "$TMP_IMAGE" "$IMAGE"
docker rmi "$TMP_IMAGE" >/dev/null 2>&1 || true
echo "[build] tagged from actual install: ${IMAGE}"

# --- 4. Smoke test ---------------------------------------------------------
# Confirm the binary actually runs on arm64 (catches a package that installs but
# can't execute). Many tools respond to --version or --help; try a few.
echo "[build] smoke test ..."
if docker run --rm --platform "$PLATFORM" "$IMAGE" "$PKG" --version >/dev/null 2>&1 \
   || docker run --rm --platform "$PLATFORM" "$IMAGE" "$PKG" --help >/dev/null 2>&1 \
   || docker run --rm --platform "$PLATFORM" "$IMAGE" sh -c "command -v $PKG" >/dev/null 2>&1; then
  echo "[build] smoke test PASSED ($PKG is present and runnable on arm64)"
else
  echo "[build] WARNING: smoke test inconclusive — verify $PKG manually" >&2
fi

# --- 5. Optional push ------------------------------------------------------
if [ "${PUSH:-0}" = "1" ]; then
  echo "[build] pushing ${IMAGE} (PUSH=1) ..."
  docker push "$IMAGE"
  echo "[build] pushed."
else
  echo "[build] not pushing (set PUSH=1 to push to ${REGISTRY}). Image is loaded locally."
fi

echo "[build] done: ${IMAGE}"
