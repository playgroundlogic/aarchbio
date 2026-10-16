#!/bin/sh
# tag-check.sh — runs INSIDE an image. Asserts the package conda actually installed
# is the version and build the image's tag claims.
#
# The project's tag scheme is <version>--<build>, read back from the finished image
# (DESIGN.md D4/D6) so that "a pulled image always contains exactly what its tag
# claims". build.sh enforces that at publish time today, but nothing ever checked
# images built before that guard existed — and one was found lying:
#
#   control-freec:11.6--hdc89528_3   actually contains   control-freec 11.6b hdc89528_3
#
# conda treats `pkg=11.6` as a PREFIX match, so the request resolved 11.6b and the
# tag recorded what was asked for instead of what was installed. Its OCI version
# label says 11.6 as well, so no metadata reveals it; only the installed record does.
#
# Piped in like arch-check.sh:  docker run --rm -i IMG sh -s -- PKG VERSION BUILD
# Plain POSIX sh with no python, because many images have no interpreter.
#
# Output: TAG_OK / TAG_MISMATCH <claimed> <installed> / TAG_UNKNOWN <reason>
# Exit:   0 match, 1 mismatch, 2 could not determine (caller decides)
PKG="${1:?usage: tag-check.sh <pkg> <version> [build]}"
WANT_VER="${2:?usage: tag-check.sh <pkg> <version> [build]}"
WANT_BUILD="${3:-}"

found=""
for rec in /opt/conda/conda-meta/"${PKG}"-*.json; do
  [ -f "$rec" ] || continue
  base="$(basename "$rec" .json)"
  rest="${base#"${PKG}"-}"
  # Conda forbids '-' in both versions and build strings, so a record for THIS
  # package leaves exactly one hyphen after the "<pkg>-" prefix. Anything else is a
  # different package that merely shares the prefix: for pkg gatk4 the glob also
  # matches gatk4-spark-4.6.1.0-hdfd78af_0.json, which must not be mistaken for it.
  case "$rest" in
    *-*-*) continue ;;
    *-*)   ;;
    *)     continue ;;
  esac
  if [ -n "$found" ]; then
    echo "TAG_UNKNOWN more than one installed record for ${PKG}"
    exit 2
  fi
  found="$rest"
done

if [ -z "$found" ]; then
  # A legitimate state for a few images (a package fetched entirely by a post-link
  # script still has a record, but be explicit rather than silently passing).
  echo "TAG_UNKNOWN no installed conda record for ${PKG}"
  exit 2
fi

got_ver="${found%-*}"
got_build="${found##*-}"

if [ "$got_ver" != "$WANT_VER" ]; then
  echo "TAG_MISMATCH ${WANT_VER}--${WANT_BUILD:-?} ${got_ver}--${got_build}"
  exit 1
fi
if [ -n "$WANT_BUILD" ] && [ "$got_build" != "$WANT_BUILD" ]; then
  echo "TAG_MISMATCH ${WANT_VER}--${WANT_BUILD} ${got_ver}--${got_build}"
  exit 1
fi
echo "TAG_OK ${got_ver}--${got_build}"
exit 0
