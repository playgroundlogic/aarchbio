#!/usr/bin/env bash
# audit.sh — survey the arm64 readiness of bioconda tools, to quantify "how
# messed up this is": for each tool, does an arm64 conda package exist, and in
# what form. Package-level (authoritative, API-only — no container pulls).
#
# Buckets per tool (from anaconda.org bioconda channel subdirs):
#   noarch          — arch-neutral package; SHOULD run anywhere (the most absurd
#                     case when its container is amd64-only)
#   linux-aarch64   — native arm64 build exists
#   linux-64-only   — amd64 package exists but NO arm64 (the "hard 15%")
#   missing         — no package found at all (bad name / not in bioconda)
#
# Usage:  ./audit.sh tool1 tool2 ...     (or: ./audit.sh < tools.txt)
# Output: TSV to stdout (tool, latest_version, subdirs, bucket) + a summary.
set -uo pipefail

if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi

tools=("$@")
if [ "${#tools[@]}" -eq 0 ]; then mapfile -t tools; fi   # read from stdin if no args

printf "tool\tlatest\tsubdirs\tbucket\n"
declare -A count
for t in "${tools[@]}"; do
  [ -z "$t" ] && continue
  line="$(curl -s "https://api.anaconda.org/package/bioconda/$t" | "${PY[@]}" -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception:
    print("\t\tmissing"); sys.exit()
subs=sorted({f.get("attrs",{}).get("subdir","?") for f in d.get("files",[])})
latest=d.get("latest_version","?")
has_noarch = "noarch" in subs
has_arm    = "linux-aarch64" in subs
has_amd    = "linux-64" in subs
if has_noarch and not has_arm:
    bucket="noarch"
elif has_arm:
    bucket="linux-aarch64"
elif has_amd:
    bucket="linux-64-only"
else:
    bucket="missing"
tab=chr(9)
print(tab.join([str(latest), ",".join(subs), bucket]))
')"
  bucket="$(printf '%s' "$line" | awk -F'\t' '{print $NF}')"
  count["$bucket"]=$(( ${count["$bucket"]:-0} + 1 ))
  printf "%s\t%s\n" "$t" "$line"
done

# Summary to stderr so stdout stays clean TSV.
{
  echo ""
  echo "=== summary (n=${#tools[@]}) ==="
  total=0; for k in "${!count[@]}"; do total=$((total+${count[$k]})); done
  for b in noarch linux-aarch64 linux-64-only missing; do
    c=${count[$b]:-0}; pct=0; [ "$total" -gt 0 ] && pct=$(( c*100/total ))
    printf "  %-16s %3d  (%d%%)\n" "$b" "$c" "$pct"
  done
  arm_ok=$(( ${count[noarch]:-0} + ${count[linux-aarch64]:-0} ))
  [ "$total" -gt 0 ] && printf "  --> arm64-capable: %d/%d (%d%%)\n" "$arm_ok" "$total" "$(( arm_ok*100/total ))"
} >&2
