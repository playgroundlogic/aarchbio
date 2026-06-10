#!/usr/bin/env bash
# classify.sh — cheaply determine, for a bioconda package+version, WITHOUT building
# an image: the resolved build hash, the conda subdir (noarch vs linux-aarch64),
# whether it's noarch, and the resulting <version>--<build> tag.
#
# This is the shared front-end for both the CI matrix and the (future) local build
# farm: classify once, then route — noarch -> multi-arch (amd64+arm64 native),
# arch-specific -> arm64-only.
#
# It runs a micromamba SOLVE (--dry-run) inside an arm64 container — no install,
# no image build — so it returns in seconds. The solve is the source of truth for
# the build hash (we never predict it from a host conda search).
#
# Usage:  ./classify.sh <pkg> <version>
# Emits KEY=value lines (and to $GITHUB_OUTPUT if set):
#   tool, version, subdir, build, noarch (0|1), tag, platforms, ok (0|1)
set -uo pipefail

PKG="${1:?usage: classify.sh <pkg> <version>}"
VER="${2:?usage: classify.sh <pkg> <version>}"
MAMBA_IMAGE="${MAMBA_IMAGE:-mambaorg/micromamba:1.5.8}"

# Pick a Python interpreter portably: `uv run python` locally (project standard),
# plain python3 on CI runners that don't have uv. PY is an array so it expands
# correctly whether it's one word or two.
if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi

emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; }

# Solve the arm64 environment (dry-run) and read the package record.
json="$(docker run --rm --platform linux/arm64 "$MAMBA_IMAGE" \
        micromamba create -n _c --dry-run --json -c bioconda -c conda-forge "${PKG}=${VER}" 2>/dev/null)"

# Pass the solve JSON via a temp file, NOT a pipe: the parser finishing early
# (it stops at the matching package) would close a pipe while micromamba's large
# JSON is still being written, and under `pipefail` that broken-pipe poisons the
# command (observed on big solves like metaphlan in CI).
JSON_TMP="$(mktemp)"; printf '%s' "$json" > "$JSON_TMP"
read -r SUBDIR BUILD <<<"$("${PY[@]}" -c '
import json,sys
try:
    d=json.load(open(sys.argv[2]))
except Exception:
    sys.exit()
out=("","")
for a in d.get("actions",{}).get("LINK",[]):
    if a.get("name")==sys.argv[1]:
        out=(a.get("subdir",""), a.get("build_string") or a.get("build",""))
        break
print(out[0], out[1])
' "$PKG" "$JSON_TMP" 2>/dev/null)"
rm -f "$JSON_TMP"

if [ -z "${BUILD:-}" ]; then
  echo "[classify] ERROR: could not resolve ${PKG}=${VER} for linux-aarch64 (no arm64 solution)" >&2
  emit tool "$PKG"; emit version "$VER"; emit ok 0
  exit 2
fi

if [ "$SUBDIR" = "noarch" ]; then NOARCH=1; PLATFORMS="linux/amd64,linux/arm64"; else NOARCH=0; PLATFORMS="linux/arm64"; fi

emit tool      "$PKG"
emit version   "$VER"
emit subdir    "$SUBDIR"
emit build     "$BUILD"
emit noarch    "$NOARCH"
emit tag       "${VER}--${BUILD}"
emit platforms "$PLATFORMS"
emit ok        1
echo "[classify] ${PKG}=${VER}: subdir=${SUBDIR} build=${BUILD} -> $([ "$NOARCH" = 1 ] && echo 'NOARCH/multi-arch' || echo 'arch-specific/arm64-only')"
