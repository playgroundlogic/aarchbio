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
# Output lines: ARCH_SKIP (deliberate multi-arch payload), ARCH_BAD <sev> <file>
#   <arch>, ARCH_CHECKED <n>, ARCH_RESULT {OK|WARN <n> vendored|FAIL <n> critical...}
# Exit: 1 only if a CRITICAL (on-PATH) mismatch was found; 0 for OK and for
#   vendored-only mismatches, which the caller should warn about rather than block.
EXPECT="${1:?usage: arch-check.sh <expected e_machine, e.g. 183>}"

bad=0
crit=0
checked=0

check_one() {
  f="$1"
  [ -f "$f" ] || return 0
  # Only real ELFs. Shell scripts, perl, text and symlinks-to-nothing are skipped
  # here; a dangling entry point is the entry-point check's job, not this one.
  [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = "7f454c46" ] || return 0

  # Deliberately multi-arch payloads: some packages ship one .so per architecture
  # with the arch in the FILENAME and pick the right one at runtime. The ONT
  # vbz_hdf_plugin does exactly this — libvbz_hdf_plugin_x86_64.so sits next to
  # libvbz_hdf_plugin_aarch64.so. Flagging those produced three false positives
  # (medaka, dragonflye, toulligqc), all of which work correctly. Skip a
  # foreign-arch-named file only when the native-arch sibling is actually present,
  # so a package shipping ONLY the x86 variant is still caught.
  base="$(basename "$f")"
  case "$base" in
    *x86_64*|*x86-64*|*amd64*)
      if [ "$EXPECT" = "183" ]; then
        for alt in "$(dirname "$f")/$(echo "$base" | sed 's/x86_64/aarch64/; s/x86-64/aarch64/; s/amd64/arm64/')"; do
          if [ -f "$alt" ]; then
            echo "ARCH_SKIP ${f} (native sibling $(basename "$alt") present)"
            return 0
          fi
        done
      fi
      ;;
  esac

  m="$(od -An -tu1 -j18 -N1 "$f" 2>/dev/null | tr -d ' ')"
  checked=$((checked + 1))
  if [ "$m" != "$EXPECT" ]; then
    bad=$((bad + 1))
    # Severity by location. A foreign binary on PATH means the tool itself cannot
    # run (pureclip, glnexus, humann's bowtie2, real-tbl2asn). One buried in a
    # vendored sub-library may never be loaded at all — riboWaltz ships an x86-64
    # `pak` private library and the package itself loads and works fine. Blocking
    # that would withhold a working tool, so the two are reported separately and
    # the caller decides.
    case "$f" in
      /opt/conda/bin/*|/opt/conda/libexec/*) sev="CRITICAL" ;;
      *) sev="VENDORED" ;;
    esac
    # Name the architecture rather than the raw number — the number alone sends
    # the reader to a lookup table.
    case "$m" in
      62)  name="x86-64" ;;
      183) name="AArch64" ;;
      3)   name="i386" ;;
      40)  name="ARM(32)" ;;
      *)   name="e_machine=$m" ;;
    esac
    echo "ARCH_BAD ${sev} ${f} ${name}"
    [ "$sev" = "CRITICAL" ] && crit=$((crit + 1))
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
# Exit status reflects CRITICAL only. Vendored findings are reported for the caller
# to warn about and record, not to block a tool that demonstrably works.
if [ "$crit" -gt 0 ]; then
  echo "ARCH_RESULT FAIL ${crit} critical, $((bad - crit)) vendored"
  exit 1
fi
if [ "$bad" -gt 0 ]; then
  echo "ARCH_RESULT WARN ${bad} vendored"
  exit 0
fi
echo "ARCH_RESULT OK"
exit 0
