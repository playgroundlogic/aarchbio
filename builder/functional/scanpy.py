# Functional check for scanpy: can it actually CLUSTER, not merely import?
#
# From aarchbio#63. The first fix for that issue made `import scanpy` work and was
# still not enough: the clustering backends were absent, so the image could load,
# normalise, run PCA and build a neighbour graph, and only failed at
# `sc.tl.leiden`. An import-only gate passes that image happily, which is why this
# file exists — the failure is LATE, past every cheap check.
#
# Note sc.pp.neighbors succeeds WITHOUT igraph, so even "build a graph" is not far
# enough to prove the tool works. The assertion has to reach a clustering result.
#
# Deliberately excluded: sc.tl.louvain. It needs the separate `louvain` package,
# which additionally needs setuptools for pkg_resources, and louvain is the legacy
# path in scanpy. Leiden is what current users want. Revisit if asked.
import scanpy as sc

print(f"  scanpy {sc.__version__}")

for flavor in ("igraph", "leidenalg"):
    a = sc.datasets.blobs(n_observations=60, n_variables=20, n_centers=3)
    sc.pp.pca(a, n_comps=5)
    sc.pp.neighbors(a)
    sc.tl.leiden(a, flavor=flavor, n_iterations=2)
    n = a.obs["leiden"].nunique()
    print(f"  leiden(flavor={flavor}): {n} clusters")
    # blobs() generates 3 well-separated centres, so anything other than 3 means
    # clustering ran but produced nonsense — also a failure, not a pass.
    assert n == 3, f"expected 3 clusters from blobs(n_centers=3), got {n}"

print("  scanpy functional check PASSED (clustering works, not just import)")
