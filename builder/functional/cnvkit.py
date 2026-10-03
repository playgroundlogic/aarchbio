# Functional check for cnvkit: does it actually SEGMENT?
#
# Why cnvkit needs one. The catalog audit flagged an x86-64 `cghFLasso.so` in this
# image, and every cheap check passes anyway: `import cnvlib` works, `cnvkit.py
# version` prints 0.9.10. cnvkit is a Python front end over several R backends, so
# a backend can be entirely broken while the tool looks healthy. Only running a
# segmentation touches them.
#
# What is asserted vs. merely reported:
#
#   cbs   — the DEFAULT method, backed by R DNAcopy. HARD REQUIREMENT. If this
#           breaks, cnvkit cannot do its main job and the image must not publish.
#   haar  — pure Python, no R. HARD REQUIREMENT, and it isolates blame: if haar
#           passes while cbs fails, the fault is in the R stack, not cnvkit.
#   flasso— backed by R cghFLasso. bioconda ships r-cghflasso 0.2_1 as a `noarch`
#           package containing an x86-64 .so (bioconda-recipes#69811). REPORTED, not
#           asserted: failing the build here would withhold a tool whose default
#           path works fine. The message changes if upstream ever fixes it, so this
#           stops being silent breakage and becomes a tracked limitation.
#
# The input is synthesised rather than downloaded: a flat chromosome plus one with
# an obvious gain, so a segmenter that runs but returns nonsense fails the
# >= 2 segments assertion rather than passing on an empty result.
import os
import random
import subprocess
import sys
import tempfile

random.seed(7)
work = tempfile.mkdtemp()
cnr = os.path.join(work, "synthetic.cnr")

with open(cnr, "w") as fh:
    fh.write("chromosome\tstart\tend\tgene\tdepth\tlog2\tweight\n")
    for chrom, level in (("chr1", 0.0), ("chr2", 1.0)):
        for i in range(60):
            start = i * 1000
            log2 = level + random.gauss(0, 0.05)
            fh.write(f"{chrom}\t{start}\t{start + 1000}\t-\t50.0\t{log2:.4f}\t1.0\n")

print(f"  input: 120 bins across 2 chromosomes (chr2 carries a +1.0 log2 gain)")


def segment(method):
    out = os.path.join(work, f"{method}.cns")
    proc = subprocess.run(
        ["cnvkit.py", "segment", cnr, "-m", method, "-o", out],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()
        return None, tail[-1] if tail else f"rc={proc.returncode}"
    with open(out) as fh:
        rows = sum(1 for _ in fh) - 1
    return rows, None


failed = False
for method in ("cbs", "haar"):
    rows, err = segment(method)
    if rows is None:
        print(f"  segment -m {method}: FAILED — {err}")
        failed = True
        continue
    print(f"  segment -m {method}: {rows} segments")
    if rows < 2:
        print(f"  segment -m {method}: expected >= 2 segments, got {rows}")
        failed = True

# Reported, not asserted — see the header.
rows, err = segment("flasso")
if rows is None:
    print("  segment -m flasso: UNAVAILABLE (known: r-cghflasso 0.2_1 is noarch "
          "with an x86-64 .so; bioconda-recipes#69811)")
else:
    print(f"  segment -m flasso: {rows} segments — upstream appears FIXED, "
          "consider dropping this exception")

if failed:
    print("  cnvkit functional check FAILED")
    sys.exit(1)
print("  cnvkit functional check PASSED (default cbs segmentation works)")
