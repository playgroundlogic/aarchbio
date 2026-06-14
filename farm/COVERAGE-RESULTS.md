# Coverage build results — full nf-core arm64-capable catalog

The coverage-first build: every arm64-capable tool in the nf-core ecosystem
(from the audit) not already published. Built on the local native farm
(janus amd64 + orion arm64), no emulation.

## Outcome

| | Count |
|---|------:|
| Tools attempted (coverage worklist) | 467 |
| **Built native arm64 + signed + public** | **402 (86%)** |
| Gap (no arm64 at pinned/latest version) | 65 |
| Real build failures | 0 |

Combined with the earlier demand-first run + gap bumps, the live catalog is:

> **502 tools on quay.io/aarchbio — 100% public, 100% cosign-signed, native arm64.**

Covering the large majority of the entire nf-core arm64-capable ecosystem.

## What this confirms

- **86% buildable across the BROAD ecosystem** (not just popular tools) — the
  "endemic but shallow" thesis holds: most tools are arm64-ready; the gap is
  publishing, not capability.
- **0 real build failures** once the farm was tuned (the 74 mid-run "fails" were
  an ssh-idle-timeout artifact killing slow multi-arch builds — fixed by raising
  ServerAliveCountMax; verified the tools build fine).
- The farm + CI-signing split scales: heavy native builds local (free, no
  emulation), light keyless signing in CI (truthful Sigstore/Rekor provenance).

## Bugs found and fixed along the way (farm hardening)

1. emit() returned non-zero when GITHUB_OUTPUT unset → merge "failed" on success.
2. merge.sh cosmetic pipe tripped SIGPIPE/pipefail.
3. ssh had no timeout → a wedged connection hung the run ~48 min.
4. ssh timeout then TOO aggressive (~2 min) → killed 74 slow multi-arch builds.
5. quay repo listing not paginated → sign-batch missed 402 private repos.

## The 65 gaps

Categorized via audit/gap-enrich.sh (version-pin / dep-gap / never-arm64). The
actionable ones (version-pin, dep-gap) become issues; the genuine never-arm64
long tail goes to a GAPS.md table. (Pending.)
