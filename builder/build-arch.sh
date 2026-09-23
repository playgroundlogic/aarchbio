#!/usr/bin/env bash
# build-arch.sh — build ONE platform of a tool natively and push it by DIGEST
# (no tag). Used by the multi-arch matrix: each native runner (amd64 on an amd64
# runner, arm64 on an arm64 runner — NO emulation) builds its half and pushes a
# digest; a separate merge step assembles the manifest list under the real tag.
#
# Pushing by digest (not tag) means the two arch images don't fight over the tag;
# the manifest merge is what publishes the <version>--<build> tag atomically.
#
# Usage:  PLATFORM=linux/amd64 ./build-arch.sh <pkg> <version>
# Requires: docker login to the registry. Always pushes (that's the point).
# Emits to $GITHUB_OUTPUT (and stdout): arch_digest, platform
set -euo pipefail

PKG="${1:?usage: build-arch.sh <pkg> <version>}"
VER="${2:?usage: build-arch.sh <pkg> <version>}"
PLATFORM="${PLATFORM:?set PLATFORM=linux/amd64 or linux/arm64}"
REGISTRY="${REGISTRY:-quay.io/aarchbio}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"   # mulled-image extra "name=version" specs
HERE="$(cd "$(dirname "$0")" && pwd)"

# This path pushes by digest with no probe build, so it cannot read the installed
# record itself — classify.sh already resolved the channel and passes it in.
# Defaults to bioconda, which is correct for all but a handful of tools.
SOURCE_CHANNEL="${SOURCE_CHANNEL:-bioconda}"
if [ "$SOURCE_CHANNEL" = "bioconda" ]; then
  SOURCE_RECIPE="https://github.com/bioconda/bioconda-recipes/tree/master/recipes/${PKG}"
else
  SOURCE_RECIPE="https://github.com/${SOURCE_CHANNEL}/${PKG}-feedstock"
fi
GIT_SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi
emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }

# Build this single platform natively and push by digest only (no -t tag).
# --provenance=false keeps buildx from adding an extra manifest entry that would
# complicate the later imagetools manifest merge. The pushed digest is read from
# buildx's metadata file (robust — not scraped from logs).
echo "[build-arch] building ${PKG}=${VER} for ${PLATFORM} (native, no emulation) ..."
META="$(mktemp)"
docker buildx build \
  --platform "$PLATFORM" \
  --build-arg PKG="$PKG" \
  --build-arg PKG_VERSION="$VER" \
  --build-arg SOURCE_RECIPE="$SOURCE_RECIPE" \
  --build-arg SOURCE_CHANNEL="$SOURCE_CHANNEL" \
  --build-arg BUILDER_GIT_SHA="$GIT_SHA" \
  --build-arg EXTRA_PACKAGES="$EXTRA_PACKAGES" \
  --provenance=false \
  --metadata-file "$META" \
  --output "type=image,name=${REGISTRY}/${PKG},push-by-digest=true,name-canonical=true,push=true" \
  "$HERE"

digest="$("${PY[@]}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("containerimage.digest",""))' "$META" 2>/dev/null)"
rm -f "$META"
if [ -z "${digest:-}" ]; then
  echo "[build-arch] ERROR: could not determine pushed digest from buildx metadata" >&2; exit 2
fi

echo "[build-arch] ${PLATFORM} pushed by digest: ${digest}"

# --- Smoke test THIS leg before it can become part of a published manifest ---
# This path had no verification at all, which is precisely how two broken noarch
# images reached the registry (scanpy 1.7.2, issue #63, and humann 3.9). Every
# noarch tool publishes through here, so an unchecked leg means an unchecked tag.
#
# Testing after the digest push is deliberate and safe: a digest carries no tag, so
# nothing can pull it by name. The `merge` step is what publishes the
# <version>--<build> tag, and failing here means merge never runs — so a bad build
# is never reachable under a tag. The alternative (build --load, test, then rebuild
# to push) would build every leg twice.
#
# Each leg runs on its own NATIVE runner, so this tests the real interpreter for
# the real architecture — no emulation, and an arm64-only defect cannot hide behind
# a passing amd64 leg.
HERE_ARCH="$(cd "$(dirname "$0")" && pwd)"
echo "[build-arch] smoke test (${PLATFORM}) ..."
if ! "$HERE_ARCH/smoke.sh" "${REGISTRY}/${PKG}@${digest}" "$PKG" "$PLATFORM"; then
  echo "[build-arch] ERROR: ${PKG}=${VER} failed verification on ${PLATFORM}." >&2
  echo "[build-arch] The digest stays untagged and unreachable; not emitting it, so" >&2
  echo "[build-arch] the manifest merge cannot publish this build." >&2
  exit 4
fi

emit arch_digest "$digest"
emit platform    "$PLATFORM"
