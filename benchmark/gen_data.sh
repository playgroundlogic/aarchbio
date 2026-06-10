#!/usr/bin/env bash
# gen_data.sh — deterministic, seeded test inputs for the benchmark.
#
# No network, no private data: everything is synthesized from a fixed seed so the
# exact bytes are reproducible on any machine. This is what lets a third party
# re-run the benchmark and get comparable numbers.
#
# Outputs (into ./data/):
#   ref.fasta        small synthetic "genome" (reference for bwa/minimap2)
#   reads.fastq      synthetic reads sampled from ref (aligner input)
#   reads.fasta      same reads as FASTA (seqkit input)
#
# Sizes are intentionally modest so the Mac leg runs in minutes, but large enough
# that CPU work dominates container/startup overhead. Scale with SCALE=.
set -euo pipefail

SEED="${SEED:-42}"
SCALE="${SCALE:-1}"          # multiply data size; 1 ≈ a few minutes on M4 Pro
REF_LEN=$(( 2000000 * SCALE ))   # 2 Mb reference per scale unit
N_READS=$(( 400000 * SCALE ))    # 400k reads per scale unit
READ_LEN=150

OUT="$(dirname "$0")/data"
mkdir -p "$OUT"

# Deterministic PRNG (MINSTD Lehmer LCG: x = 16807*x mod 2147483647) implemented
# in awk. Chosen because it uses only multiply/mod that stay exactly within awk's
# double precision — no bitwise ops, so it's portable across BSD/macOS awk and
# gawk alike. Same SEED => same bytes on any machine.
gen_ref() {
  awk -v len="$REF_LEN" -v seed="$SEED" '
  function rng(){ x = (16807*x) % 2147483647; return x; }
  BEGIN{
    b[0]="A"; b[1]="C"; b[2]="G"; b[3]="T";
    x=seed?seed:1;
    printf(">chr_synthetic len=%d seed=%d\n", len, seed);
    line="";
    for(i=0;i<len;i++){
      rng();
      line=line b[ x%4 ];
      if(length(line)==70){print line; line="";}
    }
    if(length(line)) print line;
  }' > "$OUT/ref.fasta"
}

# Reads: sample fixed-length windows from the reference at deterministic offsets,
# with a low, deterministic substitution rate so aligners have real work to do.
gen_reads() {
  awk -v n="$N_READS" -v rl="$READ_LEN" -v seed="$SEED" -v reflen="$REF_LEN" '
  function rng(){ x = (16807*x) % 2147483647; return x; }
  # load reference sequence (skip header) into one string
  NR==1{next}
  {seq=seq $0}
  END{
    bch[0]="A"; bch[1]="C"; bch[2]="G"; bch[3]="T";
    x=seed?seed:1; L=length(seq);
    fq=(MODE=="fastq");
    for(i=0;i<n;i++){
      rng(); start=(x % (L-rl)) + 1;
      r=substr(seq,start,rl);
      # deterministic ~1% substitutions
      out="";
      for(j=1;j<=rl;j++){
        rng();
        c=substr(r,j,1);
        if( (x%100)==0 ){ c=bch[ x%4 ]; }
        out=out c;
      }
      if(fq){
        printf("@read_%d pos=%d\n%s\n+\n%s\n", i, start, out, qual(rl));
      } else {
        printf(">read_%d pos=%d\n%s\n", i, start, out);
      }
    }
  }
  function qual(L,  s,k){ s=""; for(k=0;k<L;k++) s=s "I"; return s; }
  ' MODE="$1" "$OUT/ref.fasta"
}

echo "[gen_data] seed=$SEED scale=$SCALE  ref=${REF_LEN}bp reads=${N_READS}x${READ_LEN}"
gen_ref
echo "[gen_data] ref.fasta done ($(wc -l < "$OUT/ref.fasta") lines)"
gen_reads fastq > "$OUT/reads.fastq"
echo "[gen_data] reads.fastq done"
gen_reads fasta > "$OUT/reads.fasta"
echo "[gen_data] reads.fasta done"

# Record a checksum manifest so reproducers can confirm identical inputs.
( cd "$OUT" && shasum -a 256 ref.fasta reads.fastq reads.fasta > CHECKSUMS.txt )
echo "[gen_data] checksums written to $OUT/CHECKSUMS.txt"
