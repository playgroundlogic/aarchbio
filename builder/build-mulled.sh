#!/usr/bin/env bash
# build-mulled.sh — build a native arm64 rebuild of a legacy hashed BioContainers
# "mulled-v2" image, published under the EXACT upstream name:tag.
#
# Usage:
#   ./build-mulled.sh <pkg=ver> <pkg=ver> [...]
#   ./build-mulled.sh cnvkit=0.9.10 samtools=1.19.2
#   PUSH=1 ./build-mulled.sh prodigal=2.6.3 pigz=2.6
#
# WHY A SEPARATE SCRIPT (not a flag on build.sh)
# ----------------------------------------------
# build.sh derives BOTH coordinates from one package: repo = the package name,
# tag = <version>--<conda build hash> read back from the installed image. A mulled
# image has neither. Its repo name and tag are sha1s over the whole ingredient set
# (builder/mulled.py), so they must be *computed up front* from the requested
# specs, and there is no single package whose conda build hash could name the tag.
# Bolting that onto build.sh would mean two mutually exclusive naming paths in one
# script; the shared part (the Dockerfile) is already shared.
#
# Matching the upstream tag exactly is the whole point: an nf-core process pins
# `mulled-v2-<hash>:<tag>` literally, so anything else is not a drop-in.
#
# arm64-only by design (D9): the amd64 mulled image already exists upstream at
# quay.io/biocontainers, so we fill only the arm64 half. No emulation anywhere.
set -euo pipefail

[ "$#" -ge 2 ] || { echo "usage: build-mulled.sh <pkg=ver> <pkg=ver> [...]  (>=2 packages)" >&2; exit 64; }

REGISTRY="${REGISTRY:-quay.io/aarchbio}"
HERE="$(cd "$(dirname "$0")" && pwd)"
if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi
emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }

SPECS=("$@")

# --- 1. Compute the upstream coordinates -----------------------------------
NAME="$("${PY[@]}" "$HERE/mulled.py" name "${SPECS[@]}")"
TAG="$("${PY[@]}" "$HERE/mulled.py" tag  "${SPECS[@]}")"
[ -n "$NAME" ] && [ -n "$TAG" ] || { echo "[mulled] ERROR: could not compute mulled coordinates" >&2; exit 2; }
IMAGE="${REGISTRY}/${NAME}:${TAG}"
SPEC_CSV="$(IFS=,; echo "${SPECS[*]}")"
echo "[mulled] ${SPEC_CSV}"
echo "[mulled]   -> ${IMAGE}"

# --- 2. Sanity-check against upstream --------------------------------------
# If quay.io/biocontainers has no such name:tag, our spec list is not the one that
# produced a real upstream image — almost certainly a typo'd version. Warn loudly
# rather than publish a hash nobody will ever pull. (Not fatal: a caller may
# legitimately be first to a combination.)
if curl -fsSL "https://quay.io/api/v1/repository/biocontainers/${NAME}/tag/?onlyActiveTags=true&limit=100" \
     2>/dev/null | grep -q "\"${TAG}\""; then
  echo "[mulled] OK: upstream biocontainers/${NAME}:${TAG} exists -> this is a true drop-in"
else
  echo "[mulled] WARNING: no upstream biocontainers/${NAME}:${TAG}; check the versions" >&2
fi

# --- 3. Build natively for arm64 -------------------------------------------
# The Dockerfile installs "${PKG}=${PKG_VERSION}" plus EXTRA_PACKAGES, so split the
# spec list: first (name-sorted, matching the hash order) is primary, rest are
# extras. Which one is "primary" is arbitrary for a mulled image — all ingredients
# are installed into the same env — but sorting keeps it deterministic.
read -r PRIMARY EXTRAS <<<"$("${PY[@]}" - "${SPECS[@]}" <<'PY'
import sys
pairs = sorted((s.split("=", 1) for s in sys.argv[1:]), key=lambda p: p[0])
print(f"{pairs[0][0]}={pairs[0][1]}", " ".join(f"{n}={v}" for n, v in pairs[1:]))
PY
)"
PKG="${PRIMARY%%=*}"; PKG_VERSION="${PRIMARY#*=}"

GIT_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# Provenance points at the mulled definition, since no single bioconda recipe
# describes a fused image.
SOURCE_RECIPE="https://github.com/BioContainers/multi-package-containers"
SUBJECT="BioContainers mulled image ${NAME}:${TAG} (${SPEC_CSV})"

