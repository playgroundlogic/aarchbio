#!/usr/bin/env python3
"""scope-check.py — verify the published catalog still matches what the docs claim.

Why this exists, in the words of the person who found the problem: the original
scope bug "wasn't that either document was wrong when written — it's that practice
moved and prose didn't." The README's scope table was accurate once; it then said
conda-forge was out of scope for months while four conda-forge-sourced images were
being published. Nobody noticed until a sister project filed an issue about the
boundary.

Habits don't catch that. This does: it reads the real source channel of every
published image and compares it against the set the docs enumerate. If we start
building from a channel the docs don't mention, or stop building from one they do,
this fails.

Deliberately reads labels from the REGISTRY rather than pulling images — manifest
then config blob, a few KB each. The weekly catalog-health sweep already pays the
cost of pulling 824 images; this check has no business doing it again.

Usage:
    ./scope-check.py            # exits 1 if the docs and the catalog disagree
    ./scope-check.py --list     # just print what each image was built from
"""
import concurrent.futures
import json
import re
import sys
import urllib.request
from pathlib import Path

NS = "aarchbio"
ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


def jget(url, hdrs=None, timeout=25):
    req = urllib.request.Request(url, headers=hdrs or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def catalog():
    names, page = [], None
    while True:
        u = f"https://quay.io/api/v1/repository?namespace={NS}&public=true&limit=100"
        if page:
            u += "&next_page=" + page
        d = jget(u, timeout=30)
        names += [r["name"] for r in d.get("repositories", [])]
        page = d.get("next_page")
        if not page:
            return sorted(names)


def source_channel(repo):
    """The io.aarchbio.source-channel label of repo's first real tag, or None."""
    try:
        tok = jget("https://quay.io/v2/auth?service=quay.io"
                   f"&scope=repository:{NS}/{repo}:pull")["token"]
        H = {"Authorization": f"Bearer {tok}", "Accept": ACCEPT}
        tags = [t for t in jget(f"https://quay.io/v2/{NS}/{repo}/tags/list", H)["tags"]
                if not t.startswith("sha256-") and not t.endswith(".sig")]
        if not tags:
            return None
        m = jget(f"https://quay.io/v2/{NS}/{repo}/manifests/{tags[0]}", H)
        if "manifests" in m:                      # multi-arch: pick the arm64 leg
            digs = [x["digest"] for x in m["manifests"]
                    if x.get("platform", {}).get("architecture") == "arm64"]
            if not digs:
                return None
            m = jget(f"https://quay.io/v2/{NS}/{repo}/manifests/{digs[0]}", H)
        cfg = jget(f"https://quay.io/v2/{NS}/{repo}/blobs/{m['config']['digest']}", H)
        labels = (cfg.get("config") or {}).get("Labels") or {}
        return labels.get("io.aarchbio.source-channel")
    except Exception:
        return None


def in_bioconda(pkg):
    """Does bioconda carry this package at all?

    Needed because most of the catalog predates the io.aarchbio.source-channel
    label (492 of 531 images have no readable label), so labels alone would let
    the check report OK while blind to 93% of the catalog. If we publish something
    bioconda has never heard of, it is non-bioconda by definition, label or not.

    This does NOT catch the other case — bioconda has the package but we built the
    conda-forge copy because bioconda's is frozen (scanpy, anndata, decoupler-py).
    Only the label shows that, so the two signals are complementary and both are
    reported.
    """
    try:
        d = jget(f"https://api.anaconda.org/package/bioconda/{pkg}", timeout=20)
        return "latest_version" in d
    except Exception:
        return True   # fail safe: assume bioconda has it rather than cry drift


def documented_non_bioconda():
    """Tool names the docs claim are built from somewhere other than bioconda.

    Both files name them in prose rather than a list, so this looks for the
    backticked names in the sentence that explains the exception. Keeping it
    prose-driven is intentional: the docs should stay readable, and the check
    should adapt to them, not the other way round.
    """
    found, unparsed = set(), []
    for path, pattern in (
        (Path("README.md"), r"applies to `([^`]+)`[^.]*?and to ((?:`[^`]+`[,\s and]*)+)"),
        (Path("docs/llms.txt"), r"no recipe \(([a-z0-9._+-]+)\)[^(]*?\(([^)]+)\)"),
    ):
        if not path.exists():
            continue
        text = path.read_text()
        m = re.search(pattern, text, re.S)
        if not m:
            unparsed.append(str(path))
            continue
        for group in m.groups():
            found |= {x.strip(" `") for x in re.split(r"[,\s]+and\s+|,\s*", group) if x.strip(" `")}
    return {f for f in found if f and " " not in f}, unparsed


def main(argv):
    repos = catalog()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        channels = dict(zip(repos, ex.map(source_channel, repos)))

    unknown = [r for r, c in channels.items() if c is None]
    by_channel = {}
    for r, c in channels.items():
        if c:
            by_channel.setdefault(c, []).append(r)

    if "--list" in argv:
        for c in sorted(by_channel):
            print(f"{c} ({len(by_channel[c])}): {' '.join(sorted(by_channel[c]))}")
        if unknown:
            print(f"unreadable ({len(unknown)}): {' '.join(sorted(unknown))}")
        return 0

    labelled_non_bioconda = {r for c, rs in by_channel.items() if c != "bioconda" for r in rs}

    # Label-independent signal for the unlabelled majority.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        absent = {r for r, present in zip(unknown, ex.map(in_bioconda, unknown)) if not present}

    actual = labelled_non_bioconda | absent
    claimed, unparsed = documented_non_bioconda()
    if unparsed:
        # Distinguish "the docs changed shape" from "practice drifted". Reporting
        # the former as drift would send someone to fix the catalog when the real
        # problem is this parser, so say which it is.
        print("CANNOT VERIFY — the scope claim could not be parsed from: "
              + ", ".join(unparsed))
        print("  The prose was probably reworded. Re-read it and update the pattern")
        print("  in documented_non_bioconda(), or restore the claim if it was dropped.")
        return 1

    print(f"catalog: {len(repos)} repos; labelled channels: "
          + ", ".join(f"{c}={len(rs)}" for c, rs in sorted(by_channel.items())))
    if unknown:
        print(f"  {len(unknown)} images predate the source-channel label; for those the")
        print(f"  check falls back to 'is it in bioconda at all' — {len(absent)} are not.")
    print(f"docs claim non-bioconda: {' '.join(sorted(claimed)) or '(none parsed)'}")
    print(f"catalog says non-bioconda: {' '.join(sorted(actual)) or '(none)'}")

    undocumented = actual - claimed
    stale = claimed - actual
    if not undocumented and not stale:
        print("OK — the docs and the catalog agree about where packages come from.")
        if unknown:
            print(f"  (caveat: for {len(unknown)} unlabelled images this only rules out the")
            print("   'absent from bioconda' case; a frozen-bioconda substitution there would")
            print("   not be visible until the image is rebuilt and gains the label.)")
        return 0

    if undocumented:
        print("\nDRIFT: built from a non-bioconda channel but NOT mentioned in the docs:")
        for r in sorted(undocumented):
            print(f"  {r}  (from {channels[r]})")
        print("  -> practice moved; update the scope sections in README.md and docs/llms.txt.")
    if stale:
        print("\nDRIFT: named in the docs as non-bioconda but no longer so:")
        for r in sorted(stale):
            print(f"  {r}  (now {channels.get(r) or 'absent from the catalog'})")
        print("  -> prose is stale; correct or remove the claim.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
