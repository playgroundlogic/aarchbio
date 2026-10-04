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
# Five levels, in increasing strength. Each exists because the level above it let a
# real defect through, so none of them is redundant:
#
#   0. Arch        — e_machine of every ELF (arch-check.sh). 7 images shipped
#      x86-64 payloads under an arm64 tag and 5 passed everything else; pureclip's
#      own primary binary is x86-64. On-PATH mismatches are fatal; vendored ones
#      warn, because riboWaltz ships an x86-64 `pak` library and still works.
#   1. Entry point — the binaries the package owns, per conda-meta, EXECUTED.
#      `command -v $PKG` was wrong twice: the binary is usually not named after the
#      package (abyss->abyss-pe, star->STAR: 95 false FAILs), and existence is not
#      execution (transdecoder's entry points are dangling symlinks).
#   2. Import      — every python module the package installs must import. Caught
#      humann 3.9, published as subdir=noarch with a py312 build string and only
#      `python >=3`, its files baked at lib/python3.12/site-packages, so against
#      python 3.13 they sat where python never looks.
#   2b. R library  — Rscript library(). R/bioconductor packages have no CLI and no
#      python module, so nothing could ever prove them: 8 more false FAILs.
#   3. Functional  — optional builder/functional/<pkg>.py, run inside the image.
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
# A functional check may be python (.py, run with `python -`) or shell (.sh, run
# with `sh -s`). evigene needs shell: it has no python and is driven through
# $EVIGENEHOME rather than a binary on PATH.
FUNC=""
FUNC_RUNNER=""
if [ -f "${HERE_SMOKE}/functional/${PKG}.py" ]; then
  FUNC="${HERE_SMOKE}/functional/${PKG}.py"; FUNC_RUNNER="python -"
elif [ -f "${HERE_SMOKE}/functional/${PKG}.sh" ]; then
  FUNC="${HERE_SMOKE}/functional/${PKG}.sh"; FUNC_RUNNER="sh -s"
fi

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
  echo "[smoke] FAIL — image has WRONG-ARCHITECTURE binaries on PATH:" >&2
  printf '%s\n' "$ARCH_OUT" | grep '^ARCH_BAD CRITICAL' | head -20 | sed 's/^ARCH_BAD CRITICAL /[smoke]   /' >&2
  echo "[smoke]   ($(printf '%s' "$ARCH_OUT" | sed -n 's/^ARCH_RESULT FAIL //p'), of $(printf '%s' "$ARCH_OUT" | sed -n 's/^ARCH_CHECKED //p') ELF files checked)" >&2
  echo "[smoke] These may appear to run on an Apple Silicon Mac via Rosetta and" >&2
  echo "[smoke] CANNOT execute on an aarch64 Linux host. Not publishing." >&2
  exit 3
fi
# Vendored mismatches do not block: the tool itself may never load them, and the
# remaining levels still have to prove the package works. They ARE surfaced,
# because "mostly native" is a claim users deserve to see rather than discover.
if printf '%s' "$ARCH_OUT" | grep -q '^ARCH_RESULT WARN'; then
  echo "[smoke] WARNING: non-native binaries present, none on PATH:" >&2
  printf '%s\n' "$ARCH_OUT" | grep '^ARCH_BAD VENDORED' | head -8 | sed 's/^ARCH_BAD VENDORED /[smoke]   /' >&2
  n_v="$(printf '%s\n' "$ARCH_OUT" | grep -c '^ARCH_BAD VENDORED' || true)"
  [ "$n_v" -gt 8 ] && echo "[smoke]   ... and $((n_v - 8)) more" >&2
  echo "[smoke] Not blocking: these are vendored sub-libraries, not the tool's own" >&2
  echo "[smoke] entry points. The levels below must still prove the package works." >&2
