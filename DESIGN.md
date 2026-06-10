# Design

This document records the architecture and the decisions behind it. It is the
authoritative design reference; the [README](README.md) is the elevator pitch.

## Goal

Make ARM64 (aarch64 / AWS Graviton) builds of [BioContainers](https://biocontainers.pro/)
images available from a public, no-account-required registry, so that Nextflow /
nf-core pipelines run natively on Graviton instead of under QEMU emulation.

Secondary, explicit goal: **encourage Graviton adoption.** When the ARM64 images
are also the ones that pull fastest and cheapest on AWS, the path of least
resistance points at Graviton.

## Core insight

Every BioContainers image is, in essence, `conda install <pkg>=<version>` inside
a base container, and the image carries a label identifying the bioconda recipe
it was built from:

```
org.opencontainers.image.source=https://github.com/bioconda/bioconda-recipes/tree/master/recipes/<pkg>
```

Bioconda already publishes `linux-aarch64` conda packages for the large majority
of tools (~85% as of 2026). So for most images the ARM64 rebuild is not a port —
it is the *same recipe* resolved against the ARM64 conda channel. The missing
piece is the container publishing step, not the package build.

## Decisions

### D1 — Registry: ECR Public

**Decision:** publish to `public.ecr.aws/<alias>/` (ECR Public).

**Why:**
- Anonymous pulls, no login, no Docker Hub-style rate limits.
- Consumers are Graviton EC2 instances; pulls from ECR Public stay on the AWS
  backbone — fast and low-cost to the instance. This directly serves the
  Graviton-adoption goal.
- The bot runs inside AWS internally, so ECR Public is the natural home and the
  stakeholder story ("AWS-hosted ARM images for the bioinformatics community")
  is coherent.

**Caveat to confirm before scale-out:** ECR Public has per-account storage and
bandwidth free-tier limits. Layer dedup (a shared conda base across all images)
keeps real storage far below `N images × full size`, but the quota should be
checked before we mirror the long tail.

**Not chosen:** quay.io as primary. It is also anonymous, but it's where the
amd64-only originals already live, the org has had throttling pain, and it adds
nothing toward the Graviton story. Mirroring to quay later is possible but is
explicitly out of scope for v1.

### D2 — Prioritization axis: bioconda download counts, nf-core boosted

**Decision:** rank what to build by **bioconda package download count** (via the
anaconda.org API), then hand-boost any tool that appears in the nf-core module
set.

**Why:**
- Download count is the cleanest usage signal and uses the *same identity the
  whole bot is built on* — the bioconda package. anaconda.org exposes per-package
  totals (`https://api.anaconda.org/package/bioconda/<pkg>`).
- quay.io per-tag pull counts are not reliably public, so they're not a usable
  ranking source.
- The nf-core boost matters because a tool can have modest overall downloads yet
  sit on the critical path of a popular pipeline. Pipeline users on Graviton are
  exactly the population hitting `exec format error` today.

### D3 — Build model: one builder, two drivers (pre-warm + lazy)

**Decision:** build the idempotent **on-demand builder first**, then drive it two
ways rather than writing two systems.

- **Builder (core):** parse label → resolve bioconda pkg+version → check an
  `linux-aarch64` conda package exists → `docker buildx --platform linux/arm64`
  (native on an ARM64 runner, no emulation) → push → tag. Idempotent: a no-op if
  the target tag already exists and is current.
- **Pre-warm driver:** feed the top-N bioconda-by-downloads list (D2) into the
  builder ahead of demand. This is a warm-up loop over the same builder, not
  separate code. Kills the cold-start latency for the bulk of real pulls.
- **Miss-driven driver:** when something requests an image we don't have, enqueue
  a build. ECR Public has no native "pull-through that triggers a build," so the
  miss signal needs a thin mechanism — see [Open questions](#open-questions).

**Why builder-first:** the builder has to be correct and idempotent regardless;
making it the foundation means Pareto pre-warming and lazy fill are just two
queues into one engine. Lazy-only would leave a bad cold-start UX; Pareto-only
would never cover the long tail.

### D4 — Versioning policy

**Decision:**
- **Pre-warm** the *latest* version (and the most-pulled recent versions) of each
  top-N tool.
- **Lazy-build** any older/specific version on first request.
- Mirror BioContainers' own tag scheme: `<version>--<build>`.

**Why:** pipelines pin specific versions, so we can't publish only `latest`. But
eagerly mirroring every historical tag of every tool would blow up ECR storage.
Pre-warm the head, let the long tail of old versions arrive on demand.

## Architecture

```
GitHub Actions (ubuntu-24.04-arm — free native ARM64 runners)
    │
    ├── Rank:     anaconda.org download counts + nf-core module boost   (D2)
    ├── Drivers:  pre-warm queue (top-N)  +  miss-driven queue          (D3)
    │
    └── Builder (idempotent):                                            (D3)
          parse label → resolve bioconda pkg+version
            → assert linux-aarch64 conda package exists
            → docker buildx --platform linux/arm64   (native, no QEMU)
            → push → tag <version>--<build>                              (D4)
                │
                └── public.ecr.aws/<alias>/<tool>                        (D1)
```

Consumers point a Nextflow registry override at it:

```nextflow
// nextflow.config
docker {
    registry = 'public.ecr.aws/<alias>'
}
```

## The hard 15%

~15% of bioconda packages have compiled C / Fortran / Rust that needs a native
ARM64 build, not just a conda environment swap. Two things make this tractable:

1. The native ARM64 GitHub Actions runner builds them natively (no emulation).
2. Bioconda's own `linux-aarch64` CI keeps closing the gap, so the conda package
   often already exists and we're back to the D3 builder path.

v1 targets the ~85% that are a clean conda swap. The compiled tail is tracked
separately and is not a v1 blocker.

## Open questions

- **OQ1 — miss-driven trigger (D3):** ECR Public can't trigger a build on a pull
  miss. Options: a thin pull-proxy that enqueues on 404; an issue/PR-based
  request form; or a periodic reconciler that diffs "requested" vs "published."
  Undecided.
- **OQ2 — ECR Public quota (D1):** confirm storage/bandwidth free-tier headroom
  against the projected long-tail image count before scaling past the pre-warm
  set.
- **OQ3 — provenance:** should rebuilt images carry a label asserting "rebuilt
  for arm64 from bioconda recipe X at <sha>" for traceability back to the source?
- **OQ4 — base image parity:** confirm the ARM64 base container matches the
  amd64 BioContainers base closely enough that only the architecture differs.

## Non-goals (v1)

- Mirroring to quay.io or any registry other than ECR Public.
- Rebuilding tools whose bioconda recipe has no `linux-aarch64` package and no
  feasible native build.
- Replacing Wave / Seqera for on-the-fly, arbitrary-image builds. This is a
  publish-ahead-of-need mirror, not a general build service.
