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

# --- level 0: architecture integrity (MANDATORY, before anything else) -------
# The project's entire premise is "native, never emulated", and until the catalog
# audit nothing enforced it: 7 images shipped x86-64 binaries and 5 passed the gate.
# This runs first because it is the one check that cannot be satisfied by accident,
# and because behaviour is not evidence here — Docker Desktop's Rosetta handler
# runs static x86-64 binaries happily on a Mac while they cannot execute on
# Graviton. Read the ELF header, don't trust the exit code.
case "$PLATFORM" in
  linux/arm64) EXPECT_MACHINE=183 ;;
  linux/amd64) EXPECT_MACHINE=62  ;;
  *) echo "[smoke] FAIL — unknown platform ${PLATFORM}; refusing to guess its ELF machine." >&2; exit 3 ;;
esac
echo "[smoke] checking ELF architecture (expect e_machine=${EXPECT_MACHINE} for ${PLATFORM}) ..."
ARCH_OUT="$(docker run --rm -i --platform "$PLATFORM" "$IMAGE" sh -s -- "$EXPECT_MACHINE" \
            < "${HERE_SMOKE}/arch-check.sh" 2>&1)"
if printf '%s' "$ARCH_OUT" | grep -q '^ARCH_RESULT FAIL'; then
  echo "[smoke] FAIL — image contains binaries for the WRONG ARCHITECTURE:" >&2
  printf '%s\n' "$ARCH_OUT" | grep '^ARCH_BAD' | head -20 | sed 's/^ARCH_BAD /[smoke]   /' >&2
  n_bad="$(printf '%s' "$ARCH_OUT" | sed -n 's/^ARCH_RESULT FAIL //p')"
  echo "[smoke]   (${n_bad} mismatched of $(printf '%s' "$ARCH_OUT" | sed -n 's/^ARCH_CHECKED //p') ELF files)" >&2
  echo "[smoke] These may appear to run on an Apple Silicon Mac via Rosetta and" >&2
  echo "[smoke] CANNOT execute on an aarch64 Linux host. Not publishing." >&2
  exit 3
fi
echo "[smoke] arch OK ($(printf '%s' "$ARCH_OUT" | sed -n 's/^ARCH_CHECKED //p') ELF files, all ${PLATFORM})"

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

# --- level 2b: R libraries, the R analogue of the import check ---------------
# R/bioconductor packages ship no CLI and no python module, so every level above
# was blind to them — 8 of the audit's false FAILs were exactly this. The library
# directory name is read from conda-meta (DESeq2, ASCAT, riboWaltz), because it is
# capitalised differently from the conda package name (bioconductor-deseq2).
if [ "$PROVEN" = "0" ]; then
  RLIBS="$(run sh -c '
    rec=$(ls /opt/conda/conda-meta/'"$PKG"'-*.json 2>/dev/null | head -1)
    [ -n "$rec" ] || exit 0
    grep -o "\"lib/R/library/[^/\"]*/" "$rec" | sed "s|\"lib/R/library/||; s|/$||" | sort -u | head -10
  ' 2>/dev/null | tr -d '\r')"
  if [ -n "${RLIBS// /}" ]; then
    echo "[smoke] ${PKG} ships R library/libraries: ${RLIBS}"
    if run sh -c "for l in ${RLIBS}; do Rscript --vanilla -e \"library(\$l)\" >/dev/null 2>&1 || exit 1; done" >/dev/null 2>&1; then
      echo "[smoke] R library/libraries load on ${PLATFORM}"
      PROVEN=1
    else
      echo "[smoke] FAIL — ${PKG} ships R libraries that do not load on ${PLATFORM}:" >&2
      run sh -c "for l in ${RLIBS}; do Rscript --vanilla -e \"library(\$l)\" 2>&1 | tail -3; done" >&2 || true
      exit 3
    fi
  fi
fi

# --- level 1: entry points, derived from conda-meta and actually EXECUTED -----
# Two fixes over the old `$PKG --version || --help || command -v $PKG`:
#
# 1. The binary is usually not named after the package. That produced 95 false
#    FAILs in the catalog audit — abyss ships abyss-pe, star ships STAR, gatk4
#    ships gatk, emboss ships 442 binaries. Entry points now come from the
#    package's own conda-meta file list.
# 2. `command -v` proves a path exists, not that it runs. transdecoder's three
#    PATH entries are dangling symlinks into a directory that no longer has those
#    names; evigene puts everything under opt/ with nothing on PATH; glnexus's
#    binary is x86-64. All three "passed" existence.
#
# Acceptance is "it executed", not "it exited 0": plenty of bioinformatics tools
# exit non-zero on --version or print usage to stderr. Shells report 127 for
# not-found and 126 for found-but-not-executable, which is exactly the distinction
# that matters, so those two codes are the failure signal.
if [ "$PROVEN" = "0" ]; then
  ENTRIES="$(run sh -c '
    rec=$(ls /opt/conda/conda-meta/'"$PKG"'-*.json 2>/dev/null | head -1)
    [ -n "$rec" ] || exit 0
    grep -o "\"\(bin\|libexec\)/[^\"]*\"" "$rec" | tr -d "\"" | head -40
  ' 2>/dev/null | tr -d '\r')"

  if [ -z "${ENTRIES// /}" ]; then
    echo "[smoke] note: ${PKG} owns no bin/ or libexec/ entry point in its conda-meta record"
  else
    n_entries="$(printf '%s\n' "$ENTRIES" | grep -c . || true)"
    echo "[smoke] ${PKG} owns ${n_entries} entry point(s); checking they execute ..."
    RAN=0
    for e in $ENTRIES; do
      rc="$(run sh -c "/opt/conda/${e} --version >/dev/null 2>&1; echo \$?" 2>/dev/null | tr -d '\r')"
      case "$rc" in
        126|127|"") ;;                       # not found / not executable -> no proof
        *) echo "[smoke] ${e} executes (exit ${rc})"; RAN=1; break ;;
      esac
    done
    if [ "$RAN" = "1" ]; then
      PROVEN=1
    else
      echo "[smoke] FAIL — ${PKG} owns ${n_entries} entry point(s) and NONE of them execute:" >&2
      printf '%s\n' "$ENTRIES" | head -8 | sed 's|^|[smoke]   /opt/conda/|' >&2
      echo "[smoke] (exit 127 = missing target, e.g. a dangling symlink; 126 = not executable)" >&2
      exit 3
    fi
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
