#!/usr/bin/env bash
# gap-enrich.sh — for each "tool=version" gap (no arm64 at that pinned version),
# determine WHY: does the tool have arm64 at some OTHER version? This distinguishes
# the two gap kinds (D10):
#   never-arm64   — no version of the tool has a linux-aarch64/noarch build
#   version-pin   — arm64 exists, but not at the pinned version (note the earliest
#                   arm64-having version so a pipeline can bump to it)
#
# Uses the anaconda.org API (authoritative across all versions). No builds.
# Usage:  ./gap-enrich.sh tool=version [tool=version ...]   (or < gaps.txt)
# Output: TSV  tool  pinned_version  kind  arm64_versions
set -uo pipefail
if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi

specs=("$@"); [ "${#specs[@]}" -eq 0 ] && mapfile -t specs

printf "tool\tpinned\tkind\tarm64_versions\n"
for spec in "${specs[@]}"; do
  [ -z "$spec" ] && continue
  pkg="${spec%%=*}"; ver="${spec#*=}"
  curl -s "https://api.anaconda.org/package/bioconda/$pkg" | "${PY[@]}" -c '
import json,sys
pkg,ver=sys.argv[1],sys.argv[2]
try: d=json.load(sys.stdin)
except Exception:
    print(f"{pkg}\t{ver}\tmissing\t"); sys.exit()
# versions that have an arm64-capable file (linux-aarch64 or noarch)
arm=set()
pinned_has=False
for f in d.get("files",[]):
    sd=f.get("attrs",{}).get("subdir",""); v=f.get("version","")  # version is top-level
    if sd in ("linux-aarch64","noarch"):
        arm.add(v)
        if v==ver: pinned_has=True
def vkey(s):
    import re
    # tuple of (is_str, int_or_0, str) per component -> always comparable
    out=[]
    for x in re.split(r"[._-]", s):
        if x.isdigit(): out.append((0, int(x), ""))
        else: out.append((1, 0, x))
    return out
arms=sorted(arm, key=vkey)
# NOTE: presence of an arm64/noarch FILE at a version does NOT guarantee the
# package INSTALLS on arm64 — its dependency closure may lack arm64 builds (a
# noarch package can still be un-installable on arm64). The build/solve is the
# authoritative gate; this enrichment only explains the package-level situation.
if pinned_has:
    # arm64 file exists at the pinned version yet the farm gapped it => the
    # FAILURE is in dependencies, not the package itself.
    kind="dep-gap"         # noarch/arm64 pkg, but arm64 deps fail to resolve
elif arm:
    kind="version-pin"     # arm64 pkg exists at OTHER versions (bump target below)
else:
    kind="never-arm64"     # no arm64 build at any version — genuine hard tail
# show a few arm64 versions (earliest + latest) as the bump target
hint=""
if arms: hint = arms[0] + (" .. " + arms[-1] if len(arms)>1 else "")
print(f"{pkg}\t{ver}\t{kind}\t{hint}")
' "$pkg" "$ver"
done
