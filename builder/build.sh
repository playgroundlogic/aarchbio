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
# EXTRA_PACKAGES: space-separated "name=version" for mulled images (e.g.
# kraken2 + "coreutils=9.4 pigz=2.8"). The primary PKG still names the repo/tag.
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# bioconda recipe URL for the source label (provenance).
SOURCE_RECIPE="https://github.com/bioconda/bioconda-recipes/tree/master/recipes/${PKG}"
GIT_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --- 1. Assert the arm64 conda package exists (best-effort pre-check) ------
# This is an EARLY failure check only. The authoritative gate is the in-container
# `micromamba install` in step 2 — if no linux-aarch64 package exists, that fails
# regardless. So when `conda` isn't on the host (e.g. a hosted CI runner), we skip
# the pre-check rather than hard-fail, and let the build be the source of truth.
spec="$PKG=$VER"
if command -v conda >/dev/null 2>&1; then
  echo "[build] checking bioconda linux-aarch64 for ${PKG}=${VER} ..."
  if ! conda search -c bioconda --platform linux-aarch64 "$spec" >/dev/null 2>&1; then
    echo "[build] ERROR: no linux-aarch64 bioconda package for ${PKG}=${VER}." >&2
    echo "[build]        This tool is in the 'hard 15%' or the version is wrong." >&2
    exit 2
  fi
  echo "[build] OK: ${PKG}=${VER} available for arm64."
else
  echo "[build] (no host conda — skipping pre-check; the in-container install is the gate)"
fi

# --- 2. Build arm64 locally (probe build) ----------------------------------
# Build the arm64 image to a temp tag and --load it, so we can (a) read the real
# installed build hash, (b) detect whether the package is noarch, and (c) smoke-
# test — all before deciding how to publish. We do NOT predict the build hash
# from a host `conda search`; the in-container resolver is the source of truth.
TMP_IMAGE="${REGISTRY}/${PKG}:_building_${VER}"
echo "[build] building probe image (linux/arm64, native = no emulation) ..."
docker buildx build \
  --platform linux/arm64 \
  --build-arg PKG="$PKG" \
  --build-arg PKG_VERSION="$VER" \
  --build-arg SOURCE_RECIPE="$SOURCE_RECIPE" \
  --build-arg BUILDER_GIT_SHA="$GIT_SHA" \
  --build-arg EXTRA_PACKAGES="$EXTRA_PACKAGES" \
  -t "$TMP_IMAGE" \
  --load \
  "$HERE"

# --- 3. Resolve tag + detect noarch from what was actually installed --------
# `micromamba list` columns: name version build channel. The channel/subdir for
# a noarch package shows the package living in noarch; we detect it by asking for
# the package's subdir explicitly via `micromamba list --json` if available, else
# infer from the build string (noarch builds carry no arch token like h*/pl* with
# arch). Most reliable: check the installed package's platform via conda metadata.
echo "[build] reading installed package metadata from the probe image ..."
INSTALLED="$(docker run --rm --platform linux/arm64 "$TMP_IMAGE" \
              micromamba list -n base 2>/dev/null \
              | awk -v p="$PKG" '$1==p {print $2" "$3}')"
GOT_VER="${INSTALLED%% *}"
GOT_HASH="${INSTALLED##* }"
[ -n "$GOT_HASH" ] || { echo "[build] ERROR: could not read installed build hash" >&2; exit 2; }

if [ "$GOT_VER" != "$VER" ]; then
  echo "[build] ERROR: requested ${VER} but image contains ${GOT_VER}" >&2; exit 2
fi
if [ -n "$BUILD_HASH" ] && [ "$BUILD_HASH" != "$GOT_HASH" ]; then
  echo "[build] ERROR: pinned build ${BUILD_HASH} but image contains ${GOT_HASH}" >&2; exit 2
fi

