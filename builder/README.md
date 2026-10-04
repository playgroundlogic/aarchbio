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
- `build-arch.sh` — builds **one platform** of a noarch tool and pushes it by
  digest; `merge.sh` assembles the multi-arch manifest under the real tag.
- `smoke.sh` — the **verification gate**. Both publish paths call it, and a
  non-zero exit means the image is not published. See below.
- `arch-check.sh` — runs inside an image and reads `e_machine` from every ELF.
  Shell and `od` only, no interpreter, because the tools that most need it have
  none.
- `functional/<pkg>.{py,sh}` — optional per-tool "does it actually work" check.
- `entrypoints/<pkg>` — optional binary-name hints for packages that provide no
  program of their own name.
- `mulled.py` — computes, and **inverts**, the hashed coordinates of legacy
  BioContainers `mulled-v2-*` multi-package images.
- `build-mulled.sh` — rebuilds one of those fused images for arm64 under its
  **exact upstream `name:tag`**.

## The verification gate (`smoke.sh`)

A broken image is worse than an absent one: it looks available in the namespace
and fails only after a pull. So nothing publishes unless the gate can *demonstrate*
it works. Every level below exists because the level above it let a real defect
reach the registry — a catalog-wide audit found 15, and 5 of those had passed the
checks as they then stood.

| level | proves | caught |
|---|---|---|
| 0 **arch** | `e_machine` of every ELF in `bin/`, `libexec/`, `lib/**.so` | `pureclip` — its *own* primary binary is x86-64 |
| 1 **entry point** | the binaries the package owns, per conda-meta, **executed** | `transdecoder` — three dangling symlinks |
| 2 **import** | every Python module the package installs | `humann` — files under `python3.12`, interpreter 3.13 |
| 2b **R library** | `Rscript -e library(X)` | 8 R packages nothing could prove at all |
| 3 **functional** | optional per-tool workload | `scanpy` — imported fine, could not cluster |

Hard-won details, each of which was a bug at some point:

- **Behaviour is not evidence for architecture.** Docker Desktop on Apple Silicon
  has a Rosetta handler, so a statically linked x86-64 binary runs happily on a Mac
  while being unrunnable on Graviton. Read the ELF header.
- **On-PATH mismatches are fatal; vendored ones warn.** `riboWaltz` ships an
  x86-64 `pak` private library and works perfectly; blocking it would withhold a
  working tool. But a foreign binary in `bin/` means the tool cannot run.
- **A foreign-arch *filename* with a native sibling is deliberate.** The ONT
  `vbz_hdf_plugin` ships `..._x86_64.so` beside `..._aarch64.so` and selects at
  runtime. Three images were falsely accused before this was handled.
- **Module names come from conda-meta, never from the package name.** `pycoqc`
  ships `pycoQC`, `scikit-learn` ships `sklearn`.
- **Binary names likewise.** `abyss` ships `abyss-pe`, `star` ships `STAR`,
  `emboss` ships 442 binaries. Guessing produced 95 false failures.
- **Existence is not execution.** `command -v` is satisfied by a dangling symlink
  and by a binary of the wrong architecture.
- **Exit codes 126/127 are the failure signal**, not "non-zero" — plenty of these
  tools exit non-zero on `--version`.
- **Conda's own hooks are not entry points.** `.*-post-link.sh` ran, which once
  "proved" `bioconductor-minfidata` while proving nothing.
- **Pull as its own step.** Letting the first probe also pull meant a cold image
  returned no modules and the gate silently fell through to its weakest check —
  and every image in CI is cold.

### Adding a functional check

Write `functional/<pkg>.py` (run with `python -`) or `functional/<pkg>.sh` (run
with `sh -s`) — whichever the image can execute; `evigene` has no Python at all.
Exit non-zero to block the publish. Synthesise inputs rather than downloading
them, and assert on the *result*, so a tool that runs but returns nonsense fails:
`functional/cnvkit.py` requires segmentation to find exactly the 3 clusters its
synthetic input contains.

Keep a known-broken sub-feature *reported* rather than asserted when the tool is
otherwise usable — cnvkit's `flasso` backend is unavailable because of an upstream
x86-64 `.so`, and failing the whole image over it would withhold a working tool.
Phrase the message so it flips when upstream fixes it.

**Verify a new check in both directions.** A check that cannot fail is worth
nothing: break the thing deliberately (hide the dependency) and confirm the gate
goes red.

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
