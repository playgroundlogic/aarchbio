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
# Does channel <1> actually publish package <2>? Used to tell "no recipe at that
# path" apart from "not in this channel" — see the multi-output note below.
in_channel() {
  # Deliberately NOT `curl ... | grep -q`: grep -q exits at the first match, curl
  # then dies on EPIPE, and under `pipefail` that poisons the whole pipeline, so
  # a package that IS in the channel reports as absent. (The API response is well
  # over a pipe buffer, so this fired every time — it reported gatk4-spark as
  # being in neither channel. Same hazard documented in builder/classify.sh.)
  # Matching with `case` uses no pipe at all.
  local resp
  resp="$(curl -s "https://api.anaconda.org/package/$1/$2" 2>/dev/null)"
  case "$resp" in *'"latest_version"'*) return 0 ;; *) return 1 ;; esac
}

for pkg in "$@"; do
  [ -z "$pkg" ] && continue
  recipe="$pkg"
  yaml="$(curl -s "$RAW/$pkg/meta.yaml" 2>/dev/null)"
  if [ -z "$yaml" ] || printf '%s' "$yaml" | grep -q "404: Not Found"; then
    # A missing recipes/<pkg>/meta.yaml does NOT mean "not in bioconda". Bioconda
    # has MULTI-OUTPUT recipes: one recipe dir builds several packages, so e.g.
    # `gatk4-spark` is an output of recipes/gatk4. Reporting those as
    # "not-bioconda — likely conda-forge" sent you to a feedstock that doesn't
    # exist while the real recipe was one directory away. Ask the API who
    # actually publishes it before concluding anything.
    if in_channel bioconda "$pkg"; then
      # Find the parent recipe by stripping trailing "-<segment>"s (the usual
      # naming for a variant output: gatk4-spark -> gatk4), and confirm the
      # candidate recipe really names this package as an output.
      cand="$pkg"
      while [ "$cand" != "${cand%-*}" ]; do
        cand="${cand%-*}"
        try="$(curl -s "$RAW/$cand/meta.yaml" 2>/dev/null)"
        if [ -n "$try" ] && ! printf '%s' "$try" | grep -q "404: Not Found" \
           && printf '%s' "$try" | grep -qF "$pkg"; then   # -F: package names contain '+', '.'
          yaml="$try"; recipe="$cand"; break
        fi
      done
    fi
    if [ "$recipe" = "$pkg" ]; then
      if in_channel conda-forge "$pkg"; then
        printf "%s\tconda-forge\t?\t?\tno bioconda recipe; see conda-forge/%s-feedstock\n" "$pkg" "$pkg"
      elif in_channel bioconda "$pkg"; then
        printf "%s\tbioconda\t?\t?\tin bioconda but no recipes/%s — multi-output recipe, parent not found\n" "$pkg" "$pkg"
      else
        printf "%s\tnot-found\t?\t?\tin neither bioconda nor conda-forge — check the name\n" "$pkg"
      fi
      continue
    fi
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
  # Say so when the answers came from a different recipe dir than the package
  # name, so nobody edits recipes/<pkg> looking for the pin they just read about.
  [ "$recipe" = "$pkg" ] || note="[via multi-output recipes/${recipe}] ${note}"
  printf "%s\tbioconda\t%s\t%s\t%s\n" "$pkg" "$arm" "${maint:-?}" "${note:-}"
done
