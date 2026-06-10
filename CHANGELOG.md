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

[Unreleased]: https://github.com/scttfrdmn/biocontainers-arm64/compare/HEAD...HEAD
