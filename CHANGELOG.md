# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial project scaffolding: README, design document, license, and changelog.
- `DESIGN.md` recording the architecture and decisions: quay.io as the canonical
  registry (D1), bioconda-download-count prioritization with nf-core boost (D2),
  one-builder / two-driver pre-warm + lazy model (D3), the `<version>--<build>`
  versioning policy (D4), Playground Logic as publisher of record + trust model
  (D5), provenance/attestation as a v1 requirement (D6), and ECR Public deferred
  to an optional accelerator mirror (D7).
- Generalized the project thesis: the audience is all arm64 researchers — both
  Apple Silicon Macs and arm64/Graviton servers — and the core harm is *silent*
  QEMU emulation on Macs, not just the loud `exec format error` on servers.
- D9: noarch tools (Python/Java — e.g. multiqc, metaphlan, fastqc) are published
  as **multi-arch manifests** (amd64+arm64), not arm64-only — a container bundles
  a native interpreter + native deps even when the top package is arch-neutral.
  arch-specific tools stay arm64-only (amd64 already upstream). Most acute on
  Graviton, where amd64-only noarch is a hard `exec format error`, not just slow.
- D10: hard-15% policy — on arm64 build failure the CI auto-files a deduped
  `arm64-gap` issue rather than compiling from source (which would make us a
  second bioconda); the fix belongs upstream in the bioconda recipe.
- D11: a `container-request` issue form is the miss-driven build queue (resolves
  OQ1 — registries can't trigger builds on a pull-miss, issues can).
- D12: build-infra direction — hosted runners are slow (cold cache + multi-arch
  doubling); plan to add orion (M4, warm cache) as a bulk build farm while
  keeping hosted runners for the canonical sign/publish path.
- **CI publish pipeline working end-to-end.** `.github/workflows/publish.yml`
  on GitHub-hosted `ubuntu-24.04-arm` (native arm64, no QEMU) runs, per tool:
  build → push → cosign **keyless-sign** → **set-public** → verify, in ~1 min.
  First proven on `seqkit`: confirmed public, anonymously pullable while logged
  out, and `cosign verify` validates the signature against the Rekor transparency
  log — certificate attests it was built by the `publish.yml` workflow in
  `playgroundlogic/aarchbio` at a specific commit. The D6 trust thesis is now
  concrete: verify the image, don't trust the publisher.
- D6 signing model decided: cosign **keyless from CI** (Sigstore/Rekor), not an
  interim key-based phase. Publishing is gated on signing — repos stay private
  until built+signed by the CI builder. D6a records quay publishing mechanics:
  no "default public" org setting, so the builder must set visibility via the
  REST API using a separate OAuth token (the robot token can't — 403/CSRF).
- `benchmark/` — reproducible benchmark protocol to back the thesis with data:
  `METHODOLOGY.md` (honest-benchmark controls), `gen_data.sh` (deterministic
  seeded inputs), `run_mac.sh` (Apple Silicon amd64-emulated vs native-arm64,
  free), and `graviton-plan.md` (EC2 speed+cost leg, design only — runs only with
  explicit sign-off since it spends money). No results collected yet.
- `builder/` — the core builder: a generic `Dockerfile` + `build.sh` that
  rebuilds any bioconda package as a native arm64 container (tool/version as
  args). Asserts the linux-aarch64 package exists, builds `--platform
  linux/arm64`, and **tags from the actually-installed build hash** (read out of
  the finished image) so the tag can never misreport its contents.
- Confirmed bioconda `linux-aarch64` availability and **built native arm64 images
  locally** for `minimap2`, `bwa`, `samtools`, `seqkit` on Apple Silicon (M4
  Pro) — all arm64, tag-matches-install, runnable. Proof that the project's core
  premise works. Nothing pushed.

### Fixed
- Tag/provenance drift: the builder originally predicted the conda build hash via
  a host `conda search`, but the in-container arm64 resolver picked a different
  build (`minimap2` tagged `h73052cd_3` while containing `h0cbc5ad_4`). The
  builder now derives the tag from what was actually installed and fails hard on
  any version/hash mismatch.

[Unreleased]: https://github.com/scttfrdmn/aarchbio/compare/HEAD...HEAD
