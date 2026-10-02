#!/bin/sh
# arch-check.sh — runs INSIDE an image. Asserts every ELF binary in the env is
# built for the expected architecture.
#
# Piped in rather than copied: `docker run --rm -i IMAGE sh -s -- 183 < arch-check.sh`
# so it needs nothing in the image but a POSIX shell and od (busybox has both).
# Deliberately NOT python: the images that most need this check are compiled tools
# with no interpreter at all.
#
# Why this exists: the catalog audit found SEVEN images shipping x86-64 binaries
# under an arm64 tag, and five of them passed the rest of the gate. Two examples:
#   pureclip 1.3.1 — /opt/conda/bin/pureclip, the package's own primary binary,
#     is x86-64. `command -v pureclip` succeeds, so the gate passed it.
#   humann 3.9 — the noarch package bundles x86-64 bin/bowtie2-* and bin/diamond,
#     overwriting the correct aarch64 binaries its own dependencies installed.
#
# And why a local "it ran fine" proves nothing: Docker Desktop on Apple Silicon has
# a Rosetta binfmt handler, so a STATICALLY linked x86-64 binary executes happily
# on a Mac while being unrunnable on the actual Graviton target. Dynamically linked
# ones fail even locally with "failed to open elf at /lib64/ld-linux-x86-64.so.2".
# So architecture must be read from the ELF header, never inferred from behaviour.
#
# ELF layout: bytes 0-3 are the magic 7f 45 4c 46; byte 18 (decimal) is e_machine.
#   183 = AArch64,  62 = x86-64.
#
# Usage (inside the image):  sh arch-check.sh <expected-e_machine>
# Exit: 0 all ELFs match, 1 at least one does not.
EXPECT="${1:?usage: arch-check.sh <expected e_machine, e.g. 183>}"

bad=0
checked=0

check_one() {
  f="$1"
  [ -f "$f" ] || return 0
  # Only real ELFs. Shell scripts, perl, text and symlinks-to-nothing are skipped
  # here; a dangling entry point is the entry-point check's job, not this one.
  [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || return 0
  m="$(od -An -tu1 -j18 -N1 "$f" 2>/dev/null | tr -d ' ')"
  checked=$((checked + 1))
  if [ "$m" != "$EXPECT" ]; then
    bad=$((bad + 1))
    # Name the architecture rather than the raw number — the number alone sends
    # the reader to a lookup table.
    case "$m" in
      62)  name="x86-64" ;;
      183) name="AArch64" ;;
      3)   name="i386" ;;
      40)  name="ARM(32)" ;;
      *)   name="e_machine=$m" ;;
    esac
    echo "ARCH_BAD ${f} ${name}"
  fi
}

# Executables first (the common case), then vendored shared objects — maxquant's
# x86-64 payload was .so files under lib/, invisible to a bin/-only scan.
for f in /opt/conda/bin/* /opt/conda/libexec/*; do
  check_one "$f"
done

# Bounded: -type f only, skip the huge site-packages tree's compiled extensions
# only if it would be unreasonably slow. In practice this is a few seconds.
for f in $(find /opt/conda/lib -type f -name '*.so' -o -type f -name '*.so.*' 2>/dev/null); do
  check_one "$f"
done

echo "ARCH_CHECKED ${checked}"
if [ "$bad" -gt 0 ]; then
  echo "ARCH_RESULT FAIL ${bad}"
  exit 1
fi
echo "ARCH_RESULT OK"
exit 0
