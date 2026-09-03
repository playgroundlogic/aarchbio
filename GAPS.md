# arm64 gaps — what aarchbio can't build (yet), and why

The honest record of bioinformatics tools that **can't** be published as native
arm64 today, from the coverage build (467 nf-core-ecosystem tools, 402 built).
This is both a transparency record and a **prioritized upstream-contribution
roadmap** — most gaps are one missing *dependency* away, not fundamental.

aarchbio does **not** compile packages from source (that would make it a second
bioconda and break the trust model — see DESIGN.md D10). Gaps are fixed
*upstream* by enabling `linux-aarch64` in the relevant bioconda recipe. aarchbio's
job is to surface and prioritize them. The scheduled reconciler (D15) re-checks
and auto-clears entries as upstream fills them.

## Summary (coverage build, 65 gaps of 467 tools)

| Kind | Count | Meaning | Action |
|------|------:|---------|--------|
| **dep-gap** | 53 | tool is arm64-capable, but a *dependency* lacks an arm64 build | fix the **dependency's** recipe upstream |
| **version-pin** | 12 | arm64 exists for the tool, but not at the pinned version | bump the pin (or build the arm64 version) |
| **never-arm64** | 0 | — | none in this set |

**86% of the broad ecosystem built natively.** The 14% gap is overwhelmingly
*transitive* (a dep, not the tool) — reinforcing "endemic but shallow": the
capability is nearly there; the holes are specific, nameable, and upstream-fixable.

## dep-gaps by blocking dependency (the leverage points)

53 tools are blocked by ~20 missing arm64 dependencies. Fixing one dependency
upstream unblocks every tool that needs it. Ranked by downstream impact:

> **Read this table with the re-diagnosis below.** It was built from the coverage
> run's classifier, which asked whether the *dependency* had an arm64 file at the
> *pinned* version. When every tracked issue was later re-solved individually,
> each "dep-gap" turned out to be a **version-pin gap one level down** — the dep
> has arm64, just not at the pinned version. Expect the same of most rows here;
> "missing arm64 dependency" below usually means "missing at the pinned version".

| Missing arm64 dependency | Tools it blocks | Category |
|--------------------------|----------------:|----------|
| `bedtools` (version-pinned) | 3 | compiled — arm64 exists at newer ver; pin bump |
| `blast` (>=2.17) | 2 | recipe arm64 **disabled** ("until CircleCI resolved", since the 2.17.0 PR merged 2025-08); maintainers `@christiam @ebete` |
| `bowtie2` / `bowtie` | 3 | compiled aligners — recipe arm64 **enabled**; gap is version-lag |
| dead ML libs: `lasagne` (deeparg), `keras 2.2.4` (deepbgc) | 2 | **genuine dead-end** — see below |
| `tabixpp`, `medaka`, `sepp`, `nextgenmap`, `flash`, `bbmap`, `ariba`, `genomethreader`, `biopython`, `r-castor`, `bioconductor-deseq`, `pycoverm`, `cbgen`, `expressbetadiversity`, `pyscipopt`, `ispcr` | 1 each | misc — run `audit/provenance.sh <dep>` to attribute |
| transitive / pypy ABI (e.g. `fargene`) | few | deep solver conflicts; lowest priority |

Use [`audit/provenance.sh <dep>`](audit/provenance.sh) to trace any blocking dep
to its bioconda recipe maintainers + arm64 status (enabled / disabled-with-reason
/ not-mentioned / not-bioconda).

**Three clusters worth calling out:**
- **Compiled aligners (bedtools/bowtie2)** — recipe arm64 is *enabled*; the gap is
  just a downstream tool pinning a pre-arm64-build version. Self-resolves; the
  reconciler catches it.
- **`blast`** — recipe arm64 is *deliberately disabled* with a tracked reason
  (CircleCI infra), pending re-enablement since the 2.17.0 update merged in Aug
  2025. Not ours to fix; watch the recipe. We keep the latest arm64-having version
  (2.16.0) published meanwhile.
- **`deeparg` / `deepbgc` — NOT a "modern ML on arm64" problem** (corrected: their
  earlier "tensorflow" label was wrong — tensorflow *does* have arm64 via
  conda-forge). They pin **abandoned** DL libraries: deeparg needs `lasagne`
  (dead Theano-era lib) and deepbgc needs `keras 2.2.4` (2018, pre-merger).
  Neither exists for arm64 anywhere, and both tools are *already at their latest
  version* — so version-bumping can't help. Genuine dead-end until the **tool
  authors** modernize their DL stack; far below aarchbio's layer (D16).

