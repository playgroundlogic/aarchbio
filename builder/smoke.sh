#!/usr/bin/env bash
# smoke.sh — prove an image's own package actually works, and FAIL if it doesn't.
#
# Single-sourced because there are two publish paths and only one of them used to
# have any check at all:
#   build.sh       arch-specific -> arm64-only tag   (had an advisory check)
#   build-arch.sh  noarch -> one leg of a multi-arch manifest (had NO check)
# Both scanpy 1.7.2 (#63) and humann 3.9 are noarch, so they went through the
# unchecked path. Duplicating the logic would have let them drift apart again.
#
# Why importing matters more than running a CLI: a library has no CLI, so
# `$PKG --version` is vacuous for it. Two real defects, both invisible to a CLI
# probe and both caught by an import:
#   scanpy 1.7.2 — bioconda froze it in 2021 with loose deps, so the solver paired
#     it with a 2025 anndata; `from anndata import read` no longer exists.
#   humann 3.9   — published as subdir=noarch but with a py312 build string and
#     only `python >=3`, while its files are baked at lib/python3.12/site-packages.
#     Installed against python 3.13 the files sit where python never looks.
#
# Module names come from the package's own conda-meta file list, never guessed
# from the package name: pycoqc ships pycoQC, scikit-learn ships sklearn, so
# guessing would reintroduce exactly the false pass this is meant to stop.
#
# Usage:  ./smoke.sh <image-ref> <pkg> [platform]
# Exit:   0 = proven working, 3 = could not prove it (caller must not publish)
set -uo pipefail

IMAGE="${1:?usage: smoke.sh <image-ref> <pkg> [platform]}"
PKG="${2:?usage: smoke.sh <image-ref> <pkg> [platform]}"
PLATFORM="${3:-linux/arm64}"

run() { docker run --rm --platform "$PLATFORM" "$IMAGE" "$@"; }

# Which top-level python modules does THIS package install?
MODS="$(run sh -c '
  command -v python >/dev/null 2>&1 || exit 0
  python - '"$PKG"' <<'"'"'PY'"'"' 2>/dev/null
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
' 2>/dev/null | tr -d '\r')"

# An optional per-tool FUNCTIONAL check, for tools where importing proves too
# little. Convention: builder/functional/<pkg>.py, run inside the image if present.
#
# Needed because import is a weak proxy. aarchbio#63 round two: scanpy imported
# fine, loaded data, normalised, ran PCA and built a neighbour graph, and only
# failed at sc.tl.leiden because the clustering backends were missing. The generic
# builder cannot synthesise a meaningful workload per tool, so the tools that
# warrant one get a hand-written file, and everything else keeps the import gate.
HERE_SMOKE="$(cd "$(dirname "$0")" && pwd)"
FUNC="${HERE_SMOKE}/functional/${PKG}.py"

functional_check() {
  [ -f "$FUNC" ] || return 0
  echo "[smoke] running functional check: functional/${PKG}.py"
  if docker run --rm -i --platform "$PLATFORM" "$IMAGE" python - < "$FUNC" 2>&1 \
       | sed 's/^/[smoke]   /'; then
    return 0
  fi
  echo "[smoke] FAIL — ${PKG} imports but its functional check did not pass." >&2
  echo "[smoke] The package loads and then fails in real use, which an import" >&2
  echo "[smoke] test cannot see. Not publishing." >&2
  return 1
}

if [ -n "${MODS// /}" ]; then
  echo "[smoke] ${PKG} installs python modules: ${MODS}"
  if run sh -c "for m in ${MODS}; do python -c \"import \$m\" || exit 1; done" >/dev/null 2>&1; then
    echo "[smoke] imports OK on ${PLATFORM}"
    if ! functional_check; then exit 3; fi
    echo "[smoke] PASS — ${PKG} verified on ${PLATFORM}"
    exit 0
  fi
  echo "[smoke] FAIL — ${PKG} installs python modules that do not import on ${PLATFORM}:" >&2
  run sh -c "for m in ${MODS}; do python -c \"import \$m\" 2>&1 | tail -3; done" >&2 || true
  # The usual cause is a python-version mismatch, so surface it: it makes the
  # difference between "wrong interpreter" and "incompatible dependency" obvious.
  run sh -c 'echo "  active python: $(python -V 2>&1)"; echo "  site-packages present: $(ls -d /opt/conda/lib/python*/site-packages 2>/dev/null | tr "\n" " ")"' >&2 || true
  echo "[smoke] refusing to publish: a broken image is worse than an absent one," >&2
  echo "[smoke] because it looks available in the namespace and fails after a pull." >&2
  exit 3
fi

# No python modules: fall back to proving a CLI exists and runs.
if run "$PKG" --version >/dev/null 2>&1 \
   || run "$PKG" --help >/dev/null 2>&1 \
   || run sh -c "command -v $PKG" >/dev/null 2>&1; then
  echo "[smoke] PASS — ${PKG} CLI present and runnable on ${PLATFORM}"
  exit 0
fi

echo "[smoke] FAIL — no importable python module and no runnable ${PKG} CLI on ${PLATFORM}." >&2
echo "[smoke] Cannot demonstrate this image works, so it must not be published." >&2
exit 3
