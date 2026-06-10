#!/usr/bin/env bash
# run_mac.sh — Mac leg of the benchmark: amd64-under-QEMU vs native arm64,
# on the same Apple Silicon machine. Speed only (cost comes from the Graviton leg).
#
# Honest-benchmark controls (see METHODOLOGY.md):
#   - identical tool version pinned in both images (only the arch differs)
#   - identical seeded input (run gen_data.sh first)
#   - pinned thread count
#   - 1 warm-up (untimed) + N timed runs; report median + min/max
#   - capture wall-clock per run; record env + image digests into the result file
#
# Does NOT build or push. Runs `docker run` against images that already exist
# locally (arm64: built by builder/build.sh; amd64: pulled from biocontainers).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DATA="$HERE/data"
RESULTS="$HERE/results"
mkdir -p "$RESULTS"

N="${N:-10}"                 # timed runs per (tool,mode)
THREADS="${THREADS:-4}"
ARM_REG="${ARM_REG:-quay.io/playground-logic}"
AMD_REG="${AMD_REG:-quay.io/biocontainers}"

[ -f "$DATA/reads.fastq" ] || { echo "ERROR: run ./gen_data.sh first (no test data)"; exit 1; }
[ -f "$DATA/aln.bam" ]     || { echo "ERROR: aln.bam missing (input prep for samtools)"; exit 1; }

# Tool matrix. Versions are identical across arch; build hashes differ because
# bioconda builds each arch separately. Tags pinned from real registry contents.
#   name | version | arm64_tag | amd64_tag | workload (uses $T, reads /data:ro, writes /work)
TOOLS=(
  "minimap2|2.28|2.28--h0cbc5ad_4|2.28--h577a1d6_4|minimap2 -t \$T -a /data/ref.fasta /data/reads.fastq > /work/out.sam"
  "bwa|0.7.18|0.7.18--h0cbc5ad_2|0.7.18--h577a1d6_2|bash -c 'cp /data/ref.fasta /work/ref.fa && bwa index /work/ref.fa 2>/dev/null && bwa mem -t \$T /work/ref.fa /data/reads.fastq > /work/out.sam 2>/dev/null'"
  "samtools|1.22.1|1.22.1--h0b41a95_0|1.22.1--h96c455f_0|samtools sort -@ \$T -o /work/sorted.bam /data/aln.bam"
  "seqkit|2.11.0|2.11.0--h8865c2f_0|2.11.0--he881be0_0|bash -c 'seqkit stats -j \$T /data/reads.fasta > /work/stats.txt && seqkit grep -j \$T -s -p ACGTACGT /data/reads.fasta > /work/grep.fa'"
)

time_one() {  # platform image cmd  ->  "WALL_SECONDS" or "FAIL"
  local platform="$1" image="$2" cmd="$3" work
  work="$(mktemp -d)"
  local start end rc
  start="$(uv run python -c 'import time;print(time.time())')"
  if docker run --rm --platform "$platform" \
        -v "$DATA":/data:ro -v "$work":/work -e T="$THREADS" \
        "$image" sh -c "$cmd" >/dev/null 2>&1; then rc=0; else rc=1; fi
  end="$(uv run python -c 'import time;print(time.time())')"
  rm -rf "$work"
  [ "$rc" -eq 0 ] && uv run python -c "print(f'{$end-$start:.4f}')" || echo "FAIL"
}

ensure_image() {  # platform image -> 0 if available (pull if needed)
  docker image inspect "$2" >/dev/null 2>&1 && return 0
  docker pull --platform "$1" "$2" >/dev/null 2>&1
}

digest() { docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}local{{end}}' "$1" 2>/dev/null || echo none; }

median() { tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -n | awk '{a[NR]=$1} END{ if(!NR){print "null";exit} print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2 }'; }
mmin()   { tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -n | head -1; }
mmax()   { tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -n | tail -1; }

STAMP="${STAMP:-manual}"
RESULT="$RESULTS/mac_${STAMP}.json"

echo "[run_mac] N=$N threads=$THREADS  arm=$ARM_REG amd=$AMD_REG"
ROWS=()

for spec in "${TOOLS[@]}"; do
  IFS='|' read -r name ver arm_tag amd_tag cmd <<<"$spec"
  for mode in amd64-emulated arm64-native; do
    if [ "$mode" = amd64-emulated ]; then platform=linux/amd64; image="$AMD_REG/$name:$amd_tag"
    else                                   platform=linux/arm64; image="$ARM_REG/$name:$arm_tag"; fi

    if ! ensure_image "$platform" "$image"; then
      echo "[run_mac] SKIP $name/$mode — image unavailable: $image"
      ROWS+=("{\"tool\":\"$name\",\"version\":\"$ver\",\"mode\":\"$mode\",\"image\":\"$image\",\"status\":\"skipped\"}")
      continue
    fi

    echo "[run_mac] warm-up $name/$mode ..."; time_one "$platform" "$image" "$cmd" >/dev/null || true
    samples=""
    for i in $(seq 1 "$N"); do
      r="$(time_one "$platform" "$image" "$cmd")"
      echo "[run_mac]   $name/$mode $i/$N: ${r}s"
      samples="$samples $r"
    done
    med="$(echo "$samples" | median)"; lo="$(echo "$samples" | mmin)"; hi="$(echo "$samples" | mmax)"
    dg="$(digest "$image")"
    ROWS+=("{\"tool\":\"$name\",\"version\":\"$ver\",\"mode\":\"$mode\",\"image\":\"$image\",\"digest\":\"$dg\",\"median_s\":${med:-null},\"min_s\":${lo:-null},\"max_s\":${hi:-null},\"raw\":\"$(echo $samples|xargs)\"}")
  done
done

{
  echo "{"
  echo "  \"leg\": \"mac\", \"stamp\": \"$STAMP\","
  echo "  \"env\": {"
  echo "    \"chip\": \"$(sysctl -n machdep.cpu.brand_string)\", \"cores\": $(sysctl -n hw.ncpu),"
  echo "    \"mem_gb\": $(( $(sysctl -n hw.memsize)/1024/1024/1024 )),"
  echo "    \"os\": \"$(sw_vers -productVersion) ($(sw_vers -buildVersion))\","
  echo "    \"docker\": \"$(docker version --format '{{.Server.Version}}')\","
  echo "    \"threads\": $THREADS, \"runs\": $N"
  echo "  },"
  echo "  \"results\": ["
  for i in "${!ROWS[@]}"; do
    printf "    %s%s\n" "${ROWS[$i]}" "$([ "$i" -lt $((${#ROWS[@]}-1)) ] && echo ,)"
  done
  echo "  ]"
  echo "}"
} > "$RESULT"

echo "[run_mac] wrote $RESULT"
