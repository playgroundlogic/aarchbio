# biocontainers-arm64

Rebuilds [BioContainers](https://biocontainers.pro/) images for ARM64 (aarch64 /
AWS Graviton) and publishes them to a public, no-account-required registry — no
[Wave](https://seqera.io/wave/), no Seqera Platform, no external account.

> **Status:** design / pre-implementation. The architecture is settled (see
> [DESIGN.md](DESIGN.md)); the builder and workflows are not written yet.

## Problem

BioContainers publishes ~10,000 bioinformatics tool containers at
`quay.io/biocontainers/`. Every image is built from a
[bioconda](https://bioconda.github.io/) recipe. As of 2026, essentially all of
them are `linux/amd64` only. Running them on Graviton (ARM64) means QEMU
emulation (slow, fragile) or a commercial service like Wave. The failure mode is
abrupt: every pull dies with `exec format error`.

## The insight that makes this easy

Every BioContainers image is essentially `conda install <pkg>=<version>` in a
base container, and the image carries a label pointing back to its bioconda
recipe:

```
org.opencontainers.image.source=https://github.com/bioconda/bioconda-recipes/tree/master/recipes/fastqc
```

So an ARM64 rebuild is not a port — it's the *same recipe* resolved against
bioconda's `linux-aarch64` channel, which **already exists for ~85% of tools**.
The missing piece is the container publishing step, not the package build.

```
1. Parse the image label → bioconda package + version
2. On a native ARM64 runner: assert a linux-aarch64 conda package exists
3. docker buildx --platform linux/arm64   (native — no emulation)
4. Push to ECR Public under a stable <version>--<build> tag
```

## How it works

```
GitHub Actions (ubuntu-24.04-arm — free native ARM64 runners)
    │
    ├── Rank:     anaconda.org download counts + nf-core module boost
    ├── Drivers:  pre-warm queue (top-N most-used)  +  miss-driven queue
    │
    └── Builder (idempotent):
          parse label → resolve bioconda pkg+version
            → assert linux-aarch64 package exists
            → docker buildx --platform linux/arm64
            → push → tag <version>--<build>
                │
                └── public.ecr.aws/<alias>/<tool>
```

The key choices, in brief (full rationale in [DESIGN.md](DESIGN.md)):

- **Registry — ECR Public.** Anonymous pulls, no rate limits, and pulls stay on
  the AWS backbone for Graviton EC2 consumers. Encouraging Graviton adoption is
  an explicit goal, not just a side effect.
- **Prioritization — bioconda downloads, nf-core boosted.** Build the most-used
  tools first, ranked by anaconda.org download counts, with a boost for anything
  on the critical path of an nf-core pipeline.
- **Build model — one builder, two drivers.** A single idempotent builder, fed
  both by a Pareto pre-warm queue (kills cold-start latency for common tools) and
  a lazy miss-driven queue (covers the long tail).
- **Versioning — `<version>--<build>`.** Pre-warm latest + most-pulled versions;
  lazy-build specific older versions on first request.

## Usage (planned)

Point a Nextflow / nf-core pipeline's registry override at the mirror:

```nextflow
// nextflow.config
docker {
    registry = 'public.ecr.aws/<alias>'
}
```

Or via nf-core's `--registry` parameter.

## The hard 15%

~15% of bioconda packages ship compiled C / Fortran / Rust that needs a native
ARM64 build, not just a conda environment swap. The native ARM64 runner builds
these natively, and bioconda's own `linux-aarch64` CI keeps shrinking the gap.
v1 targets the ~85% clean-swap tools; the compiled tail is tracked separately
and is not a v1 blocker.

## Prior art / alternatives

- **Wave (Seqera):** does this on-demand, but requires an account and routes
  container pulls through an external service.
- **bioconda `linux-aarch64` channel:** the conda packages exist — container
  publishing is the missing piece this project fills.
- **nf-core / Nextflow:** have begun adding `--platform linux/arm64` to their own
  containers but haven't backfilled biocontainers.

## Motivation

Came out of running nf-core/taxprofiler on AWS Graviton3 (c7g/r7g) instances via
[nf-spawn](https://github.com/spore-host/nf-spawn). Every biocontainer failed
with `exec format error`. The fix should be a small bot, not a commercial
service.

## Documentation

- [DESIGN.md](DESIGN.md) — architecture and decision record
- [CHANGELOG.md](CHANGELOG.md) — notable changes ([Keep a Changelog](https://keepachangelog.com/) / [SemVer 2.0](https://semver.org/spec/v2.0.0.html))

## Related

- https://github.com/bioconda/bioconda-recipes
- https://github.com/BioContainers/containers
- https://seqera.io/wave/ (the commercial alternative)
- https://github.com/spore-host/nf-spawn (the executor that surfaced this)

## License

[Apache License 2.0](LICENSE) — Copyright 2026 Scott Friedman.