BUILD_ARGS=(
  --build-arg PKG="$PKG"
  --build-arg PKG_VERSION="$PKG_VERSION"
  --build-arg EXTRA_PACKAGES="$EXTRAS"
  --build-arg IMAGE_TITLE="$NAME"
  --build-arg MULLED_SPECS="$SPEC_CSV"
  --build-arg IMAGE_SUBJECT="$SUBJECT"
  --build-arg IMAGE_VERSION="$TAG"
  --build-arg SOURCE_RECIPE="$SOURCE_RECIPE"
  --build-arg SOURCE_CHANNEL="bioconda"
  --build-arg BUILDER_GIT_SHA="$GIT_SHA"
)

echo "[mulled] building linux/arm64 (native, no emulation): ${PKG}=${PKG_VERSION} + [${EXTRAS}]"
docker buildx build --platform linux/arm64 "${BUILD_ARGS[@]}" -t "$IMAGE" --load "$HERE"

# --- 4. Smoke test EVERY ingredient ----------------------------------------
# Stricter than build.sh's single-tool check, and it FAILS the build rather than
# warning: a fused image whose ingredients don't all resolve on PATH is silently
# useless to the pipeline that pinned it, and the hashed tag gives a user no clue
# which half is missing. Cheap insurance for a rare build.
echo "[mulled] verifying all ingredients are present on arm64 ..."
missing=""
for spec in "${SPECS[@]}"; do
  p="${spec%%=*}"
  # Not every package installs a binary named exactly after it (libraries, or
  # differently-cased entry points like ALE), so accept either an executable on
  # PATH or an installed conda record for the package.
  if ! docker run --rm --platform linux/arm64 "$IMAGE" sh -c \
        "command -v '$p' >/dev/null 2>&1 || ls /opt/conda/conda-meta/${p}-*.json >/dev/null 2>&1"; then
    missing="$missing $p"
  fi
done
if [ -n "$missing" ]; then
  echo "[mulled] ERROR: ingredients missing from the built image:$missing" >&2
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
  exit 2
fi
echo "[mulled] all ${#SPECS[@]} ingredients present"

# Prove it is really AArch64 and no foreign binary sneaked in: ELF e_machine
# (byte 18) must be 183 = AArch64 for EVERY ELF in bin/, not just one. Checking
# all of them is what catches the real hazard — a recipe that ships a prebuilt
# x86_64 blob (e_machine 62) alongside genuinely rebuilt tools, which one sampled
# binary would miss.
#
# Files must be filtered by ELF MAGIC (7f 45 4c 46), not by being executable:
# /opt/conda/bin is full of executable shell/python scripts, and byte 18 of a
# script is just text (a `y` read as 121), which failed the check spuriously.
elf="$(docker run --rm --platform linux/arm64 "$IMAGE" sh -c '
  for f in /opt/conda/bin/*; do
    [ -f "$f" ] || continue
    [ "$(od -An -tx1 -N4 "$f" | tr -d " \n")" = "7f454c46" ] || continue
    od -An -tu1 -j18 -N1 "$f" | tr -d " "
  done | sort -u | tr "\n" ","' 2>/dev/null)"
if [ "$elf" != "183," ]; then
  echo "[mulled] ERROR: ELF e_machine set = ${elf:-none}, expected exactly '183,' (AArch64)" >&2
  exit 2
fi
echo "[mulled] every ELF in /opt/conda/bin is AArch64 (e_machine=183)"

# --- 5. Publish ------------------------------------------------------------
DIGEST=""
if [ "${PUSH:-0}" = "1" ]; then
  echo "[mulled] pushing ${IMAGE} ..."
  docker buildx build --platform linux/arm64 "${BUILD_ARGS[@]}" -t "$IMAGE" --push "$HERE"
  DIGEST="$(docker buildx imagetools inspect "$IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null)"
  echo "[mulled] pushed. digest=${DIGEST:-unknown}"
else
  echo "[mulled] not pushing (set PUSH=1)."
fi

PINNED=""
[ -n "$DIGEST" ] && PINNED="${REGISTRY}/${NAME}@${DIGEST}"
emit tool      "$NAME"
emit tag       "$TAG"
emit image     "$IMAGE"
emit specs     "$SPEC_CSV"
emit digest    "$DIGEST"
emit pinned    "$PINNED"
emit pushed    "${PUSH:-0}"
emit platforms "linux/arm64"
echo "[mulled] done: ${IMAGE}"