## version-pin gaps (arm64 available at a different version)

| Tool (pinned) | arm64 available at | Note |
|---------------|--------------------|------|
| isoseq3=4.0.0 | 3.2.0–3.2.1 | PacBio — arm64 only at *older* versions |
| medaka=2.2.2 | 2.0.1–2.2.1 | bump down one minor |
| meryl=2013 | 1.4.1 | odd pin (date-version) |
| paraphase=4.0.0 | 1.1.3–3.5.0 | |
| pbccs=6.4.0 | 4.0.0 | PacBio |
| pbmm2=26.1.99 | 1.8.0 | PacBio — newer dropped arm64 |
| pbsv=2.11.0 | 2.2.1–2.2.2 | PacBio |
| plink=1.90b6.21 | 1.90b7.7 | |
| thermorawfileparser=2.0.0.dev | 1.1.7–1.4.5 | dev pin |
| trgt=5.0.0 | 0.3.3–0.9.0 | PacBio |
| varlociraptor=8.9.5 | 8.4.6–8.9.4 | bump down |
| vt=2015.11.10 | 0.57721 | date-version pin |

**Notable:** several PacBio tools (isoseq3/pbccs/pbmm2/pbsv/trgt) have arm64 only
at *older* versions — PacBio appears to have **dropped** arm64 in recent releases
rather than added it. Worth flagging to PacBio/bioconda upstream as a regression.

## Re-diagnosis of the tracked issues (2026-09-03)

Every open `arm64-gap` issue was re-diagnosed with a real `micromamba` arm64
**solve** rather than by asking whether a `linux-aarch64` file exists. That
distinction matters: the earlier pass judged availability from the presence of a
`linux-aarch64` **or `noarch`** package file, which wrongly cleared `comebin`,
`pycoqc` and `gtdbtk` — they are `noarch` packages whose *dependencies* are the
problem. `builder/classify.sh` (a solve) is the source of truth; a file listing is
not.

**The headline correction: there were no true "dependency gaps" left.** All four
issues labelled that way are **version-pin gaps one level down** — the dependency
*does* have arm64, just not at the version the tool pins. That is a much cheaper
fix than "port a dependency to arm64", and it is a one-line recipe change:

| Tool | Pins | Pinned dep on arm64? | arm64 exists at | Real blocker |
|------|------|----------------------|-----------------|--------------|
| `gtdbtk=2.7.2` | `pplacer 1.1.alpha19.*` | ✗ linux-64 only | `alpha20`, `alpha22` | **pplacer pin** |
| `comebin=1.0.4` | `bedtools 2.30.0.*` | ✗ linux-64 only | `2.31.1` | **bedtools pin** (but see below) |
| `pycoqc=2.5.2` | `h5py 2.9.0.*` | ✗ linux-64/osx-64/win-64 | `3.3.0`–`3.9.0` | **h5py pin** |
| `tiara=1.0.3` | `pytorch >=1.7,<1.8` | ✗ none below 1.12.0 | `1.12.0` … `2.13.0` | **pytorch pin** (a 2020 pin) |

Two things worth acting on rather than just recording:

- **`pplacer` is a shared leverage point.** `gtdbtk` pins `1.1.alpha19` today, and
  the *master* `comebin` recipe has already relaxed `bedtools` to `>=2.31,<3`
  (which has arm64) while still pinning `pplacer =1.1.alpha19` — so comebin's next
  release just swaps one blocker for the other. One pin bump, in two recipes,
  clears both tools. Note the split: the *published* `comebin=1.0.4` artifact
  carries the old `bedtools 2.30.0.*` pin, so the solve and the master recipe
  disagree, and both readings are true of different things.
- **`comebin`'s pytorch pin is fine.** `pytorch >=2.13,<2.14` looks alarming but
  `2.13.0` does have `linux-aarch64`. Not a blocker; don't report it as one.

### Genuine dead-ends (skip-listed `wontfix`)

