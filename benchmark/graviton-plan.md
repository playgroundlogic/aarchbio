# Graviton leg — plan (NOT run without explicit sign-off)

> **This leg spends real money** (EC2 instances). Per the project's constraints,
> nothing here is executed until the maintainer explicitly approves a specific
> run. This file is the design + cost estimate to approve against. No instances
> are launched by writing or reviewing this document.

AWS context (read-only, already verified): account `942542972736`, user
`scofri`, region `us-west-2`.

## What this leg proves that the Mac leg can't

The Mac leg shows **speed** (native arm64 vs amd64-under-QEMU on one machine).
The Graviton leg shows the **cost** half of the thesis — *"AWS arm64 is faster
AND cheaper than people assume"* — by running the same workload on comparable
arm64 and amd64 EC2 instances and dividing by on-demand/Spot price.

It also exercises the real spore.host path: launch ephemeral compute (Spawn),
run the workload, auto-terminate — so the benchmark is also a story about the
ecosystem the project belongs to.

## Instance pairing (the honest comparison)

Compare **generation-matched, size-matched** instances that differ only in CPU
architecture, so it's arm-vs-x86, not old-vs-new:

| Role | arm64 (Graviton) | amd64 (x86) | Notes |
|------|------------------|-------------|-------|
| general | `c7g.4xlarge` | `c7i.4xlarge` | same gen (7), same 16 vCPU, compute-optimized |
| (optional) memory | `r7g.4xlarge` | `r7i.4xlarge` | if a tool is memory-bound |

On the arm64 instance: **native arm64 image**. On the amd64 instance: the stock
amd64 biocontainer (no emulation — it's a native x86 host). We are NOT emulating
on Graviton; we're comparing each architecture running its *native* image. (The
QEMU-tax story is the Mac leg's job; the Graviton story is price/performance.)

## Metrics

- **Wall-clock per workload** (same tools, same seeded inputs as the Mac leg —
  identical `gen_data.sh` bytes, confirmed by checksum).
- **$/workload** = wall-clock × instance on-demand $/hr, and again × Spot $/hr.
  Spot is the spore.host default and where the "cheaper than you think" line
  lives.
- **Throughput/$ ratio** arm64 vs amd64 — the headline number.

## Price inputs (fetch read-only at run time, don't hardcode)

```bash
# On-demand (illustrative; resolve live before reporting)
AWS_PROFILE=aws aws pricing get-products --region us-east-1 \
  --service-code AmazonEC2 --filters \
  'Type=TERM_MATCH,Field=instanceType,Value=c7g.4xlarge' \
  'Type=TERM_MATCH,Field=regionCode,Value=us-west-2' ...
# Spot history
AWS_PROFILE=aws aws ec2 describe-spot-price-history --region us-west-2 \
  --instance-types c7g.4xlarge c7i.4xlarge --product-descriptions "Linux/UNIX" \
  --start-time <t> --max-results 10
```

## Cost guardrails for the run itself

- **TTL auto-terminate** on every instance (Spawn does this natively) — no
  forgotten boxes. Hard cap, e.g. 1 hour.
- Smallest instance pair that makes CPU work dominate (4xlarge is plenty).
- Estimated cost of the benchmark itself: **2 instances × ~1 hr × ~$0.5–0.7/hr
  on-demand ≈ $1–2 total** (less on Spot). Confirm live before launch.
- Tear-down verification step: `describe-instances` must show terminated before
  the run is considered done.

## Sign-off checklist (all must be explicit before launch)

- [ ] Maintainer approves spending (~$1–2, confirmed against live prices).
- [ ] Native arm64 images for all four tools exist and are pulled-tested (Mac leg
      done first).
- [ ] TTL/auto-terminate confirmed on the launch path.
- [ ] Region/AZ with Spot capacity confirmed (Lagotto or `describe-spot-price-history`).
- [ ] `gen_data.sh` checksums match the Mac leg's inputs.

## Out of scope here

- Multi-node / MPI scaling (separate study).
- GPU tools.
- Any instance launch performed as a side effect of writing or reviewing this
  plan. Launch is a separate, explicitly-approved action.
