#!/usr/bin/env bash
# run_mac.sh — Mac leg of the benchmark: amd64-under-QEMU vs native arm64,
# on the same Apple Silicon machine. Speed only (cost comes from the Graviton leg).
#
# Honest-benchmark controls (see METHODOLOGY.md):
#   - identical tool version pinned in both images
#   - identical seeded input (run gen_data.sh first)
#   - pinned thread count
#   - 1 warm-up (untimed) + N timed runs; report median + min/max
#   - capture wall-clock AND max-RSS per run
#   - record full environment + image digests into the result file
#
# This script DOES NOT build images and DOES NOT push anything. It only runs
# `docker run` against images that already exist. If the native arm64 image
# doesn't exist yet, that row is skipped and noted (the project is pre-impl).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$HERE/data"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"

N="${N:-10}"                 # timed runs per (tool,mode)
THREADS="${THREADS:-4}"
AMD_REGISTRY="${AMD_REGISTRY:-quay.io/biocontainers}"
ARM_REGISTRY="${ARM_REGISTRY:-quay.io/playground-logic}"

# Tool matrix: name | image repo:tag | command template (uses $T threads, /data mount)
# NOTE: image tags are illustrative; real tags resolve via the builder. Pinned on purpose.
read -r -d '' TOOLS <<'EOF' || true
bwa|bwa:0.7.18--he4a0461_1|bash -c "bwa index /data/ref.fasta && bwa mem -t $T /data/ref.fasta /data/reads.fastq > /dev/null"
minimap2|minimap2:2.28--he4a0461_0|bash -c "minimap2 -t $T -a /data/ref.fasta /data/reads.fastq > /dev/null"
samtools|samtools:1.21--h50ea8bc_0|bash -c "minimap2 -t $T -a /data/ref.fasta /data/reads.fastq 2>/dev/null | samtools sort -@ $T -o /dev/null -"
seqkit|seqkit:2.8.2--h9ee0642_0|bash -c "seqkit stats -j $T /data/reads.fasta && seqkit grep -j $T -s -p ACGTACGT /data/reads.fasta > /dev/null"
EOF
# (samtools row pipes from minimap2 inside the same image only if present; otherwise
#  adjust to a pre-generated BAM. Kept simple here; refine when images exist.)

[ -f "$DATA/reads.fastq" ] || { echo "ERROR: run ./gen_data.sh first (no test data)"; exit 1; }

ts() { python3 -c 'import time;print(f"{time.time():.6f}")'; }

# Run one container once; echo "WALL_SECONDS MAX_RSS_KB" or "FAIL".
time_one() {
  local platform="$1" image="$2" cmd="$3"
  # /usr/bin/time -l prints max RSS (bytes on macOS) to stderr; we parse it.
  local out rc
  out="$( { /usr/bin/time -l docker run --rm --platform "$platform" \
            -v "$DATA":/data:ro -e T="$THREADS" "$image" $cmd ; } 2>&1 )" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then echo "FAIL"; return; fi
  local real rss
  real="$(printf '%s\n' "$out" | awk '/ real /{print $1}' | tail -1)"
  rss="$(printf '%s\n' "$out"  | awk '/maximum resident set size/{print $1}' | tail -1)"
  echo "${real:-NA} ${rss:-NA}"
}

image_digest() {
  docker image inspect --format '{{index .RepoDigests 0}}' "$1" 2>/dev/null || echo "none"
}

# Median of space-separated numbers (ignores NA/FAIL).
median() {
  tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -n | awk '{a[NR]=$1} END{
    if(NR==0){print "NA"; exit}
    if(NR%2){print a[(NR+1)/2]} else {printf "%.4f\n",(a[NR/2]+a[NR/2+1])/2}
  }'
}
minmax() { tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -n | awk 'NR==1{mn=$1}{mx=$1}END{print mn" "mx}'; }

STAMP="${STAMP:-manual}"   # pass STAMP=<iso-time> from caller; Date is intentionally external
RESULT="$RESULTS/mac_${STAMP}.json"

echo "[run_mac] N=$N threads=$THREADS  amd=$AMD_REGISTRY arm=$ARM_REGISTRY"
{
  echo "{"
  echo "  \"leg\": \"mac\","
  echo "  \"stamp\": \"$STAMP\","
  echo "  \"env\": {"
  echo "    \"chip\": \"$(sysctl -n machdep.cpu.brand_string)\","
  echo "    \"cores\": $(sysctl -n hw.ncpu),"
  echo "    \"mem_gb\": $(( $(sysctl -n hw.memsize)/1024/1024/1024 )),"
  echo "    \"os\": \"$(sw_vers -productVersion) ($(sw_vers -buildVersion))\","
  echo "    \"docker\": \"$(docker version --format '{{.Server.Version}}')\","
  echo "    \"threads\": $THREADS, \"runs\": $N"
  echo "  },"
  echo "  \"results\": ["
}  > "$RESULT"

first=1
printf '%s\n' "$TOOLS" | while IFS='|' read -r name imgtag cmd; do
  [ -z "$name" ] && continue
  amd_img="$AMD_REGISTRY/$imgtag"
  arm_img="$ARM_REGISTRY/$imgtag"
  for mode in amd64-emulated arm64-native; do
    if [ "$mode" = amd64-emulated ]; then platform=linux/amd64; image="$amd_img"; else platform=linux/arm64; image="$arm_img"; fi

    if ! docker image inspect "$image" >/dev/null 2>&1; then
      if ! docker pull --platform "$platform" "$image" >/dev/null 2>&1; then
        echo "[run_mac] SKIP $name/$mode — image not available: $image"
        skipped=1
      fi
    fi

    digest="$(image_digest "$image")"
    if [ "${skipped:-0}" = 1 ]; then
      samples=""; unset skipped
    else
      echo "[run_mac] warm-up $name/$mode ..."; time_one "$platform" "$image" "$cmd" >/dev/null || true
      samples=""
      for i in $(seq 1 "$N"); do
        r="$(time_one "$platform" "$image" "$cmd")"
        w="${r%% *}"; echo "[run_mac]   $name/$mode run $i: ${w}s"
        samples="$samples ${w}"
      done
    fi
    med="$(echo "$samples" | median)"; mm="$(echo "$samples" | minmax)"
    [ "$first" = 1 ] || echo "," >> "$RESULT"; first=0
    {
      printf '    {"tool":"%s","mode":"%s","image":"%s","digest":"%s",' "$name" "$mode" "$image" "$digest"
      printf '"median_s":%s,"min_s":%s,"max_s":%s,"raw":"%s"}' \
        "${med:-null}" "$(echo "$mm" | awk '{print ($1==""?"null":$1)}')" \
        "$(echo "$mm" | awk '{print ($2==""?"null":$2)}')" "$(echo "$samples" | xargs)"
    } >> "$RESULT"
  done
done

echo "" >> "$RESULT"
echo "  ]" >> "$RESULT"
echo "}" >> "$RESULT"
echo "[run_mac] wrote $RESULT"
echo "[run_mac] NOTE: speedup = amd64-emulated.median_s / arm64-native.median_s (computed at report time)"