- **`msisensor2=0.1`** — the recipe's `source` is a **prebuilt x86_64 binary**
  fetched from the upstream repo (`.../raw/master/msisensor2`), with
  `skip: True  # [not linux and x86_64]`. There is no source to compile, so no
  bioconda recipe change can produce an arm64 build. Fixable only by the *tool
  authors* shipping an arm64 binary or publishable source — below our layer (D16).
- **`ale=20180904`** — bioconda's ALE (Assembly Likelihood Evaluator) is
  **Python-2 only** (`skip: true  # [py3k]`) and needs `pymix`, a dead Py2-era
  library that exists only for `linux-64`/`osx-64`. Same shape as
  `deeparg`/`deepbgc`: a dead dependency plus the tool already at its final
  version (2018), so no version bump can help.
  **Do not conflate with conda-forge's `ale`** — that is an entirely different
  project (Abstraction Library for Ephemerides, planetary sensor data). It has
  arm64, and it is not this tool.
- **`p7zip=15.09`** — moot rather than blocked: bioconda's `latest_version` is
  15.09 (no arm64), but we already publish the **newer** 16.02 on arm64. Chasing
  15.09 daily fails for zero gain.

### Legacy `mulled-v2-*` images: recoverable, not never-arm64

Four gaps were hashed multi-package images. They were classified "never-arm64"
because a mulled name is a one-way hash, so nothing could say what packages it
stood for — an unnameable image is unbuildable by construction. That was a
tooling artifact. [`builder/mulled.py`](builder/mulled.py) inverts the hash (see
that file for the algorithm and its validation: 14 of 14 real upstream tags
reproduced), and [`builder/build-mulled.sh`](builder/build-mulled.sh) rebuilds
them arm64-native under the **exact upstream `name:tag`** — which is required,
since an nf-core process pins that literal string.

Ingredients recovered, against the tags nf-core/sarek actually pins:

| Ingredients | Status |
|-------------|--------|
| `prodigal=2.6.3, pigz=2.6` | ✅ built at sarek's exact tag |
| `svdb=2.8.2, bcftools=1.21` | ✅ built at sarek's exact tag |
| `cnvkit=0.9.10, samtools=1.17` | version-pin: built the upstream tag with `samtools=1.19.2` |
| `dragmap=1.2.1, samtools=1.19.2, pigz=2.3.4` | version-pin: `dragmap 1.2.1` and `pigz 2.3.4` are x86-only |

**`samtools` arm64 starts exactly at 1.19.2** — 1.15 through 1.19.1 have none,
1.19.2 and everything above do. That single cutoff explains both mulled misses,
and `dragmap` *1.3.0* does have arm64 while the pinned 1.2.1 does not.

### `gatk4-spark`: an arm64 **regression**, not a gap

`gatk4-spark` was `noarch` (hence arm64-capable) through `4.6.2.0 build_1` — we
publish it. At `4.7.0.0` the recipe switched to per-arch `linux-64`/`osx-64`
outputs and never added `linux-aarch64`, so arm64 "does not exist" at the new
version. This is upstream *losing* arm64 support, which is worth reporting
differently from a gap that was never filled.

## How these resolve

- **Reconciler (D15):** re-checks gaps on each scheduled run; auto-builds any that
  upstream has since fixed, and (planned) auto-closes the matching tracking issue.
  No manual tracking rot.
- **Upstream issues:** file against the *dependency's* bioconda recipe (one issue
  per missing dep, ranked above), not 53 tool issues.
- **No from-source builds** (D10). The fix is upstream packaging, where it belongs.

## Issue tracking (how GAPS.md relates to GitHub issues)

`GAPS.md` is the **canonical bulk record** — the full table, regenerable by the
reconciler. We do **not** mint one issue per gap (that's noise). GitHub issues are
reserved for the trackable units:

- **`arm64-gap`** — an open gap tracked as an issue (the few worth individual
  attention: dependency gaps, genuine never-arm64, legacy mulled images).
- **`arm64-gap` + `upstream`** — fix belongs in an upstream bioconda recipe;
  these are the candidates to file upstream (with a cross-link when we do).
- *Closed* — resolved. Either aarchbio built the arm64 version (version-pin gaps,
  e.g. the 9 demand-run bumps closed as "built X instead"), or upstream filled it
  and the reconciler rebuilt it.

Current open backlog: `gh issue list --label arm64-gap` (dep-gaps, never-arm64,
mulled-v2). The 53 coverage dep-gaps live in the table above, not as issues, until
one warrants individual upstream action.
