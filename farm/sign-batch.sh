#!/usr/bin/env bash
# sign-batch.sh — sign + publish every farm-built (private) tool in the aarchbio
# org that isn't public yet. Dispatches the CI sign-existing workflow one tool at
# a time, waits for each, and records results. Resumable: re-running skips tools
# already public.
#
# Run backgrounded for long batches; reads the live registry so it needs no input
# list. Requires gh auth + QUAY_OAUTH_TOKEN in ../.env.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi
TOK="$(sed -n 's/^QUAY_OAUTH_TOKEN="\(.*\)"/\1/p' "$REPO/.env")"
RESULTS="$HERE/sign-batch-results.tsv"; : > "$RESULTS"

# List private repos + their current non-sig tag, as "tool:tag".
list_private() {
  QUAY_OAUTH_TOKEN="$TOK" "${PY[@]}" - <<'PY'
import json,os,urllib.request
tok=os.environ["QUAY_OAUTH_TOKEN"]
def api(p):
    r=urllib.request.Request("https://quay.io/api/v1/"+p,headers={"Authorization":"Bearer "+tok})
    return json.load(urllib.request.urlopen(r,timeout=30))
priv=sorted(x["name"] for x in api("repository?namespace=aarchbio&public=true&private=true")["repositories"] if not x.get("is_public"))
for tool in priv:
    tags=[t["name"] for t in api(f"repository/aarchbio/{tool}/tag/?onlyActiveTags=true&limit=50").get("tags",[])
          if not t["name"].endswith((".sig",".att")) and not t["name"].startswith("sha256-")]
    if tags: print(f"{tool}:{tags[0]}")
PY
}

mapfile -t refs < <(list_private)
echo "[sign-batch] $(printf '%s' "${#refs[@]}") private tools to sign"
n=0
for ref in "${refs[@]}"; do
  n=$((n+1))
  gh workflow run sign-existing.yml --repo playgroundlogic/aarchbio -f images="$ref" >/dev/null 2>&1
  sleep 6
  rid=$(gh run list --repo playgroundlogic/aarchbio --workflow sign-existing.yml --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
  gh run watch "$rid" --repo playgroundlogic/aarchbio --exit-status >/dev/null 2>&1
  concl=$(gh run view "$rid" --repo playgroundlogic/aarchbio --json conclusion --jq .conclusion 2>/dev/null)
  printf '%s\t%s\n' "$ref" "$concl" >> "$RESULTS"
  echo "[sign-batch] [$n/${#refs[@]}] $ref -> $concl"
done
echo "[sign-batch] done"
awk -F'\t' '{c[$2]++} END{for(k in c) printf "  %s: %d\n",k,c[k]}' "$RESULTS"
