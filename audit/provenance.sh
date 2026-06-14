#!/usr/bin/env bash
# provenance.sh — for a gap (a tool, or a blocking dependency), trace it back to
# its bioconda recipe and surface WHO owns it and WHETHER arm64 is enabled.
#
# Every bioconda recipe (recipes/<pkg>/meta.yaml) carries:
#   extra.recipe-maintainers   — GitHub handles to @-mention upstream
#   extra.additional-platforms — whether linux-aarch64 is enabled (+ often a
#                                comment / PR link if deliberately disabled)
#   about.home / source.url    — upstream project
#
# This turns "X is a gap" into "X is a gap; recipe owned by @a @b; arm64
# {enabled / disabled because <reason+PR> / not mentioned}" — so gaps become
# actionable and attributable instead of anonymous.
#
# Usage:  ./provenance.sh <pkg> [<pkg> ...]
# Output: TSV  tool  channel  arm64_status  maintainers  home/note
set -uo pipefail
RAW="https://raw.githubusercontent.com/bioconda/bioconda-recipes/master/recipes"

printf "tool\tchannel\tarm64\tmaintainers\tnote\n"
for pkg in "$@"; do
  [ -z "$pkg" ] && continue
  yaml="$(curl -s "$RAW/$pkg/meta.yaml" 2>/dev/null)"
  if [ -z "$yaml" ] || printf '%s' "$yaml" | grep -q "404: Not Found"; then
    # not in bioconda — likely conda-forge (a different channel/maintainer set)
    printf "%s\tnot-bioconda\t?\t?\tlikely conda-forge — check conda-forge/%s-feedstock\n" "$pkg" "$pkg"
    continue
  fi
  # maintainers: the indented list under recipe-maintainers
  maint="$(printf '%s' "$yaml" | awk '/recipe-maintainers:/{f=1;next} f&&/^[[:space:]]+-/{gsub(/[ -]/,"");print;next} f&&/^[^[:space:]]/{exit} f&&/^[[:space:]]*[a-z]/{exit}' | tr '\n' ',' | sed 's/,$//')"
  # arm64 status
  if printf '%s' "$yaml" | grep -qE "^[[:space:]]*-[[:space:]]*linux-aarch64"; then
    arm="enabled"; note="$(printf '%s' "$yaml" | grep -E "^[[:space:]]+home:" | head -1 | sed 's/.*home:[[:space:]]*//; s/"//g')"
  elif printf '%s' "$yaml" | grep -qiE "aarch64|arm64"; then
    arm="disabled"
    note="$(printf '%s' "$yaml" | grep -iE "aarch64|arm64" | grep -iE "skip|until|resolv|see:|#" | head -1 | sed 's/^[[:space:]]*#*[[:space:]]*//')"
  else
    arm="not-mentioned"; note="$(printf '%s' "$yaml" | grep -E "^[[:space:]]+home:" | head -1 | sed 's/.*home:[[:space:]]*//; s/"//g')"
  fi
  printf "%s\tbioconda\t%s\t%s\t%s\n" "$pkg" "$arm" "${maint:-?}" "${note:-}"
done
