#!/usr/bin/env python3
"""mulled.py — compute (and invert) BioContainers "mulled-v2" image coordinates.

WHY THIS EXISTS
---------------
Some nf-core processes don't pin a single-tool biocontainer; they pin a *fused*
multi-package image whose name and tag are both opaque hashes, e.g.

    biocontainers/mulled-v2-780d630a9bb6a0ff2e7b6f730906fd703e40e98f:c94363856059151a2974dc501fb07a0360cc60a3-0

Four of those turned up in the coverage build and were recorded as
"never-arm64" gaps — not because arm64 was impossible, but because nothing in
the pipeline could say *what packages the hash stood for*. A hash is one-way, so
they looked unbuildable by construction.

They aren't. The hash inputs are short and the candidate set is public, so the
mapping can be recovered exactly:

    repo name = "mulled-v2-" + sha1("\\n".join(package names,   sorted by name))
    tag       =               sha1("\\n".join(package versions, in that same order)) + "-<build>"

(This matches galaxy-tool-util's `mulled_util.v2_image_name`. Note the *names*
alone determine the repo, which is why one mulled repo carries many tags: one
per version combination.)

VALIDATION (do not weaken this without re-running it)
-----------------------------------------------------
Inverted by brute force over the 951 combinations published in
BioContainers/multi-package-containers `combinations/hash.tsv`. All four unknown
repo hashes resolved, and every version combination for those repos reproduced a
tag that actually exists on quay.io/biocontainers — 14 of 14, including all six
tags of the cnvkit+samtools repo and all six of the dragmap+samtools+pigz repo.
A wrong algorithm cannot hit 14 real 40-hex tags by chance.

USAGE
-----
    # forward: specs -> image coordinates
    ./mulled.py name  cnvkit=0.9.10 samtools=1.19.2
    ./mulled.py tag   cnvkit=0.9.10 samtools=1.19.2
    ./mulled.py ref   cnvkit=0.9.10 samtools=1.19.2      # name:tag

    # inverse: which package set produced this repo hash / this full ref?
    ./mulled.py invert mulled-v2-780d630a9bb6a0ff2e7b6f730906fd703e40e98f
    ./mulled.py invert mulled-v2-780d...:c94363856059151a2974dc501fb07a0360cc60a3-0

`invert` fetches hash.tsv (cached under /tmp) and prints every matching
combination as TSV: specs, tag, and whether that tag is the one asked for.
"""

import hashlib
import os
import sys
import urllib.request

HASH_TSV_URL = (
    "https://raw.githubusercontent.com/BioContainers/"
    "multi-package-containers/master/combinations/hash.tsv"
)
CACHE = "/tmp/aarchbio-mulled-hash.tsv"


def _sha1(text):
    return hashlib.sha1(text.encode()).hexdigest()


def parse_specs(specs):
    """["cnvkit=0.9.10", "samtools=1.19.2"] -> [(name, version), ...] sorted by name.

    Sorting by name is part of the hash definition, not a convenience: the caller
    may pass the packages in any order and must still get the upstream identity.
    """
    pairs = []
    for spec in specs:
        if "=" not in spec:
            raise SystemExit(f"mulled: spec must be pkg=version, got {spec!r}")
        name, version = spec.split("=", 1)
        pairs.append((name, version))
    return sorted(pairs, key=lambda p: p[0])


def image_name(specs):
    """Repo name. Determined by package NAMES only — versions live in the tag."""
    return "mulled-v2-" + _sha1("\n".join(n for n, _ in parse_specs(specs)))


def image_tag(specs, build="0"):
    """Tag. Versions in package-name order, then the mulled build number."""
    return _sha1("\n".join(v for _, v in parse_specs(specs))) + f"-{build}"


def _load_combinations():
    if not os.path.exists(CACHE):
        with urllib.request.urlopen(HASH_TSV_URL, timeout=30) as r, open(CACHE, "wb") as f:
            f.write(r.read())
    combos = []
    with open(CACHE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Columns are: targets, base_image, image_build — we only need targets,
            # and only entries where every target carries an explicit version.
            targets = line.split("\t")[0].split(",")
            if all("=" in t for t in targets):
                combos.append(targets)
    return combos


def invert(ref):
    """ref is 'mulled-v2-<sha1>' or 'mulled-v2-<sha1>:<tag>'. Yields matches."""
    name, _, want_tag = ref.partition(":")
    name = name.rsplit("/", 1)[-1]                     # tolerate a registry prefix
    for targets in _load_combinations():
        if image_name(targets) != name:
            continue
        tag = image_tag(targets)
        yield targets, tag, (tag == want_tag if want_tag else None)


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__.strip())
    cmd, rest = argv[1], argv[2:]
    if cmd == "name":
        print(image_name(rest))
    elif cmd == "tag":
        print(image_tag(rest))
    elif cmd == "ref":
        print(f"{image_name(rest)}:{image_tag(rest)}")
    elif cmd == "invert":
        found = False
        for targets, tag, is_wanted in invert(rest[0]):
            found = True
            flag = "" if is_wanted is None else ("WANTED" if is_wanted else "")
            print(f"{','.join(targets)}\t{tag}\t{flag}")
        if not found:
            # Not an error: hash.tsv only covers combinations that were *requested*
            # through the multi-package-containers repo.
            print(f"mulled: no known combination hashes to {rest[0]}", file=sys.stderr)
            return 1
    else:
        raise SystemExit(f"mulled: unknown command {cmd!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
