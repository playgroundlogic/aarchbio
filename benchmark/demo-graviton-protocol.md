# Demo benchmark protocol — x86_64 vs arm64 (real EC2, nf-core/taxprofiler)

The authentic head-to-head the project was built to enable: run the
aws-microbiome-demo pipeline on x86 and on Graviton, measure **both** dimensions
(per-stage wall-clock AND dollars), present the real ratio — not a price
projection. Runs in `aws-microbiome-demo`; aarchbio supplies the (verified)
native arm64 containers.

## The claim under test

> For the *same pipeline, same samples, same data*, Graviton vs x86 differs by:
> (1) wall-clock per stage, (2) $/run. The price/hr gap (~19%) is known; the
> performance ratio is **unknown and the point of measuring** — it can amplify or
> erode the price savings, and it's tool-dependent (Kraken2 is memory-bound, the
> least predictable case).

## Fairness controls (only architecture may differ)

1. **Same samples.** Identical `SAMPLE_COUNT` and the *same* HMP accessions (the
   demo takes `HMP_ACCESSIONS[:n]` — deterministic, so both runs use the same
   set). Use SAMPLE_COUNT=5 for the rehearsal-benchmark; optionally a larger N
   later for tighter numbers.
2. **Same instance *spec*, differ only in family.** c7i↔c7g, r7i↔r7g at identical
   vCPU/RAM. NOT c7i.2xlarge vs c7g.4xlarge — that confounds arch with size.
3. **Same region/AZ** (us-east-1) — same RODA locality, same Spot/on-demand board.
4. **Same pipeline version** — both resolve nf-core/taxprofiler 2.0.0 (no `-r`
   drift between runs; pin if needed).
5. **x86 run uses native amd64 containers; arm64 run uses aarchbio native arm64.**
   NEITHER emulates. This measures native-vs-native price/perf, not the
   emulation tax (that's a separate, already-known story).
6. **Warm vs cold:** both runs pull containers fresh per ephemeral instance, so
   container-pull time is included in both equally — fair, though it adds noise;
   note it.

## What to capture (both dimensions, per stage)

From each run's `s3://.../trace.tsv` (fields: task_id, name, status, exit, start,
complete, duration, realtime, cpus, memory, rss, vmem, rchar, wchar):

- **`realtime`** per process (actual compute time) — the performance signal.
- **`duration`** (incl. scheduling/queue) — the wall-clock the user feels.
- **peak `rss`/`vmem`** — memory behavior can differ by arch (esp. Kraken2).
- **exit codes** — confirm every stage actually succeeded natively (a "faster"
  run that silently failed a step is not faster).

Cost: per-stage instance-type × `duration` × on-demand $/hr (resolve live, don't
hardcode), summed. The demo's dashboard already tracks actual dollars — capture
that total too as the real-world figure.

## Procedure

1. **x86 baseline:** run the demo on the *pre-diff-(b)* config (all x86), N=5,
   same accessions. Save `trace.tsv` → `x86.tsv` + dashboard cost total.
2. **arm64:** run on the diff-(b) config (all Graviton, aarchbio containers), N=5,
   same accessions. Save `trace.tsv` → `arm64.tsv` + cost total.
3. **Diff:** per process name, join x86.tsv↔arm64.tsv on `name`, compute
   `realtime` ratio and `duration` ratio; multiply each stage's `duration` by its
   instance $/hr for $/stage; sum.
4. **Present** a per-stage table: process | x86 realtime | arm64 realtime | speed
   ratio | x86 $ | arm64 $ | $ saved. Plus totals.

## Honesty requirements (so the number survives scrutiny)

- **N=5 is a pilot, not a census.** Report it as such; variance on 5 samples is
  real. A larger N tightens it.
- **Report per-stage, not just the total** — the interesting finding is *which*
  stages win/lose on arm64 (expect Kraken2 to be the swing factor).
- **State if any stage was slower on arm64** — keep negative results.
- **The price/hr ratio is fixed (~19%); the runtime ratio is what we measured** —
  don't conflate the two. $/run = price/hr × measured duration.
- One run each is anecdote-grade; if a stage's ratio looks surprising, repeat it.

## Why this run is also the rehearsal

The arm64 leg *is* the diff-(b) rehearsal: it exercises every step native
(light steps on the rebaked AMI, the Kraken2 mull doing real classification, the
ubuntu:20.04 override). Green rehearsal + captured trace = both deliverables from
one spend (~$2-4 for both legs at N=5).
