# postinstall / repair hints

`builder/postinstall/<pkg>` lists conda packages to **re-install in a second
transaction** after the main install, one per line (`#` comments allowed).

Only needed for the rare upstream package that bundles — and thereby overwrites —
its own dependencies' binaries. Within a single transaction conda orders by
dependency, so the clobbering package always wins no matter how arguments are
ordered; a second transaction is the only way to let the real package's files land
last. It changes no package's contents.

When this file exists, the builder additionally deletes any remaining
foreign-architecture ELF in `bin/`/`libexec/` — those are provided by no package
built for this platform and cannot execute. Both actions are recorded in the
`io.aarchbio.repaired-packages` label.

Current entries:

- **`humann`** — `humann 3.9` is `noarch` yet ships x86-64 `bin/diamond` and
  `bin/bowtie2-*`, overwriting the correct `linux-aarch64` binaries its own
  declared dependencies install. Three conda records end up owning the same paths.
  Reported: bioconda-recipes#69811, aarchbio#66.

## Not the same thing as a dependency *version* pin

If the problem is "the solver picked a version that doesn't work", that is not a
repair — pass it as an extra spec instead (`tools="pkg=1.0+dep=2.3"`), which keeps
it visible in the build request and in the `io.aarchbio.extra-packages` label.
Cases so far:

- `humann=3.9+python=3.12` — the noarch package carries a `py312` build string but
  declares only `python >=3`, so its files land in `python3.12/site-packages`
  while the solver is free to install 3.13.
- `r-saige=1.3.1+tbb=2020.2` — `SAIGE.so` needs `tbb::task`, removed in oneTBB
  2021, while `r-rcppparallel` requires `tbb >=2023`. Pinning tbb back also pulls
  the matching older `r-rcppparallel`, giving a coherent environment.
