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

emit() { echo "$1=$2"; [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; return 0; }

# Solve the arm64 environment (dry-run) and read the package record.
#
# stderr is CAPTURED, not discarded, and the exit status is inspected, because
# "the solver says there is no arm64 build" and "the solver never ran" are
# different facts that used to look identical. Discarding both turned any infra
# failure into `ok=0`, and publish.yml routes `ok=0` straight to the D10 gap filer
# -- so a full disk or a failed image pull would file a public arm64-gap issue
# blaming an innocent recipe. (Hit for real: a local Docker VM with no space left
# reported piscem=0.23.0 as having no arm64 solution, when it solves fine.)
#
# Fail-safe direction: only a RECOGNISED solver verdict is allowed to mean "gap".
# Anything else is an infra error, which exits 3 and must not be read as a gap.
ERR_TMP="$(mktemp)"
json="$(docker run --rm --platform linux/arm64 "$MAMBA_IMAGE" \
        micromamba create -n _c --dry-run --json -c bioconda -c conda-forge "${PKG}=${VER}" 2>"$ERR_TMP")"
RC=$?
err="$(cat "$ERR_TMP")"; rm -f "$ERR_TMP"

if [ "$RC" -ne 0 ]; then
  case "$err$json" in
    *"Could not solve for environment specs"*|*"nothing provides"*|\
    *"is not installable"*|*"PackagesNotFoundError"*|*"packages are not available"*|\
    *"no candidates were found"*)
      : ;;   # a real solver verdict -> fall through to the ok=0 gap path
    *)
      echo "[classify] INFRA ERROR: the solver did not run for ${PKG}=${VER}" >&2
      echo "[classify] docker exit=$RC; stderr follows (NOT an arm64 gap):" >&2
      printf '%s\n' "$err" | tail -5 >&2
      emit tool "$PKG"; emit version "$VER"; emit ok error
      exit 3
      ;;
  esac
fi

# Pass the solve JSON via a temp file, NOT a pipe: the parser finishing early
# (it stops at the matching package) would close a pipe while micromamba's large
# JSON is still being written, and under `pipefail` that broken-pipe poisons the
# command (observed on big solves like metaphlan in CI).
JSON_TMP="$(mktemp)"; printf '%s' "$json" > "$JSON_TMP"
read -r SUBDIR BUILD CHANNEL <<<"$("${PY[@]}" -c '
import json,sys
try:
    d=json.load(open(sys.argv[2]))
except Exception:
    sys.exit()
out=("","","bioconda")
for a in d.get("actions",{}).get("LINK",[]):
    if a.get("name")==sys.argv[1]:
        # "channel" is a URL or name; keep just the channel name (last non-subdir
        # path element) so a conda-forge-packaged tool is labelled truthfully.
        ch=(a.get("channel") or "bioconda").rstrip("/")
        parts=[p for p in ch.split("/") if p]
        if parts and (parts[-1]=="noarch" or parts[-1].split("-")[0] in ("linux","osx","win")):
            parts=parts[:-1]
        out=(a.get("subdir",""), a.get("build_string") or a.get("build",""),
             parts[-1] if parts else "bioconda")
        break
print(out[0], out[1], out[2])
' "$PKG" "$JSON_TMP" 2>/dev/null)"
rm -f "$JSON_TMP"

if [ -z "${BUILD:-}" ]; then
  # Reachable two ways: the solver rendered an unsatisfiable verdict (RC!=0, and
  # the case above let it through), or it succeeded but the package was absent
  # from the LINK actions. The latter is not a solver verdict about arm64, so it
  # is reported as an error rather than a gap -- same fail-safe rule as above.
  if [ "$RC" -eq 0 ]; then
    echo "[classify] INFRA ERROR: solve for ${PKG}=${VER} succeeded but '${PKG}' was not in its LINK actions" >&2
    echo "[classify] (a parse problem or an unexpected package name -- NOT an arm64 gap)" >&2
    emit tool "$PKG"; emit version "$VER"; emit ok error
    exit 3
  fi
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
emit channel   "${CHANNEL:-bioconda}"
emit ok        1
echo "[classify] ${PKG}=${VER}: subdir=${SUBDIR} build=${BUILD} channel=${CHANNEL:-bioconda} -> $([ "$NOARCH" = 1 ] && echo 'NOARCH/multi-arch' || echo 'arch-specific/arm64-only')"
