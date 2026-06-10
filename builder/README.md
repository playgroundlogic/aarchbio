# builder

The core of the project: a **generic, parameterized builder** that rebuilds any
bioconda package as a native arm64 container. One `Dockerfile` + one `build.sh`
serve every tool — the tool and version are arguments, so the same recipe scales
from 1 image to 10,000.

## Files

- `Dockerfile` — `micromamba install <pkg>=<version>` on a multi-arch base, with
  provenance labels (DESIGN.md D6) stamped in.
- `build.sh` — the idempotent builder (D3): assert arm64 conda package exists →
  build `--platform linux/arm64` (native, no QEMU on an arm64 host) → **tag from
  what was actually installed** → smoke-test → optionally push.

## Usage

```bash
# Build locally (does not push). Exact version recommended.
./build.sh minimap2 2.28
./build.sh samtools 1.22.1          # use the FULL version — see note below

# Pin the exact conda build hash (build fails if the install doesn't match):
./build.sh minimap2 2.28 h0cbc5ad_4

# Push to quay.io/playground-logic (requires `docker login quay.io`):
PUSH=1 ./build.sh minimap2 2.28
```

## Provenance: the tag never lies (D6)

The tag is `<version>--<build>`, BioContainers' scheme (D4). Critically, the
build hash is read **from the finished image**, not predicted beforehand — the
conda resolver inside the arm64 container can pick a different build than a host
`conda search` would, and tagging from a prediction produced a tag that
misreported its own contents. `build.sh` now:

1. builds to a temporary tag,
2. reads the real installed `version build` via `micromamba list` inside the image,
3. fails hard if the installed version ≠ requested, or ≠ a CLI-pinned hash,
4. tags from the actual install.

So a pulled image always contains exactly what its tag claims.

## Notes / known issues

- **Exact versions.** `conda` treats `samtools=1.22` as a prefix match and may
  resolve `1.22.1`; the integrity guard then refuses to mislabel it. Pass the
  full version (`1.22.1`) you want.
- **`org.opencontainers.image.created`** is still inherited from the micromamba
  base layer (BuildKit sets that field specially, not via `LABEL`), so it shows
  the base's build date, not ours. Cosmetic but on the fix list.
- **Validated locally** on Apple Silicon (M4 Pro) for `minimap2`, `bwa`,
  `samtools`, `seqkit` — all build native arm64, tag-matches-install, runnable.
  Nothing has been pushed.
