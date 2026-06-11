#!/usr/bin/env bash
# merge.sh — assemble per-arch digests (from build-arch.sh) into ONE multi-arch
# manifest published under the real <version>--<build> tag, then emit the
# manifest-list digest so the caller can cosign-sign it.
#
# Usage:  ./merge.sh <pkg> <tag> <digest1> [<digest2> ...]
#   e.g.  ./merge.sh multiqc 1.21--pyhdfd78af_0 sha256:aaa... sha256:bbb...
# Requires: docker login to the registry.
# Emits: image, pinned (registry/pkg@<manifest-list-digest>)
set -euo pipefail

PKG="${1:?usage: merge.sh <pkg> <tag> <digest...>}"
TAG="${2:?usage: merge.sh <pkg> <tag> <digest...>}"
shift 2
[ "$#" -ge 1 ] || { echo "[merge] ERROR: need at least one arch digest" >&2; exit 2; }

REGISTRY="${REGISTRY:-quay.io/aarchbio}"
IMAGE="${REGISTRY}/${PKG}:${TAG}"
emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }

# Build the source list: each per-arch image referenced by digest.
srcs=()
for d in "$@"; do srcs+=("${REGISTRY}/${PKG}@${d}"); done

echo "[merge] creating manifest ${IMAGE} from: ${srcs[*]}"
docker buildx imagetools create --tag "$IMAGE" "${srcs[@]}"

# Read back the manifest-list digest (this is what cosign should sign — signing
# the list covers all arches; verifiers resolving the tag get this digest).
MANIFEST_DIGEST="$(docker buildx imagetools inspect "$IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null)"
[ -n "$MANIFEST_DIGEST" ] || { echo "[merge] ERROR: could not read manifest digest" >&2; exit 2; }

echo "[merge] published ${IMAGE} (manifest ${MANIFEST_DIGEST})"
# Cosmetic platform listing — must not fail the script (head closes the pipe
# early -> SIGPIPE -> pipefail; guard it so a display line can't mark merge failed).
{ docker buildx imagetools inspect "$IMAGE" 2>/dev/null | grep -E 'Name|Platform' | head -8; } || true
emit image  "$IMAGE"
emit pinned "${REGISTRY}/${PKG}@${MANIFEST_DIGEST}"
