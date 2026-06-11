# aarchbio

Rebuilds [BioContainers](https://biocontainers.pro/) images for ARM64 (aarch64)
and publishes them to a public, no-account-required registry — no
[Wave](https://seqera.io/wave/), no Seqera Platform, no external account.

> **Status:** design / pre-implementation. The architecture is settled (see
> [DESIGN.md](DESIGN.md)); the builder and workflows are not written yet.

## Problem

**A large and growing share of the machines researchers actually use are arm64,
but the containers they depend on are not.** Apple Silicon (M-series) Macs are
arm64. AWS Graviton and other arm64 servers are arm64. Yet BioContainers — the
~10,000 bioinformatics tool images at `quay.io/biocontainers/`, each built from a
[bioconda](https://bioconda.github.io/) recipe — is, as of 2026, essentially all
`linux/amd64`.

The worst part is that this usually fails *silently*. On an Apple Silicon laptop,
Docker quietly falls back to QEMU emulation: the container "works," but runs an
amd64 binary under emulation — slower, occasionally subtly wrong, and giving no
signal that anything is off. On a server that lacks the emulation shim, the same
pull dies outright with `exec format error`. Either way the researcher pays a tax
they can't see.

## A gap, not a failing

aarchbio stands entirely on the shoulders of
[bioconda](https://bioconda.github.io/), [BioContainers](https://biocontainers.pro/),
[nf-core](https://nf-co.re/), and [Seqera/Wave](https://seqera.io/wave/). These
projects built the infrastructure that makes bioinformatics reproducible at all —
an enormous, mostly-volunteer good. arm64 simply hasn't finished catching up yet,
which is unsurprising given how recently it became mainstream for researchers.
This project just fills that one gap, and ideally helps close it upstream.

We surveyed the gap rather than guessing at it (see [`audit/`](audit/)):

- **~62% of bioinformatics tools could already run natively on arm64** — about a
  third of bioconda packages are `noarch` (Python/Java — architecture-neutral by
  nature), and another third already ship native `linux-aarch64` builds. Only
  ~8% are genuinely arm64-blocked; for the most-used tools it was effectively 0%.
- **Yet across five popular nf-core pipelines, ~100% of the containers they pull
  are still amd64-only.** The packages are ready; the *container publishing* step
  is what hasn't caught up.

A note on [Wave](https://seqera.io/wave/), since pipelines increasingly use it:
Wave's on-demand and "mulled" multi-tool images are a genuinely clever way to
assemble exactly the dependencies a step needs. Today those community images are
built for amd64 — so for arm64 users they currently emulate or fail just like the
classic ones. (About a third of the containers we surveyed were Wave-mulled.)
That's a publishing gap too, not a flaw in the approach.

And the cost of running emulated rather than native is real and measurable — not
a complaint, a number. On an Apple M4 Pro, the same tool emulated (amd64 under
QEMU) vs. native arm64 (this project's rebuild): `seqkit` **10.9× faster**
native; compiled aligners more modest (`minimap2` 1.28×). It's tool-dependent,
not a blanket claim — full method and results in [`benchmark/`](benchmark/), and
the cost is starker on Graviton, where the emulated image often won't start at
all.

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
4. Push to quay.io under a stable <version>--<build> tag
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
            → sign + stamp provenance (source recipe + git SHA)
            → push → tag <version>--<build>
                │
                └── quay.io/aarchbio/<tool>
```

The key choices, in brief (full rationale in [DESIGN.md](DESIGN.md)):

- **Registry — quay.io** (`quay.io/aarchbio`). Free and unlimited for a
  solo publisher, anonymous pulls, no rate limits, and it sits right next to the
  amd64 originals at `quay.io/biocontainers/` — where the community (and Mac
  users) already look. ECR Public is deferred to a possible same-region
  accelerator mirror for Graviton, if pull latency ever justifies it.
- **Prioritization — bioconda downloads, nf-core boosted.** Build the most-used
  tools first, ranked by anaconda.org download counts, with a boost for anything
  on the critical path of an nf-core pipeline.
- **Build model — one builder, two drivers.** A single idempotent builder, fed
  both by a Pareto pre-warm queue (kills cold-start latency for common tools) and
  a lazy miss-driven queue (covers the long tail).
- **Versioning — `<version>--<build>`.** Pre-warm latest + most-pulled versions;
  lazy-build specific older versions on first request.
- **Publisher & trust — Playground Logic, with verifiable provenance.** Published
  by Playground Logic (AWS is infrastructure only — no implied AWS endorsement) as
  an unofficial community rebuild. Every image is signed and stamped with the
  source bioconda recipe + git SHA, so trust rides on a verifiable, reproducible
  build chain rather than on the registry name.

## Usage (planned)

Point a Nextflow / nf-core pipeline's registry override at the mirror. The same
config works on an Apple Silicon laptop and a Graviton server — Docker selects
the arm64 image automatically:

```nextflow
// nextflow.config
docker {
    registry = 'quay.io/aarchbio'
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

- **Wave (Seqera):** solves a broader problem — on-demand, per-step container
  assembly — and does it well; arm64 community images just aren't there yet. A
  great fit if you want a managed service; aarchbio is the no-account, pre-built
  alternative for the arm64 slice.
- **bioconda `linux-aarch64` channel:** the conda packages exist — container
  publishing is the missing piece this project fills.
- **nf-core / Nextflow:** have begun adding `--platform linux/arm64` to their own
  containers but haven't backfilled biocontainers.

## Origin

The sharp edge that surfaced this was running nf-core/taxprofiler on AWS
Graviton3 via [nf-spawn](https://github.com/spore-host/nf-spawn), where every
biocontainer failed with `exec format error`. But that was just the loud version
of a problem most researchers hit quietly on their Macs every day. The fix should
be a small bot, not a commercial service.

## Proving the thesis (benchmark)

The claim "native arm64 is faster, and on Graviton cheaper" is only worth telling
if it's measured. [`benchmark/`](benchmark/) holds a reproducible protocol:

- [METHODOLOGY.md](benchmark/METHODOLOGY.md) — the honest-benchmark protocol
  (same tool/version/input, pinned threads, median of N runs, captured
  environment), written before any numbers exist.
- A **Mac leg** (`run_mac.sh`) comparing amd64-under-QEMU vs native arm64 on
  Apple Silicon — free, reproducible on any M-series machine.
- A **Graviton leg** ([graviton-plan.md](benchmark/graviton-plan.md)) for the
  speed *and cost* story on EC2 — design only; it spends real money and runs only
  with explicit sign-off.

Tools span the emulation-sensitivity range (`bwa`, `minimap2`, `samtools`,
`seqkit`) so the result is honest about where the benefit is large and where it's
modest. No results collected yet.

## Documentation

- [DESIGN.md](DESIGN.md) — architecture and decision record
- [CHANGELOG.md](CHANGELOG.md) — notable changes ([Keep a Changelog](https://keepachangelog.com/) / [SemVer 2.0](https://semver.org/spec/v2.0.0.html))

## Related

- https://github.com/bioconda/bioconda-recipes
- https://github.com/BioContainers/containers
- https://seqera.io/wave/ (Seqera Wave — the managed, on-demand approach)
- https://github.com/spore-host/nf-spawn (the executor that surfaced this)

## License

[Apache License 2.0](LICENSE) — Copyright 2026 Playground Logic LLC.
