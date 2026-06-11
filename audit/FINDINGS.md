# Audit findings — how arm64-broken the bioinformatics container ecosystem is

Two surveys, run 2026-06-10/11. Scripts: `audit.sh` (package-level),
`container_audit.sh` (container-level). Raw data: `*.tsv` / `*.summary`.

## The headline

> **~62% of bioinformatics tools *could* run natively on arm64 today — but ~0%
> of the containers that real pipelines actually pull *do*.**

The conda packages are ready. The containers are the problem. That gap is the
entire reason aarchbio exists.

## Package audit — 874 nf-core-ecosystem tools (`package-audit-nfcore.tsv`)

Per tool, does an arm64 bioconda package exist (anaconda.org API)?

| Bucket | Count | % |
|--------|------:|--:|
| `noarch` (Python/Java — runs anywhere) | 289 | 33% |
| `linux-aarch64` (native arm64 build) | 262 | 29% |
| `linux-64-only` (genuinely arm64-blocked — the "hard" tools) | 72 | **8%** |
| `missing` (mostly nf-core-name ≠ bioconda-package-name) | 251 | 28% |
| **arm64-capable (noarch + linux-aarch64)** | **551** | **63%** |

- The genuinely hard, arm64-blocked tools are **~8%**, not the ~15% folklore — and
  that's of the *whole* ecosystem; for the popular head it was **0%** (see the
  24-tool pilot, `pilot-24.tsv`, 100% arm64-capable).
- The 28% "missing" is mostly a name-mapping artifact (nf-core module names vs
  bioconda package names), so true coverage is **higher** than 63%.

## Container audit — 5 popular pipelines (`container-audit.tsv`)

What containers do taxprofiler, sarek, rnaseq, mag, viralrecon actually pull?
374 container references across 379 modules.

| Container class | Count | % |
|-----------------|------:|--:|
| `biocontainers` (quay.io legacy) | 182 | 49% |
| **`wave-mulled`** (Seqera Wave, multi-tool fused) | **117** | **31%** |
| `wave-plain` (Seqera Wave, single tool) | 75 | 20% |
| **arch = amd64-only** | **374** | **100%** |

**Every single container probed is amd64-only.** Zero multi-arch, zero arm64.

### Mulling is a pattern, not a one-off

**33 distinct mulled images** across just these 5 pipelines — every one
amd64-only. The ecosystem's move to Seqera Wave *worsened* arm64: Wave bakes
multiple tools into bespoke single-arch images with content-hash tags, e.g.:

- `bowtie2_htslib_samtools_pigz` (4 tools fused)
- `coreutils_grep_gzip_lbzip2_pruned` (5 utilities fused)
- `kraken2_coreutils_pigz`, `gatk4_gcnvkernel_htslib_samtools`,
  `pangolin-data_pangolin_pip_snakemake`, `htslib_samtools_star_gawk` …

A plain biocontainers `multiqc` is `noarch` (runs anywhere); the equivalent Wave
image is a baked amd64 artifact. "Optimizing" by pre-fusing tools compiled the
arch-neutrality *away*.

## Why this matters

- **On Apple Silicon:** these amd64 containers silently emulate (slow, sometimes
  subtly wrong) — millions of Mac researchers, every day.
- **On Graviton:** a vanilla instance has no emulation layer, so they
  `exec format error` — arch-neutral code locked *out* of an architecture by
  packaging alone.

The fix isn't porting software (62%+ already have arm64 packages). It's rebuilding
the containers — which is what aarchbio does, including the mulled case
(`EXTRA_PACKAGES`).

## Caveats / honesty

- Package audit keys on nf-core module names; ~28% "missing" are largely name
  mismatches, not truly absent packages — so arm64 coverage is *understated*.
- Container `arch` for biocontainers refs reflects the published *image*; many
  wrap `noarch` packages yet ship amd64-only images — itself the core finding.
- 5 pipelines is a sample, not the census; the pattern was 100% consistent across
  all 5, but a wider sweep would firm up the exact percentages.
