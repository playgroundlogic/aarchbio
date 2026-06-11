# farm — local native build farm

Bulk-builds aarchbio containers on local hardware, **no emulation**: amd64 on a
native x86_64 box, arm64 on a native Apple Silicon box, merged into one manifest.
Free, fast, warm-cached, and unlimited (no CI minute caps) — the substrate for
rebuilding hundreds of tools (DESIGN.md D12).

## Hardware (current)

- **orion.local** — Apple M-series, native **arm64** (Colima + Docker).
- **janus.local** — Rocky Linux 9, native **x86_64** (Docker).

Both need: Docker + buildx with a `docker-container` driver builder named
`aarchbio` (`docker buildx create --name aarchbio --driver docker-container
--bootstrap`), and `docker login quay.io` as the `aarchbio+robot` account. The
host OS is irrelevant — builds run inside the `micromamba` base container.

## Usage

```bash
./farm-build.sh worklist-demand.txt
```

Worklist: one spec per line, `tool=version` (or mulled `tool=ver+extra=ver+...`).
Per tool it classifies locally (cheap solve), then:
- **noarch** → builds amd64@janus + arm64@orion, merges → multi-arch manifest
- **arch-specific** → builds arm64@orion only (amd64 already upstream)

Pushes **tagged but unsigned/private**. Resumable via `state.tsv` (skips `ok`
lines). The host Mac runs the merge (has buildx + auth).

## Signing is separate (D6)

The farm has no OIDC token, so it does **not** sign. After a farm run, a CI
`sign-existing` pass keyless-signs the pushed tags and sets them public — keeping
truthful Sigstore/Rekor provenance. Build heavy + local; sign light + in CI.

## Worklists

- `worklist-demand.txt` — the 101 unique biocontainers tool:versions that 5
  popular nf-core pipelines actually pin (from the container audit). Demand-first.
