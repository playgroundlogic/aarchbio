#!/usr/bin/env bash
# container_audit.sh — survey what CONTAINERS popular nf-core pipelines actually
# pull, and classify each by registry/form + arm64 availability. This is the
# "scandal" half: not "could tools run on arm64" (package audit) but "what do real
# pipelines force you to pull, and is it arm64".
#
# For each pipeline (latest release), list modules/nf-core/**/main.nf, extract the
# docker container ref, classify:
#   biocontainers   — quay.io/biocontainers/... (legacy; usually noarch or has arm64)
#   wave-plain      — community.wave.seqera.io/library/<single-tool>:...
#   wave-mulled     — community.wave.seqera.io/library/<tool_tool_tool>:<hash> (fused)
#   other
# and probe arm64 (multi-arch manifest? or amd64-only single manifest).
#
# Usage:  ./container_audit.sh pipeline1 pipeline2 ...
# Output: TSV (pipeline, module, ref, class, arch) + summary to stderr.
set -uo pipefail
if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi

pipelines=("$@")
[ "${#pipelines[@]}" -eq 0 ] && pipelines=(taxprofiler sarek rnaseq mag viralrecon)

printf "pipeline\tmodule\tref\tclass\tarch\n"
declare -A cls_count arch_count

classify_ref() {  # echo class given a ref
  case "$1" in
    *quay.io/biocontainers/*|*biocontainers/*) echo biocontainers ;;
    *community.wave.seqera.io/library/*)
      # mulled images fuse multiple tools: name has >1 underscore-joined tool
      name="${1##*/library/}"; name="${name%%:*}"
      case "$name" in *_*) echo wave-mulled ;; *) echo wave-plain ;; esac ;;
    *) echo other ;;
  esac
}

probe_arch() {  # echo multi-arch|amd64-only|arm64-only|unknown for a docker ref
  ref="$1"
  # bare "biocontainers/x:tag" needs the quay.io host to be pullable
  case "$ref" in biocontainers/*) ref="quay.io/$ref" ;; esac
  raw="$(docker buildx imagetools inspect --raw "$ref" 2>/dev/null)" || { echo unknown; return; }
  if printf '%s' "$raw" | grep -q '"manifests"'; then
    arches="$(printf '%s' "$raw" | "${PY[@]}" -c 'import json,sys
d=json.load(sys.stdin); print(",".join(sorted({m.get("platform",{}).get("architecture","?") for m in d.get("manifests",[]) if m.get("platform",{}).get("os")=="linux"})))' 2>/dev/null)"
    case "$arches" in
      *amd64*arm64*|*arm64*amd64*) echo multi-arch ;;
      *arm64*) echo arm64-only ;;
      *amd64*) echo amd64-only ;;
      *) echo "list:$arches" ;;
    esac
  else
    a="$(docker buildx imagetools inspect "$ref" --format '{{.Image.Architecture}}' 2>/dev/null)"
    echo "${a:-unknown}-only"
  fi
}

for pl in "${pipelines[@]}"; do
  rel="$(curl -s "https://api.github.com/repos/nf-core/$pl/releases/latest" | "${PY[@]}" -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null)"
  [ -z "$rel" ] && { echo "  $pl: no release" >&2; continue; }
  # list module main.nf paths
  mods="$(curl -s "https://api.github.com/repos/nf-core/$pl/git/trees/$rel?recursive=1" \
    | "${PY[@]}" -c 'import json,sys
d=json.load(sys.stdin)
for t in d.get("tree",[]):
    p=t.get("path","")
    if p.startswith("modules/nf-core/") and p.endswith("/main.nf"): print(p)' 2>/dev/null)"
  echo "  $pl@$rel: $(printf '%s' "$mods" | grep -c . ) modules" >&2
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    mod="$(echo "$m" | sed 's#modules/nf-core/##; s#/main.nf##')"
    # the docker ref is the LAST quoted string in the container "..." block (the non-singularity branch)
    ref="$(curl -s "https://raw.githubusercontent.com/nf-core/$pl/$rel/$m" \
      | awk '/container "/{f=1} f{print} /}"/{if(f)exit}' \
      | grep -oE "(quay.io/biocontainers|biocontainers|community.wave.seqera.io/library)/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+" | tail -1)"
    [ -z "$ref" ] && continue
    cls="$(classify_ref "$ref")"
    arch="$(probe_arch "$ref")"
    cls_count["$cls"]=$(( ${cls_count["$cls"]:-0}+1 ))
    arch_count["$arch"]=$(( ${arch_count["$arch"]:-0}+1 ))
    printf "%s\t%s\t%s\t%s\t%s\n" "$pl" "$mod" "$ref" "$cls" "$arch"
  done <<< "$mods"
done

{
  echo ""; echo "=== container class counts ==="
  for k in "${!cls_count[@]}"; do printf "  %-14s %d\n" "$k" "${cls_count[$k]}"; done
  echo "=== arch counts ==="
  for k in "${!arch_count[@]}"; do printf "  %-14s %d\n" "$k" "${arch_count[$k]}"; done
} >&2
