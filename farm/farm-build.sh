#!/usr/bin/env bash
# farm-build.sh — bulk-build aarchbio containers on the native local farm, NO
# emulation: amd64 on janus (x86_64), arm64 on orion (Apple M-series), merge.
#
# Driven from this Mac over SSH. Builds + pushes TAGGED images (unsigned/private);
# a separate CI 'sign-existing' pass then keyless-signs + publishes them (D6 — the
# farm has no OIDC, so signing stays in CI for truthful provenance).
#
# Per tool: classify (local) -> noarch => amd64@janus + arm64@orion + merge;
#           arch-specific    => arm64@orion only. Resumable via a state file.
#
# Usage:  ./farm-build.sh <worklist>
#   worklist: one spec per line, "tool=version" or mulled "tool=ver+extra=ver+..."
#   (lines starting with # ignored; blank lines ignored)
#
# Env: AMD_HOST (default janus.local), ARM_HOST (default orion.local),
#      REGISTRY (default quay.io/aarchbio), STATE (default farm/state.tsv).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
AMD_HOST="${AMD_HOST:-janus.local}"
ARM_HOST="${ARM_HOST:-orion.local}"
REGISTRY="${REGISTRY:-quay.io/aarchbio}"
STATE="${STATE:-$HERE/state.tsv}"
WORKLIST="${1:?usage: farm-build.sh <worklist>}"

if command -v uv >/dev/null 2>&1; then PY=(uv run python); else PY=(python3); fi
mkdir -p "$(dirname "$STATE")"; touch "$STATE"

# Remote shells differ: orion=zsh login, janus=bash login. Wrap commands so PATH
# (brew, docker) is loaded.
# `</dev/null` so ssh never consumes the while-read loop's stdin (classic bug).
arm_sh() { ssh "$ARM_HOST" "zsh -lc '$1'" </dev/null; }
amd_sh() { ssh "$AMD_HOST" "bash -lc '$1'" </dev/null; }

# Ship the builder/ dir to a box's /tmp/aarchbio-builder. Uses tar-over-ssh (not
# rsync — janus/Linux has no rsync) so it's portable; repo is private so we don't
# git-clone on the boxes.
sync_builder() {
  local host="$1"
  ssh "$host" 'rm -rf /tmp/aarchbio-builder && mkdir -p /tmp/aarchbio-builder' </dev/null
  tar --no-xattrs -C "$REPO/builder" -cf - . 2>/dev/null | ssh "$host" 'tar -C /tmp/aarchbio-builder -xf - 2>/dev/null'
}

log() { printf '[farm] %s\n' "$*"; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$STATE"; }   # spec  status  detail
already_ok() { grep -qF "$(printf '%s\tok\t' "$1")" "$STATE" 2>/dev/null; }

# Build ONE platform on a box and return the pushed digest on stdout. Retries
# once if the digest comes back empty (guards against a flaky ssh stream).
# args: host_fn platform pkg ver extra
build_arch_remote() {
  local hostfn="$1" platform="$2" pkg="$3" ver="$4" extra="$5" dg="" attempt
  for attempt in 1 2; do
    dg="$($hostfn "cd /tmp/aarchbio-builder && PLATFORM='$platform' REGISTRY='$REGISTRY' EXTRA_PACKAGES='$extra' ./build-arch.sh '$pkg' '$ver'" 2>/dev/null \
         | sed -n 's/^arch_digest=//p' | tail -1)"
    [ -n "$dg" ] && break
  done
  printf '%s' "$dg"
}

log "farm: amd=$AMD_HOST arm=$ARM_HOST registry=$REGISTRY"
log "syncing builder/ to both boxes ..."
sync_builder "$ARM_HOST"; sync_builder "$AMD_HOST"

while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"   # strip comments/space
  [ -z "$line" ] && continue
  primary="${line%%+*}"; pkg="${primary%%=*}"; ver="${primary#*=}"
  extra=""; [ "$line" != "$primary" ] && extra="$(echo "${line#*+}" | tr '+' ' ')"

  if already_ok "$line"; then log "skip (done): $line"; continue; fi
  log "=== $pkg=$ver ${extra:+(+$extra)} ==="

  # classify locally (cheap solve)
  cout="$(mktemp)"
  if ! GITHUB_OUTPUT="$cout" "$REPO/builder/classify.sh" "$pkg" "$ver" >/dev/null 2>&1; then
    log "  classify FAILED (no arm64 solution) -> gap"; record "$line" gap "no arm64 solution"; continue
  fi
  tag="$(grep '^tag=' "$cout" | head -1 | cut -d= -f2-)"
  noarch="$(grep '^noarch=' "$cout" | head -1 | cut -d= -f2-)"
  image="$REGISTRY/$pkg:$tag"

  if [ "$noarch" = "1" ]; then
    log "  noarch -> native multi-arch (amd64@$AMD_HOST + arm64@$ARM_HOST)"
    # Build each leg sequentially (reliability over speed for bulk runs; the
    # parallel-subshell digest capture was race-prone).
    da="$(build_arch_remote amd_sh linux/amd64 "$pkg" "$ver" "$extra")"
    dr="$(build_arch_remote arm_sh linux/arm64 "$pkg" "$ver" "$extra")"
    if [ -z "$da" ] || [ -z "$dr" ]; then
      log "  build FAILED (amd='$da' arm='$dr')"; record "$line" fail "build-leg empty digest"; continue
    fi
    # merge on this Mac (has buildx + auth). Retry: the merge is a remote
    # registry op that can transiently fail under farm load; the operation
    # itself is sound, so retry before giving up. Last error kept for the log.
    merr=""; ok=0
    for attempt in 1 2 3; do
      if merr="$(REGISTRY="$REGISTRY" "$REPO/builder/merge.sh" "$pkg" "$tag" "$da" "$dr" 2>&1)"; then ok=1; break; fi
      sleep 5
    done
    if [ "$ok" = 1 ]; then
      log "  published $image (multi-arch)"; record "$line" ok "$image multi-arch"
    else
      log "  merge FAILED: $(printf '%s' "$merr" | tail -1)"; record "$line" fail "merge"; continue
    fi
  else
    log "  arch-specific -> arm64-only @$ARM_HOST"
    dr="$(build_arch_remote arm_sh linux/arm64 "$pkg" "$ver" "$extra")"
    if [ -z "$dr" ]; then log "  build FAILED"; record "$line" fail "arm64 build empty digest"; continue; fi
    # tag the pushed-by-digest image to its real tag via imagetools (retry too)
    terr=""; ok=0
    for attempt in 1 2 3; do
      if terr="$(docker buildx imagetools create --tag "$image" "$REGISTRY/$pkg@$dr" 2>&1)"; then ok=1; break; fi
      sleep 5
    done
    if [ "$ok" = 1 ]; then
      log "  published $image (arm64)"; record "$line" ok "$image arm64"
    else
      log "  tag FAILED: $(printf '%s' "$terr" | tail -1)"; record "$line" fail "imagetools tag"; continue
    fi
  fi
done < "$WORKLIST"

log "done. summary:"
awk -F'\t' '{c[$2]++} END{for(k in c) printf "  %-6s %d\n", k, c[k]}' "$STATE"
log "state: $STATE"
log "next: sign+publish the 'ok' tags via the CI sign-existing workflow."
