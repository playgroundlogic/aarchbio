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

| Missing arm64 dependency | Tools it blocks | Category |
|--------------------------|----------------:|----------|
| `bedtools` (version-pinned) | 3 | compiled — arm64 exists at newer ver; pin bump |
| `tensorflow` / `keras` / `lasagne` / `h5py` | ~6 | **ML stack** — hard; waits on arm64 ML conda builds |
| `blast` (>=2.17) | 2 | compiled — arm64 exists at some vers |
| `bowtie2` / `bowtie` | 3 | compiled aligners — arm64 at other vers |
| `tabixpp`, `medaka`, `sepp`, `nextgenmap`, `flash`, `bbmap`, `ariba`, `genomethreader`, `biopython`, `r-castor`, `bioconductor-deseq`, `pycoverm`, `cbgen`, `expressbetadiversity`, `pyscipopt`, `ispcr` | 1 each | misc — one upstream issue per dep |
| transitive / pypy ABI (e.g. `fargene`) | few | deep solver conflicts; lowest priority |

**Two clusters worth calling out:**
- **Compiled aligners (bedtools/blast/bowtie2)** — these *have* arm64 at some
  version; the gap is a downstream tool pinning a pre-arm64 version of the dep.
  Self-resolves over time; the reconciler catches it.
- **ML-dependent tools (deeparg, deepbgc — via tensorflow/keras)** — the genuine
  hard tail. arm64 ML conda packaging is a conda-forge-scale problem, not ours.

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