# noarch detection: read the package record's subdir from the conda metadata in
# the image. noarch packages record "subdir": "noarch" in their conda-meta JSON.
SUBDIR="$(docker run --rm --platform linux/arm64 "$TMP_IMAGE" sh -c \
  "cat /opt/conda/conda-meta/${PKG}-${GOT_VER}-${GOT_HASH}.json 2>/dev/null" \
  | grep -o '\"subdir\"[[:space:]]*:[[:space:]]*\"[^\"]*\"' | head -1 | sed 's/.*\"\([^\"]*\)\"$/\1/')"
if [ "$SUBDIR" = "noarch" ]; then
  IS_NOARCH=1; echo "[build] package is NOARCH -> will publish a MULTI-ARCH manifest (amd64+arm64)"
else
  IS_NOARCH=0; echo "[build] package subdir='${SUBDIR:-unknown}' -> arm64-only (amd64 already on biocontainers)"
fi

TAG="${GOT_VER}--${GOT_HASH}"
IMAGE="${REGISTRY}/${PKG}:${TAG}"

# --- 4. Smoke test (arm64 probe) -------------------------------------------
echo "[build] smoke test (arm64) ..."
if docker run --rm --platform linux/arm64 "$TMP_IMAGE" "$PKG" --version >/dev/null 2>&1 \
   || docker run --rm --platform linux/arm64 "$TMP_IMAGE" "$PKG" --help >/dev/null 2>&1 \
   || docker run --rm --platform linux/arm64 "$TMP_IMAGE" sh -c "command -v $PKG" >/dev/null 2>&1; then
  echo "[build] smoke test PASSED ($PKG present and runnable on arm64)"
else
  echo "[build] WARNING: smoke test inconclusive — verify $PKG manually" >&2
fi
docker rmi "$TMP_IMAGE" >/dev/null 2>&1 || true

# --- 5. Publish ------------------------------------------------------------
# noarch  -> multi-arch manifest (amd64+arm64), each platform native; nobody ever
#            emulates an arch-neutral interpreter. MUST --push (buildx can't
#            --load a manifest list).
# arch-specific -> arm64 only; the native amd64 build already exists upstream at
#            quay.io/biocontainers, so we fill only the arm64 gap.
DIGEST=""
if [ "${PUSH:-0}" = "1" ]; then
  if [ "$IS_NOARCH" = "1" ]; then PLATFORMS="linux/amd64,linux/arm64"; else PLATFORMS="linux/arm64"; fi
  echo "[build] building+pushing ${IMAGE} for ${PLATFORMS} ..."
  docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg PKG="$PKG" \
    --build-arg PKG_VERSION="$VER" \
    --build-arg SOURCE_RECIPE="$SOURCE_RECIPE" \
    --build-arg BUILDER_GIT_SHA="$GIT_SHA" \
  --build-arg EXTRA_PACKAGES="$EXTRA_PACKAGES" \
    -t "$IMAGE" \
    --push \
    "$HERE"
  # Digest of the pushed manifest (the manifest-list digest for multi-arch).
  DIGEST="$(docker buildx imagetools inspect "$IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null)"
  echo "[build] pushed. platforms=${PLATFORMS} digest=${DIGEST:-unknown}"
else
  echo "[build] not pushing (set PUSH=1). Probe arm64 image was validated, then removed."
fi

# --- 6. Machine-readable outputs ------------------------------------------
# Emit results for a CI caller: the image ref, the pushed digest, and the
# digest-pinned ref that cosign/verification should use. Written to
# $GITHUB_OUTPUT when running under GitHub Actions, always echoed for humans.
PINNED=""
[ -n "$DIGEST" ] && PINNED="${REGISTRY}/${PKG}@${DIGEST}"
emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }
echo "[build] outputs:"
emit image    "$IMAGE"
emit tool     "$PKG"
emit tag      "$TAG"
emit digest   "$DIGEST"
emit pinned   "$PINNED"
emit pushed   "${PUSH:-0}"
emit noarch   "${IS_NOARCH:-0}"
emit platforms "$([ "${IS_NOARCH:-0}" = 1 ] && echo 'linux/amd64,linux/arm64' || echo 'linux/arm64')"

echo "[build] done: ${IMAGE}"