fi
if printf '%s' "$ARCH_OUT" | grep -q '^ARCH_SKIP'; then
  echo "[smoke] (skipped $(printf '%s\n' "$ARCH_OUT" | grep -c '^ARCH_SKIP') deliberate multi-arch payload(s) with a native sibling)"
fi
echo "[smoke] arch checked: $(printf '%s' "$ARCH_OUT" | sed -n 's/^ARCH_CHECKED //p') ELF files for ${PLATFORM}"

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
  if [ -z "${RLIBS// /}" ]; then
    # Data packages fetch their R library in a post-link script, so conda-meta
    # lists no files at all (minfidata's record has zero). Fall back to looking for
    # an installed library whose name matches the package minus its channel prefix,
    # case-insensitively: bioconductor-minfidata -> minfiData.
    RLIBS="$(run sh -c '
      want=$(echo "'"$PKG"'" | sed "s/^bioconductor-//; s/^r-//" | tr "[:upper:]" "[:lower:]")
      for d in /opt/conda/lib/R/library/*/; do
        b=$(basename "$d")
        [ "$(echo "$b" | tr "[:upper:]" "[:lower:]")" = "$want" ] && echo "$b"
      done
    ' 2>/dev/null | tr -d "\r")"
    [ -n "${RLIBS// /}" ] && echo "[smoke] (R library found on disk, not in conda-meta: ${RLIBS})"
  fi
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
    # Exclude conda machinery: post-link / pre-unlink hooks are install-time
    # scripts, not user-facing programs. bioconductor-minfidata "passed" by
    # executing bin/.bioconductor-minfidata-post-link.sh (exit 1 counts as
    # "it ran"), which proves nothing — and every bioconductor package ships one.
    grep -o "\"\(bin\|libexec\)/[^\"]*\"" "$rec" | tr -d "\"" \
      | grep -v "/\." | grep -vE "(post-link|pre-unlink|post-unlink|pre-link)" | head -40
  ' 2>/dev/null | tr -d '\r')"

  if [ -z "${ENTRIES// /}" ]; then
    # Metapackages own NO files at all (`"files": []`) and exist only to pull in
    # dependencies that provide the actual program — tabix is a metapackage whose
    # binary comes from htslib, and gatk4-spark's launcher comes from gatk4. Since
    # there is nothing of its own to test, fall back to executing the package name
    # itself. This is the one case where that is the right check rather than a lazy
    # one, and it is still execution, not mere existence.
    echo "[smoke] note: ${PKG} owns no bin/ or libexec/ entry point (metapackage?); trying the name itself"
    # Some metapackages provide a binary under a different name again, which no
    # amount of inference can discover: gatk4-spark ships only a .jar and is run
    # by `gatk` from its gatk4 dependency. Those get an explicit one-line override
    # in builder/entrypoints/<pkg> rather than a guess.
    CANDIDATES="$PKG"
    if [ -f "${HERE_SMOKE}/entrypoints/${PKG}" ]; then
      extra_names="$(grep -v '^[[:space:]]*#' "${HERE_SMOKE}/entrypoints/${PKG}" | tr '\n' ' ')"
      CANDIDATES="$PKG $extra_names"
      echo "[smoke] entrypoint override: ${extra_names}"
    fi
    for cand in $CANDIDATES; do
    for probe in --version --help; do
      rc="$(run sh -c "command -v '$cand' >/dev/null 2>&1 && $cand $probe >/dev/null 2>&1; echo \$?" 2>/dev/null | tr -d '\r')"
      case "$rc" in
        126|127|"") ;;
        *) echo "[smoke] ${cand} executes (exit ${rc})"; PROVEN=1; break ;;
      esac
    done
    [ "$PROVEN" = "1" ] && break
    done
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
if [ -n "$FUNC" ]; then
  echo "[smoke] running functional check: $(basename "$FUNC")"
  if docker run --rm -i --platform "$PLATFORM" "$IMAGE" $FUNC_RUNNER < "$FUNC" 2>&1 \
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
