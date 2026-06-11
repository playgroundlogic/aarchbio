# Demand-first build run — results

The first bulk farm run, over the **101 unique `tool:version` refs that 5 popular
nf-core pipelines** (taxprofiler, sarek, rnaseq, mag, viralrecon) actually pin —
the quay.io/biocontainers ones a registry override can redirect (from the
[container audit](../audit/)).

Built on the local native farm (janus amd64 + orion arm64), no emulation.

## Outcome

| | Count | % |
|---|------:|--:|
| **Built (native arm64, published)** | **81** | **80%** |
| Gap (no arm64 at the pinned version) | 20 | 20% |
| Build failures (orchestrator) | 0 | 0% |

80% of the *exact pinned versions* real pipelines use are now native arm64 on
`quay.io/aarchbio`. (Higher than it looks vs. the audit's 62%-at-latest in one
sense and lower in another — see "version-pinning" below.)

## The 20 gaps, categorized (`gaps-enriched.tsv`)

Not "20 tools don't work" — four distinct, actionable kinds:

| Kind | Count | What it means | Fix |
|------|------:|---------------|-----|
| **version-pin** | 9 | arm64 exists for the tool, just not at the pinned (old) version | pipeline bumps to the arm64-having version (shown in the report) |
| **never-arm64** | 8 | no arm64 build at any version | genuine hard tail — incl. 4 old-style `mulled-v2-*` hashed images (need mulled handling, not a name build) |
| **dep-gap** | 3 | package is noarch/arm64 but a *dependency* has no arm64 build | upstream (enable arm64 for the dep) |

Examples: `adapterremoval 2.3.2 → 2.3.3` (version-pin), `comebin 1.0.4` (dep-gap),
`ale`, `tiara`, `msisensor2` (never-arm64).

**Version-pinning is the headline nuance:** pipelines pin versions that often
predate a tool's arm64 enablement. So "is this tool arm64-ready?" (audit, latest
version) and "does this pipeline run native on arm64 as-pinned?" (this run) are
different questions with different answers. Both are true; the second is the
lived experience.

## Method notes

- `farm/farm-build.sh` builds + pushes (private/unsigned); CI `sign-existing.yml`
  then keyless-signs + sets public (D6 — the farm has no OIDC).
- `audit/gap-enrich.sh` categorizes each gap via the anaconda.org API. Caveat: a
  noarch/arm64 *file* existing does not guarantee the package *installs* on arm64
  (deps may fail) — the build solve is authoritative; enrichment explains.
