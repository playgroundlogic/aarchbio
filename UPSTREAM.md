# Upstream issues filed by aarchbio

aarchbio does not compile from source (DESIGN.md D10), so a gap that traces to a
recipe is fixed **upstream** or not at all. This is the ledger of what we filed,
what it was for, and — just as important — **what we deliberately did not file**.

Poll the current state of every row with [`audit/upstream-status.sh`](audit/upstream-status.sh).

Filed 2026-09-03. Each was checked for an existing duplicate before filing
(`gh search issues --repo <repo> <tool>`); none existed.

## Filed

| aarchbio | Upstream | Tool | Ask |
|---|---|---|---|
| [#40](https://github.com/playgroundlogic/aarchbio/issues/40) | [bioconda-recipes#68788](https://github.com/bioconda/bioconda-recipes/issues/68788) | `galah` | restore `linux-aarch64`, dropped in the 0.5.0 bump (#66700) |
| [#39](https://github.com/playgroundlogic/aarchbio/issues/39) | [bioconda-recipes#68789](https://github.com/bioconda/bioconda-recipes/issues/68789) | `myloasm` | un-comment `linux-aarch64`, commented out in the 0.6.0 bump (#66876) |
| [#26](https://github.com/playgroundlogic/aarchbio/issues/26) | [bioconda-recipes#68790](https://github.com/bioconda/bioconda-recipes/issues/68790) | `metamdbg` | restore the `additional-platforms` block deleted at 1.3 (#62241) |
| [#44](https://github.com/playgroundlogic/aarchbio/issues/44) | [bioconda-recipes#68791](https://github.com/bioconda/bioconda-recipes/issues/68791) | `gatk4` | declare `noarch: generic` per output (the split dropped it) |
| [#25](https://github.com/playgroundlogic/aarchbio/issues/25), [#4](https://github.com/playgroundlogic/aarchbio/issues/4) | [bioconda-recipes#68792](https://github.com/bioconda/bioconda-recipes/issues/68792) | `gtdbtk`, `comebin` | relax `pplacer =1.1.alpha19` (only recent pplacer without arm64) |
| [#12](https://github.com/playgroundlogic/aarchbio/issues/12) | [bioconda-recipes#68793](https://github.com/bioconda/bioconda-recipes/issues/68793) | `pycoqc` | relax `h5py=2.9.0`; its `numpy`/`pandas` pins are already arm64-fine |
| [#13](https://github.com/playgroundlogic/aarchbio/issues/13) | [tiara-feedstock#2](https://github.com/conda-forge/tiara-feedstock/issues/2) | `tiara` | relax `pytorch >=1.7.0,<1.8.dev0` (arm64 starts at 1.12.0) |

Two are **questions, not bug reports** — `pplacer` and `h5py` exact pins may be
load-bearing for result reproducibility, so both issues ask whether the pin is
required and commit to recording a permanent gap if the answer is yes. Don't
re-report them if the answer comes back "the pin stays".

## Deliberately not filed

Filing here would be noise, not signal. Each is tracked locally instead.

| aarchbio | Tool | Why not |
|---|---|---|
| [#23](https://github.com/playgroundlogic/aarchbio/issues/23) | `blast` | **Maintainers already tried.** [PR #62276](https://github.com/bioconda/bioconda-recipes/pull/62276) ("re-add ARM builds", merged 2026-08-22) re-enabled `osx-arm64` but left `linux-aarch64` commented with `# CircleCI arm.large runner times out as the build takes too long`. A known CI wall-clock limit, actively worked, with a documented reason — and we have no build-time data to contribute, since D10 means we never compile blast ourselves. |
| [#9](https://github.com/playgroundlogic/aarchbio/issues/9) | `dragmap` mulled image | Blocked at the **tool author** layer (D16). nf-core/sarek pins `dragmap 1.2.1` behind an explicit `// WARN: Do not update this tool to 1.3.0 until` [Illumina/DRAGMAP#47](https://github.com/Illumina/DRAGMAP/issues/47) (open segfault, 2022). `dragmap 1.3.0` *has* arm64; 1.2.1 is x86-only and always will be. No bioconda or BioContainers change helps while that segfault is open. |
| — | `ale`, `msisensor2`, `deeparg`, `deepbgc` | Dead-end deps or a prebuilt x86_64 binary as the recipe `source`. No recipe change can help; see [GAPS.md](GAPS.md). Skip-listed `wontfix`. |
| — | `p7zip` | Moot: we already publish the *newer* 16.02 on arm64. |

## Resolved without filing

| aarchbio | Tool | Resolution |
|---|---|---|
| [#10](https://github.com/playgroundlogic/aarchbio/issues/10) | `cnvkit` mulled image | **Obsolete.** nf-core/sarek migrated this process off mulled to a Seqera Wave container (`community.wave.seqera.io/library/cnvkit_htslib_samtools`), so the hashed tag we couldn't match is no longer pinned by anything. We separately publish the arm64 `cnvkit 0.9.10 + samtools 1.19.2` mulled tag. |

## Conventions for future filings

- **Check for duplicates first**, and check the recipe's recent commit history —
  `blast` was struck off the list precisely because its git log showed an attempt
  from 12 days earlier. A stale report costs a maintainer's time.
- **Verify against the recipe on `master`**, not against the published artifact.
  They disagree: `comebin`'s published 1.0.4 pins `bedtools 2.30.0.*` while master
  had already relaxed it to `>=2.31,<3`.
- **Check every pin, not the first one that looks wrong.** `pycoqc` has three
  exact 2019 pins; only `h5py` actually lacks arm64. Reporting all three would
  have been wrong.
- **Ask, don't assert, about exact version pins.** They are frequently deliberate.
- **Disclose who we are** and offer to open the PR.
