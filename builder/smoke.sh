#!/usr/bin/env bash
# smoke.sh — prove an image's own package actually works, and FAIL if it doesn't.
#
# Single-sourced because there are two publish paths and only one of them used to
# have any check at all:
#   build.sh       arch-specific -> arm64-only tag   (had an advisory check)
#   build-arch.sh  noarch -> one leg of a multi-arch manifest (had NO check)
# Both scanpy 1.7.2 (#63) and humann 3.9 are noarch, so they went through the
# unchecked path. Duplicating the logic would let them drift apart again.
#
# Three levels, in increasing strength, because each level caught a real defect the
# level above it missed:
#
#   1. CLI probe      — `$PKG --version|--help`, or the binary existing. Vacuous
#      for a library, which is how scanpy 1.7.2 shipped unusable.
#   2. Import         — every python module the package installs must import.
#      Caught humann 3.9, published as subdir=noarch but with a py312 build string
#      and only `python >=3`, its files baked at lib/python3.12/site-packages, so
#      against python 3.13 they sat where python never looks.
#   3. Functional     — optional builder/functional/<pkg>.py, run inside the image.
#      Caught scanpy round two: it imported, loaded data, normalised, ran PCA and
#      built a neighbour graph, and only failed at sc.tl.leiden because the
#      clustering backends were absent. Import is a weak proxy for "works".
#
# Module names come from the package's own conda-meta file list, never guessed from
# the package name: pycoqc ships pycoQC, scikit-learn ships sklearn.
#
# Usage:  ./smoke.sh <image-ref> <pkg> [platform]
# Exit:   0 = proven working, 3 = could not prove it (caller must not publish)
set -uo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref> <pkg> [platform]}"
PKG="${2:?usage: smoke.sh <image-ref> <pkg> [platform]}"
PLATFORM="${3:-linux/arm64}"
HERE_SMOKE="$(cd "$(dirname "$0")" && pwd)"
FUNC="${HERE_SMOKE}/functional/${PKG}.py"

run() { docker run --rm --platform "$PLATFORM" "$IMAGE" "$@"; }

# Pull FIRST, as its own step. Without this the very first `docker run` both pulls
# and probes, and on a cold image the probe came back empty — so the gate silently
# fell through to the weakest check. Every image in CI is cold, which is precisely
# where that must not happen.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[smoke] pulling ${IMAGE} (${PLATFORM}) ..."
  if ! docker pull -q --platform "$PLATFORM" "$IMAGE" >/dev/null 2>&1; then
    echo "[smoke] FAIL — could not pull ${IMAGE}; cannot verify it." >&2
    exit 3
  fi
fi

HAS_PY=0
if run sh -c 'command -v python >/dev/null 2>&1' >/dev/null 2>&1; then HAS_PY=1; fi

MODS=""
if [ "$HAS_PY" = "1" ]; then
  # stderr is kept (not sent to /dev/null) so a broken probe is visible rather
  # than masquerading as "this package installs no modules".
  DETECT_ERR="$(mktemp)"
  MODS="$(run sh -c '
    python - '"$PKG"' <<'"'"'PY'"'"'
import glob, json, re, sys
pkg = sys.argv[1].lower()
mods = set()
for rec in glob.glob(f"/opt/conda/conda-meta/{pkg}-*.json"):
    try:
        files = json.load(open(rec)).get("files", [])
    except Exception:
        continue
    for f in files:
        m = re.match(r"lib/python[0-9.]+/site-packages/([A-Za-z_][A-Za-z0-9_]*)/__init__\.py$", f)
        if m:
            mods.add(m.group(1)); continue
        m = re.match(r"lib/python[0-9.]+/site-packages/([A-Za-z_][A-Za-z0-9_]*)\.py$", f)
        if m and not m.group(1).startswith("_"):
            mods.add(m.group(1))
print(" ".join(sorted(mods)))
PY
' 2>"$DETECT_ERR" | tr -d '\r')"
  if [ -s "$DETECT_ERR" ]; then
    echo "[smoke] WARNING: module detection wrote to stderr:" >&2
    tail -3 "$DETECT_ERR" >&2
  fi
  rm -f "$DETECT_ERR"
fi

PROVEN=0

# --- level 2: imports -------------------------------------------------------
if [ -n "${MODS// /}" ]; then
  echo "[smoke] ${PKG} installs python modules: ${MODS}"
  if run sh -c "for m in ${MODS}; do python -c \"import \$m\" || exit 1; done" >/dev/null 2>&1; then
    echo "[smoke] imports OK on ${PLATFORM}"
    PROVEN=1
  else
    echo "[smoke] FAIL — ${PKG} installs python modules that do not import on ${PLATFORM}:" >&2
    run sh -c "for m in ${MODS}; do python -c \"import \$m\" 2>&1 | tail -3; done" >&2 || true
    # Usually a python-version mismatch, so surface it: it distinguishes "wrong
    # interpreter" from "incompatible dependency".
    run sh -c 'echo "  active python: $(python -V 2>&1)"; echo "  site-packages: $(ls -d /opt/conda/lib/python*/site-packages 2>/dev/null | tr "\n" " ")"' >&2 || true
    echo "[smoke] refusing to publish: a broken image is worse than an absent one," >&2
    echo "[smoke] because it looks available in the namespace and fails after a pull." >&2
    exit 3
  fi
elif [ "$HAS_PY" = "1" ]; then
  echo "[smoke] note: ${PKG} has no top-level python module in its conda-meta record"
fi

# --- level 1: CLI (only needed if imports didn't already prove it) -----------
if [ "$PROVEN" = "0" ]; then
  if run "$PKG" --version >/dev/null 2>&1 \
     || run "$PKG" --help >/dev/null 2>&1 \
     || run sh -c "command -v $PKG" >/dev/null 2>&1; then
    echo "[smoke] ${PKG} CLI present and runnable on ${PLATFORM}"
    PROVEN=1
  fi
fi

# --- level 3: functional, ALWAYS when a check exists ------------------------
# Deliberately outside the branches above. It was previously nested inside the
# module branch, so whenever detection came back empty the functional check was
# skipped too — the one case where it is most needed.
if [ -f "$FUNC" ]; then
  echo "[smoke] running functional check: functional/${PKG}.py"
  if docker run --rm -i --platform "$PLATFORM" "$IMAGE" python - < "$FUNC" 2>&1 \
       | sed 's/^/[smoke]   /'; then
    echo "[smoke] functional check passed"
    PROVEN=1
  else
    echo "[smoke] FAIL — ${PKG} passes the cheap checks but fails in real use." >&2
    echo "[smoke] Not publishing." >&2
    exit 3
  fi
fi

if [ "$PROVEN" = "1" ]; then
  echo "[smoke] PASS — ${PKG} verified on ${PLATFORM}"
  exit 0
fi

echo "[smoke] FAIL — could not demonstrate ${PKG} works on ${PLATFORM}:" >&2
echo "[smoke] no importable python module, no runnable CLI, no functional check." >&2
exit 3
