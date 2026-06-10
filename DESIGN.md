# Design

This document records the architecture and the decisions behind it. It is the
authoritative design reference; the [README](README.md) is the elevator pitch.

## Goal

Make ARM64 (aarch64) builds of [BioContainers](https://biocontainers.pro/)
images available from a public, no-account-required registry, so that Nextflow /
nf-core pipelines run natively on arm64 instead of under QEMU emulation.

There are **two arm64 audiences**, and they hit the identical failure today:

- **AWS Graviton servers** (c7g/r7g, etc.) — the original motivating case via
  nf-spawn.
- **Apple Silicon Macs** (M-series) — every bioinformatician running Docker
  Desktop on an M1/M2/M3/M4 laptop. Pulling an amd64-only biocontainer either
  fails with `exec format error` or silently runs under slow QEMU emulation.

Serving both widens the user base materially and reinforces the registry choice
(D1): Mac users are not browsing the AWS ECR gallery — they look where the
bioinformatics community already looks.

Secondary goal: **encourage Graviton adoption.** Native arm64 images remove the
friction that pushes people back to x86, on both the server and laptop side.

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

### D1 — Registry: quay.io (canonical)

**Decision:** publish to **`quay.io/aarchbio/`** as the single canonical
registry. (ECR Public is deferred to a possible accelerator mirror — see D7.)

**Why:**
- **Free and unlimited.** quay.io public repositories cost the publisher nothing;
  Red Hat bears the storage and bandwidth. For a **single-person company**
  (Playground Logic) this removes an open-ended personal bill — there is no
  storage-tail or egress-overage exposure as there is on ECR Public.
- **Discoverability.** BioContainers' own amd64 images already live at
  `quay.io/biocontainers/`. The arm64 rebuild sitting next door, on the same
  registry the bioinformatics community already uses, is far more discoverable
  than an AWS gallery — especially to the Apple Silicon audience, who have no
  reason to ever open the ECR gallery.
- **Anonymous, no login, no Docker Hub-style rate limits** — same as ECR on this
  axis; never a differentiator between them.

**Why not ECR Public as canonical (it was the original choice — superseded):**
ECR rested on three pillars; two collapsed once D5 made Playground Logic (not
AWS) the publisher:
1. *Same-region Graviton pull speed* — still real, but a measurable optimization,
   not a v1 necessity. Captured as D7.
2. *"AWS-hosted is a coherent stakeholder story"* — **retired by D5.** With
   Playground Logic as publisher and AWS as mere infrastructure, there is no
   AWS-endorsement story to be coherent about.
3. *Anonymous / no rate limits* — quay matches this; not a differentiator.
   On top of that, ECR Public puts a metered bill (storage + internet egress
   beyond the free tier) on a solo founder's account, which quay does not.

**Future:** if pull latency is ever measured to hurt nf-spawn job startup on
Graviton, add ECR Public as a same-region accelerator mirror (D7) — a data-driven
optimization, not a guess, and a reversible one (adding a second push target is a
one-step builder change; un-pinning a registry users depend on is not).

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
  a build. A public registry has no native "pull-through that triggers a build,"
  so the miss signal needs a thin mechanism — see [Open questions](#open-questions).

**Why builder-first:** the builder has to be correct and idempotent regardless;
making it the foundation means Pareto pre-warming and lazy fill are just two
queues into one engine. Lazy-only would leave a bad cold-start UX; Pareto-only
would never cover the long tail.

### D5 — Publisher of record and trust model

**Decision:** **Playground Logic** is the publisher of record, under the
namespace `quay.io/aarchbio/` (D1). AWS is infrastructure only
(Graviton/ARM64 for compute) — not the publisher, and nothing about the project
implies AWS endorsement. Trust is established in two layers:

1. **Identity** — the Playground Logic-branded namespace, with a clear
   "unofficial community rebuild of BioContainers" statement. This answers
   *who stands behind these images*.
2. **Integrity** — every image carries provenance and is independently
   verifiable. This answers *can I prove this image is a faithful arm64 rebuild
   of the bioconda recipe it claims, and not tampered with*. See D6.

**Why Playground Logic and not other options:**
- It's a name we own, so it sidesteps any naming-policy or trademark problem —
  we do **not** borrow `biocontainers`/`bioconda`/`aws`, which are other parties'
  names. (This also satisfies ECR Public's custom-alias policy, relevant only if
  D7's accelerator mirror is ever stood up.)
- A company is durable. A public registry that consumers pin in
  `nextflow.config` must persist; an ephemeral sandbox account cannot be the
  publisher of record.
- It's honestly attributed: `quay.io/aarchbio/<tool>` claims a Playground
  Logic rebuild — true, and it impersonates neither BioContainers nor AWS.

### D6 — Provenance and attestation (v1 requirement)

**Decision:** trust is carried by verifiable build provenance, not by the alias
looking legitimate. The following are **v1 requirements, not nice-to-haves:**

- **Provenance labels** — every image is stamped with the source bioconda recipe
  and the exact git SHA it was built from, so any tag traces back to its source.
- **Build attestation / signing** — images are signed (e.g. cosign) and/or carry
  SLSA provenance proving they were produced by this public build pipeline from
  that source, not hand-uploaded. This is what lets someone trust the *registry*
  without having to trust *us* personally — they trust the verifiable build
  chain.
- **Public, reproducible build** — the GitHub Actions workflow *is* the recipe;
  anyone can re-run it and reproduce the image. Trust the process, not the
  person.

**Why a requirement:** the entire value of the project depends on strangers
trusting images enough to run them in their pipelines. A nicer-looking namespace
borrows trust; verifiable provenance *earns* it. Promoting this from the former
open question OQ3 to a first-class requirement reflects that the namespace is the
weakest trust lever and attestation is the strongest.

**Signing model (decided): keyless from CI.** Images are signed with cosign
**keyless** (Sigstore: OIDC identity → Fulcio cert → Rekor transparency log)
inside the GitHub Actions builder, where the ambient OIDC token makes it
non-interactive. Rejected: key-based signing from local/orion builds — it would
work headless today, but it adds a private key to guard and has no transparency
log, and keyless-from-CI is the stronger end state. We do **not** do an interim
key-based phase.

**Consequence — publishing is gated on signing.** Because signing happens in CI
and not in the current manual/SSH build, the first 4 images pushed to
`quay.io/aarchbio` are **unsigned and must stay PRIVATE**. No repo goes public
until it is built+signed by the CI pipeline. This couples "go public" to "CI
builder exists" (D3): **build CI → keyless-sign there → then flip public.** The 4
private unsigned images are the *correct* state until then, not a loose end.

### D6a — Quay publishing mechanics (no "default public" setting)

Quay's free/community tier has **no org setting to make new repositories public
by default**, and a push creates the repo **private**. So "public-on-upload" must
be done explicitly by the builder after each push, via the quay REST API
(`POST /api/v1/repository/{ns}/{repo}/changevisibility {"visibility":"public"}`).

That API does **not** accept the registry **robot token** (returns 403/CSRF —
robot tokens are for `docker push/pull`, not management). It needs a separate
**OAuth application token** (`repo:admin` scope). Therefore the CI builder carries
**two quay credentials**:
- **robot token** (`aarchbio+robot`) — for `docker push`,
- **OAuth app token** — for `changevisibility` (and any repo admin).

Per-tool CI flow becomes: **build → push (robot) → keyless-sign (D6) → set-public
(OAuth)**.

### D7 — ECR Public deferred to optional accelerator mirror

**Decision:** ECR Public is **not** part of v1. quay.io is the sole canonical
registry (D1). ECR Public may be added later as a *same-region accelerator
mirror* — but only if pull latency is measured to materially hurt nf-spawn job
startup on Graviton, and only as a mirror of the quay-canonical images (never a
divergent second source).

**Why deferred, not adopted now:**
- The only surviving ECR advantage is same-region-free pull speed for Graviton
  EC2 (D1). That is a measurable optimization, not a v1 unknown worth paying for
  blind, and it does nothing for the Apple Silicon audience (who pull over the
  internet regardless).
- Dual-publishing multiplies the D6 trust surface: two registries must be proven
  byte-identical and both signed, and lazy/re-pushed builds must stay in sync.
  One canonical, signed source is a *stronger* trust story than two mirrors.
- It's the reversible direction: adding an ECR push target later is a one-step
  builder change; un-pinning a registry users already depend on is not.

**Stretch / external-funding path:** if the project gains real adoption, lobby
AWS internally for an **AWS-funded ECR Public replication** of the quay-canonical
images. That makes the accelerator mirror someone else's bill and turns the
Graviton speed advantage into a genuine, free-to-Playground-Logic feature. This
is aspirational and depends on adoption + internal sponsorship — explicitly out
of scope until then.

### D4 — Versioning policy

**Decision:**
- **Pre-warm** the *latest* version (and the most-pulled recent versions) of each
  top-N tool.
- **Lazy-build** any older/specific version on first request.
- Mirror BioContainers' own tag scheme: `<version>--<build>`.

**Why:** pipelines pin specific versions, so we can't publish only `latest`. But
eagerly mirroring every historical tag of every tool is needless build and push
work. Pre-warm the head, let the long tail of old versions arrive on demand.

### D8 — Microarchitecture-tuned fat images (future, gated on the generational sweep)

**Idea:** for hot, SIMD-bound tools, ship **one image containing multiple builds**
of the tool — each compiled for a different arm64 microarch level — plus a tiny
launcher that detects CPU features at `docker run` time and `exec`s the best one:

```
/opt/<tool>/armv8-a/      baseline — any arm64 (Graviton1+, Apple M1+)
/opt/<tool>/armv8.2-a+sve/  Graviton3 (Neoverse V1, SVE)
/opt/<tool>/armv9-a+sve2/   Graviton4 (Neoverse V2, SVE2)
/usr/local/bin/<tool> -> launcher  # reads AT_HWCAP/HWCAP2, picks by FEATURE not chip
```

Same tag, one pull, optimal binary chosen automatically on Graviton2/3/4 or
M-series. This is **runtime dispatch across separately-compiled builds** — *not*
in-source function multiversioning (`target_clones`), which most bioinformatics
tools' source doesn't support. Doing it at packaging time is what keeps it a
packaging concern.

**Decision: deferred and selective, not v1.** Reasons:
- **It breaks the pure-conda path (D3).** bioconda ships one baseline `armv8-a`
  build; SVE/SVE2 variants require **compiling from source** with custom `-march`
  flags. So this only applies to tools we build ourselves — i.e. the "hard 15%,"
  not the easy 85%. No `conda install` shortcut exists for it.
- **Costs:** N× build time, larger images, and every variant must be correctness-
  verified (not just "it runs") — each must produce identical output.
- **Select by feature, not chip.** SVE is vector-length-agnostic, so an
  `+sve` build runs on both Graviton3 (256-bit) and Graviton4. The launcher keys
  off HWCAP feature flags so it's robust to instances we've never seen.

**Gating:** build a fat image only for tools where the **generational benchmark
sweep** (see `benchmark/`) shows a baseline-vs-tuned gap on Graviton3/4 worth the
cost. Measure first, then fatten the few that matter. Ties to the hard-15%
discussion below.

### D9 — noarch tools → multi-arch manifest; arch-specific → arm64-only

**Decision:** the builder branches on whether the bioconda package is `noarch`:

- **noarch** (pure Python, Java, etc. — e.g. multiqc, metaphlan, fastqc): publish
  a **multi-arch manifest** (`linux/amd64,linux/arm64`), each variant natively
  built. A noarch *package* is arch-neutral, but a *container* never is — it
  bundles a native interpreter (python/openjdk) and native dependency binaries
  (numpy, pysam, bowtie2…). Shipping it arm64-only would force x86 users to
  emulate an arm64 interpreter — the exact mistake we exist to fix, mirrored.
- **arch-specific** (compiled C/C++/Rust with a real `linux-aarch64` build —
  e.g. bwa, samtools, fastp, kraken2): publish **arm64-only**. The native amd64
  build already exists upstream at `quay.io/biocontainers`; we fill only the gap.

**Why it matters most on Graviton:** on a Mac the amd64 noarch container is merely
*slow* (emulated interpreter). On a vanilla Graviton instance (no binfmt/QEMU) it
**fails to start** — `exec format error`. So arch-neutral code is locked out of an
architecture by packaging alone; the multi-arch fix makes it *run at all*.

**Detection:** the builder builds an arm64 probe image, reads the installed
package's `subdir` from `/opt/conda/conda-meta/<pkg>-<ver>-<build>.json` inside
it (`"subdir":"noarch"` ⇒ multi-arch). The tag (`<version>--<build>`, D4) is
unchanged: noarch build hashes are identical across arches, so one tag covers
both. Multi-arch builds must `--push` (buildx can't `--load` a manifest list).

**Caveat:** a noarch top package can still have a dependency with no
`linux-aarch64` build — then the arm64 half fails and the tool is "hard 15%"
(D10), not multi-arch. The build, not the noarch label, is the proof.

### D10 — Hard-15% policy: report upstream, don't compile from source

**Decision:** when the arm64 build fails (a dependency has no `linux-aarch64`
bioconda package), the builder **auto-files a deduped `arm64-gap` issue**
(tool, version, build-log tail, run URL) and moves on. It does **not** attempt to
compile the missing package from source.

**Why not from-source (rejected):** building a conda package for a new arch from
source means reproducing bioconda's per-recipe build scripts, patches, flags, and
tests — and recursing into *its* missing deps. That turns aarchbio into a second
bioconda and makes us own the correctness of packages no blessed channel
produced (a direct D6 trust regression). The correct fix lives **upstream**:
enable `linux-aarch64` in the bioconda recipe's CI. aarchbio's leverage is making
the gap **visible and actionable**, and the auto-filed issues double as the
upstream-contribution backlog.

### D11 — Request issues are the miss-driven build queue (resolves OQ1)

**Decision:** a GitHub **issue form** (`request-container.yml`, label
`container-request`) is how users request a tool, and it *is* the D3 "miss-driven"
driver. This resolves OQ1: a registry can't trigger a build on a pull-miss, but a
filed issue can be parsed and fed into the publish workflow. Pre-warm (D2 top-N)
and these requests are two queues into the one builder.

### D12 — Build infrastructure: native runners per arch (no emulation)

**Observation:** GitHub-hosted runners are slow for this workload — cold start,
no conda/layer cache between runs, and worst of all, **building the amd64 half of
a multi-arch image on an arm64 runner runs under QEMU emulation** (metaphlan's
emulated amd64 build took ~25 min before we cancelled it). Emulating an
architecture to publish images whose purpose is to end emulation is both slow and
self-contradictory.

**Decision: build each arch on its OWN native hardware, then merge.** No `--platform`
cross-build. The CI matrix (D13) splits noarch builds into an amd64 leg on a
native amd64 runner and an arm64 leg on a native arm64 runner.

**Local build farm (confirmed hardware, planned wiring):**
- **orion.local** — Apple M4, native **arm64** (Colima/docker).
- **janus.local** — native **Linux x86_64**, docker 29.2.1 (no colima needed).
- Together they cover both arches natively for the bulk/long-tail builds — free,
  cached, no per-minute clock, no emulation. Same `build-arch.sh`/`merge.sh`
  primitives as CI; SSH-driven. Not yet wired.

Hosted runners remain the canonical sign/publish path (reliable keyless OIDC,
safe for a public repo).

### D13 — Native multi-arch via matrix + manifest merge

**Decision:** the publish workflow classifies each tool (cheap dry-run solve,
`classify.sh`), then:
- **arch-specific** → one job, native arm64, `build.sh` (build+tag+push) → sign → public.
- **noarch** → a `build-leg` matrix with one job per (tool × arch) on the matching
  native runner (`ubuntu-24.04` for amd64, `ubuntu-24.04-arm` for arm64); each
  builds its arch with `build-arch.sh` and pushes **by digest** (no tag), saving
  the digest as an artifact. A dependent `merge` job runs `merge.sh` to assemble
  the manifest list under the `<version>--<build>` tag, then cosign-signs the
  **manifest-list** digest (covers all arches) and sets the repo public.

Push-by-digest avoids the two arch legs racing on the tag; the merge publishes
the tag atomically.

### D14 — Website (aarch.bio) and request automation (planned)

- **Website:** a GitHub Pages site at **aarch.bio**, generated *from the registry*
  (list published tools, link each to its quay page + a copy-paste `cosign verify`
  command), plus the story and benchmark data. Purpose: **discovery** (the
  silently-emulating cohort won't seek us out otherwise) and **trust UX** (an
  unused signature is theater — the verify command must be one copy-paste away).
- **Request automation:** an `on: issues` workflow parses `container-request`
  forms (D11), validates via `classify.sh`, and dispatches `publish.yml` — gated
  ("with checking"): the package must resolve in bioconda, and a new tool's first
  version requires a maintainer `approved` label before building (guards against
  typosquat/malicious package names). Closes the request→publish loop.

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
            → sign + stamp provenance (source recipe + git SHA)         (D6)
            → docker buildx --platform linux/arm64   (native, no QEMU)
            → push → tag <version>--<build>                              (D4)
                │
                └── quay.io/aarchbio/<tool>                      (D1)
```

Consumers point a Nextflow registry override at it (works on both Graviton and
Apple Silicon — Docker selects the arm64 image automatically):

```nextflow
// nextflow.config
docker {
    registry = 'quay.io/aarchbio'
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
- **OQ2 — base image parity:** confirm the ARM64 base container matches the
  amd64 BioContainers base closely enough that only the architecture differs.
- **OQ3 — multi-arch manifest:** decide whether to publish a single multi-arch
  manifest (so `quay.io/aarchbio/<tool>` resolves to arm64 on M-series
  and Graviton automatically and could later carry amd64 too) or arm64-only tags.
  Multi-arch is the more transparent UX for Mac users.

> Former OQ2 (ECR Public quota) is moot — quay.io is canonical and free (D1);
> ECR is deferred (D7). Former OQ3 (provenance) is resolved — now a v1
> requirement in D6.

## Non-goals (v1)

- Publishing to any registry other than quay.io. ECR Public is deferred to a
  possible accelerator mirror (D7), not a v1 target.
- Rebuilding tools whose bioconda recipe has no `linux-aarch64` package and no
  feasible native build.
- Replacing Wave / Seqera for on-the-fly, arbitrary-image builds. This is a
  publish-ahead-of-need mirror, not a general build service.
