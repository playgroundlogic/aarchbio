# aarchbio

**Native arm64 (aarch64) rebuilds of [BioContainers](https://biocontainers.pro/),
for Apple Silicon and AWS Graviton.** Signed, public, no account required.

🌐 **[playgroundlogic.github.io/aarchbio](https://playgroundlogic.github.io/aarchbio/)**
 · 📦 [quay.io/aarchbio](https://quay.io/organization/aarchbio)

```nextflow
// nextflow.config — point any nf-core / Nextflow pipeline here
docker { registry = 'quay.io/aarchbio' }
```

```bash
# or pull directly — anonymous, no login
docker pull quay.io/aarchbio/samtools:1.22.1--h0b41a95_0
```

> **500+ tools live** at [`quay.io/aarchbio`](https://quay.io/organization/aarchbio) —
> each built natively (no emulation), cosign-signed, and tagged to match
> BioContainers' own `<version>--<build>` scheme. The same config runs native on
> a Mac laptop and a Graviton server; Docker picks the right architecture.

## Why this exists

The machines researchers increasingly use are arm64 — every Apple Silicon Mac,
every AWS Graviton instance. The containers they depend on are not: the ~10,000
[BioContainers](https://biocontainers.pro/) images are, as of 2026, essentially
all `linux/amd64`.

The failure is usually invisible. On a Mac, Docker silently emulates the amd64
image under QEMU — it "works," but runs an emulated binary: slower, occasionally
subtly wrong, with no signal anything is off. On a Graviton server with no
emulation layer, the same pull dies outright with `exec format error`. Either way
the researcher pays a tax they can't see — and the only escapes today are slow
emulation or a commercial service.

**The key insight: this is a publishing gap, not a porting problem.** A
BioContainers image is essentially `conda install <pkg>=<version>` in a base
container — and [bioconda](https://bioconda.github.io/) *already* publishes
`linux-aarch64` packages for most tools. So an arm64 image isn't a port; it's the
same recipe resolved against the arm64 channel. The software is ready. Only the
*container* was never rebuilt. aarchbio is the bot that rebuilds it.

We measured the gap rather than guessing (see [`audit/`](audit/)): across a
467-tool sweep of the nf-core ecosystem, **86% built natively for arm64** — yet
across five popular nf-core pipelines, **~100% of the containers they actually
pull are amd64-only.** The capability is there; the publishing hadn't caught up.

## Scope — what aarchbio does and doesn't do

aarchbio operates at **exactly one layer**: it rebuilds **bioconda tool packages
into native arm64 containers**. That focus is deliberate — it's the layer where
the gap is large *and* unowned. The neighboring layers either already handle
arm64 or belong to someone else:

| Layer | Owner | arm64 today | aarchbio? |
|-------|-------|-------------|-----------|
| Distro base images (`ubuntu`, `debian`) | Docker Official | already multi-arch | ❌ out of scope |
| Language / framework packages (`tensorflow`, `numpy`) | **conda-forge** | mostly already arm64 | ❌ out of scope |
| Standalone ML / vendor containers (`tensorflow/tensorflow`, NVIDIA NGC) | the vendors | already multi-arch | ❌ out of scope |
| **Bioinformatics tool containers** (`quay.io/biocontainers/<tool>`) | BioContainers | **amd64-only** ← the gap | ✅ **this** |

So aarchbio is **not** trying to rebuild the whole container universe — just the
bioinformatics-tool slice that nobody else publishes for arm64. When a tool can't
be built, the cause usually lives in a layer aarchbio doesn't own (a conda-forge
dependency without arm64, or an upstream bioconda recipe with arm64 disabled) —
those are surfaced and attributed in [GAPS.md](GAPS.md), to be fixed upstream
where they belong. aarchbio does **not** compile packages from source; that would
make it a second bioconda and break the verifiable-build trust model.

## How it works

```
classify (cheap solve)  →  build native (no emulation)  →  sign  →  publish
   │                          │                              │         │
   bioconda arm64?      amd64 on x86 + arm64 on arm64    cosign    quay.io/
   noarch / arch?       merged into one manifest         keyless   aarchbio
```

- **Native, never emulated.** Each architecture builds on its own native
  hardware; noarch tools (Python/Java) become multi-arch manifests so one tag
  serves Mac *and* Graviton.
- **Verifiable, not just trusted.** Every image is cosign **keyless**-signed in CI
  and logged to the Sigstore transparency log — the signature attests *which
  workflow, which repo, which commit* built it. You don't have to trust the
  publisher; you can verify the build:

  ```bash
  cosign verify quay.io/aarchbio/metaphlan:4.1.1--pyhdfd78af_0 \
    --certificate-identity-regexp 'github.com/playgroundlogic/aarchbio' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```

- **Reproducible.** The build workflow *is* the recipe — re-run it and get the
  same image. Trust the process, not the person.

Architecture and decisions are recorded in [DESIGN.md](DESIGN.md).

## What it costs you to *not* do this

Real, measured — not a complaint, a number. On an Apple M4 Pro, the same tool
emulated (amd64 under QEMU) vs. native arm64:

| Tool | Emulated → Native | Note |
|------|-------------------|------|
| seqkit | **10.9× faster** native | Go binary; QEMU's worst case |
| minimap2 | 1.28× | compiled C aligner |
| samtools | 1.15× | |

It's tool-dependent, not a blanket claim — full method in
[`benchmark/`](benchmark/). On Graviton the cost is starker: the emulated image
often won't start at all.

## The gaps (honest)

Not every tool can be rebuilt for arm64 yet. Of the 467-tool sweep, ~14% are
gaps — and we categorize them rather than hand-wave (see [GAPS.md](GAPS.md)):

- **version-pin** — arm64 exists, just not at the pinned version (bump fixes it).
- **dep-gap** — the tool is arm64-ready but a *dependency* isn't; the fix belongs
  upstream in that dependency's bioconda recipe.
- **never-arm64** — genuinely no arm64 build (the real hard tail, e.g. some
  ML-stack tools awaiting arm64 conda packages).

aarchbio does **not** compile packages from source — that would make it a second
bioconda and undermine the verifiable-build trust model. Gaps are fixed upstream;
aarchbio surfaces and prioritizes them. Missing a tool you need?
[Request it](https://github.com/playgroundlogic/aarchbio/issues/new?template=request-container.yml) —
most just work.

## A gap, not a failing

aarchbio stands on the shoulders of [bioconda](https://bioconda.github.io/),
[BioContainers](https://biocontainers.pro/), [nf-core](https://nf-co.re/), and
[Seqera/Wave](https://seqera.io/wave/) — the mostly-volunteer infrastructure that
makes bioinformatics reproducible at all. arm64 simply hasn't finished catching
up, which is unsurprising given how recently it went mainstream for researchers.
This project fills that one gap and aims to help close it upstream.

[Wave](https://seqera.io/wave/) deserves a specific note, since pipelines
increasingly use it: its on-demand and "mulled" multi-tool images are a genuinely
clever way to assemble exactly the dependencies a step needs — about a third of
the containers we surveyed were Wave-mulled. Those community images are currently
amd64-only too, so arm64 users emulate or fail just the same. That's the same
publishing gap, not a flaw in the approach (aarchbio rebuilds mulled images too).

## Origin

This surfaced running nf-core/taxprofiler on AWS Graviton3 via
[nf-spawn](https://github.com/spore-host/nf-spawn) — every biocontainer died with
`exec format error`. That was just the loud version of a problem most researchers
hit quietly on their Macs every day. The fix should be a small bot, not a
commercial service. So: a small bot.

## More

- [**Website**](https://playgroundlogic.github.io/aarchbio/) — the project site (custom domain `aarch.bio` coming soon)
- [**Catalog**](https://quay.io/organization/aarchbio) — browse all 500+ published images on quay.io
- [DESIGN.md](DESIGN.md) — architecture & decision record
- [GAPS.md](GAPS.md) — what can't be built yet, and why
- [audit/](audit/) — the arm64-readiness survey behind the numbers
- [benchmark/](benchmark/) — the performance methodology & results
- [CHANGELOG.md](CHANGELOG.md) — [Keep a Changelog](https://keepachangelog.com/) / [SemVer 2.0](https://semver.org/spec/v2.0.0.html)

An unofficial community project by **Playground Logic** — not affiliated with or
endorsed by BioContainers, bioconda, nf-core, Seqera, or AWS.
[Apache 2.0](LICENSE) · Copyright 2026 Playground Logic LLC.
