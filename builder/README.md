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
- `mulled.py` — computes, and **inverts**, the hashed coordinates of legacy
  BioContainers `mulled-v2-*` multi-package images.
- `build-mulled.sh` — rebuilds one of those fused images for arm64 under its
  **exact upstream `name:tag`**.

## Legacy `mulled-v2-*` images

Some nf-core processes pin a *fused* multi-package image whose name and tag are
both opaque hashes. Those looked unbuildable by construction: the hash is one-way,
so nothing could say which packages it stood for, and four were written off as
"never-arm64" for that reason alone.

They are recoverable. The coordinates are

```
repo = "mulled-v2-" + sha1("\n".join(package names,    sorted by name))
tag  =               sha1("\n".join(package versions, in that same order)) + "-<build>"
```

so a hash can be inverted by brute force over the public combination list. Note
the *names alone* fix the repo — which is why one mulled repo carries many tags,
one per version combination.

```bash
# What is this thing?
./mulled.py invert mulled-v2-780d630a9bb6a0ff2e7b6f730906fd703e40e98f:a9e32be812f4aa6b7691c4f43d2bad41e56fc246-0
# -> cnvkit=0.9.10,samtools=1.19.2   a9e32be8...-0   WANTED

# Rebuild it for arm64 under that same tag
PUSH=1 ./build-mulled.sh cnvkit=0.9.10 samtools=1.19.2
```

Input is always the **ingredient list, never the hash** — the hash is what you
have when you *don't* know the ingredients, so resolve it with `invert` first.

Why a separate script from `build.sh`: `build.sh` derives both coordinates from
one package (repo = its name, tag = `<version>--<conda build hash read back from
the built image>`). A mulled image has neither, so its coordinates must be
computed up front from the whole spec set. `build-mulled.sh` also checks the
computed `name:tag` really exists upstream before pushing (otherwise it would
publish a hash nobody can pull), verifies **every** ingredient resolves, and
requires **every** ELF in `bin/` to be AArch64 — the all-binaries form is what
catches a recipe shipping a prebuilt x86_64 blob, which one sampled binary misses.

## Usage

```bash
# Build locally (does not push). Exact version recommended.
./build.sh minimap2 2.28
./build.sh samtools 1.22.1          # use the FULL version — see note below

# Pin the exact conda build hash (build fails if the install doesn't match):
./build.sh minimap2 2.28 h0cbc5ad_4

# Push to quay.io/aarchbio (requires `docker login quay.io`):
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
