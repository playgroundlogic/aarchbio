#!/usr/bin/env python3
"""arm64-decay.py — measure how often upstream arm64 support REGRESSES.

The usual question about arm64 in bioinformatics is "what fraction of tools
support it?", which treats coverage as a number that only goes up. The galah case
says otherwise: the recipe built for linux-aarch64 at 0.4.2, the platform line was
deleted in the 0.5.0 bump with no reason recorded, and nothing failed — an unbuilt
platform is an absence, not a red X. osx-arm64 kept working, so ARM never looked
broken. Users just silently land on emulation.

So the more useful question is: **for tools that already worked on arm64, does the
newest release still work?** This script answers it over the aarchbio catalog,
which is a population defined by "we successfully built this on arm64 at some
version" — exactly the set where a later loss is a regression rather than a gap
that was never filled.

Per package: resolve the channel, then compare arm64-capability of the newest
version against every earlier version.

  ok         newest release is arm64-capable
  REGRESSED  an earlier version was arm64-capable, the newest is not
  never      no version was ever arm64-capable (shouldn't appear for catalog
             members; if it does, it means we published from a version that has
             since been deleted from the channel)

"arm64-capable" = a linux-aarch64 file OR a noarch file. Note this is the cheap
file-level test, not a solve: it OVERSTATES capability, because a noarch package
whose dependency is x86-only still fails to install (see GAPS.md). That bias is
deliberate here — it makes the regression count a LOWER bound.

**"Newest release" is determined by upload timestamp, not by parsing version
strings.** This is the whole difficulty of the measurement. The API's
`latest_version` orders lexically and is wrong for date- or letter-embedded
versions (it calls beagle 5.4_22Jul22.46e newer than 5.5_27Feb25.75f, and plink
1.90b6.21 newer than 1.90b7.7). But a hand-rolled version sort is no better: the
first draft of this script reported 16 regressions, of which 11 were artifacts —
it ranked hhsuite's `v3.2.0` above `3.3.0` (a `v` prefix sorts after digits),
seqtk's `r93` above `1.5`, and trinity's `date.2011_11_26` above `2.15.2`.
Timestamps sidestep version grammar entirely: hhsuite's `v3.2.0` was uploaded in
2019 and `3.3.0`, with arm64, in 2025.

Caveat on timestamps: a rebuild of an OLD version (a build-number bump) uploads
later than a newer version's original release, which would make the old version
look current. Where the timestamp answer and the version-sort answer disagree, the
row is flagged `time_vs_sort_differ` so it can be eyeballed rather than trusted
silently.

Usage:
    ./arm64-decay.py                  # whole public catalog
    ./arm64-decay.py samtools galah   # just these packages
    ./arm64-decay.py --tsv out.tsv    # also write per-package rows
"""
import json
import sys
import urllib.error
import urllib.request
from collections import defaultdict

API = "https://api.anaconda.org/package"
CHANNELS = ("bioconda", "conda-forge")


def get(url, timeout=25):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.load(r)
    except Exception:
        return None


def catalog():
    """Public repo names in quay.io/aarchbio (paginated)."""
    names, page = [], None
    while True:
        u = "https://quay.io/api/v1/repository?namespace=aarchbio&public=true&limit=100"
        if page:
            u += "&next_page=" + page
        d = get(u, timeout=30)
        if not d:
            break
        names += [r["name"] for r in d.get("repositories", [])]
        page = d.get("next_page")
        if not page:
            break
    return sorted(names)


def vkey(v):
    """Mixed numeric/alpha version key. Ints sort before strings, never raises."""
    out = []
    for part in v.replace("-", ".").replace("_", ".").split("."):
        num = ""
        while part and part[0].isdigit():
            num, part = num + part[0], part[1:]
        out.append((0, int(num), part) if num else (1, 0, part))
    return tuple(out)


def classify(pkg):
    """Best state across channels.

    Both channels are evaluated and the most favourable answer wins, rather than
    taking the first channel that merely CONTAINS the name. Otherwise a package we
    build from conda-forge (`pigz`, `gawk`) is judged by a same-named bioconda
    package that has no arm64, and reports as "never" — which is what the first
    version of this script did.

    Caveat: a shared name is not always the same software. conda-forge's `ale` is
    planetary ephemerides; bioconda's is the Assembly Likelihood Evaluator. So the
    winning channel is recorded in the output, and a cross-channel result should be
    sanity-checked before being treated as "this tool is fine".
    """
    results = [r for r in (_classify_one(pkg, ch) for ch in CHANNELS) if r]
    if not results:
        return {"pkg": pkg, "channel": "?", "state": "not-found", "newest": "",
                "newest_uploaded": "", "last_good": "", "lost_after": "",
                "api_latest": "", "api_disagrees": False,
                "time_vs_sort_differ": False, "n_versions": 0}
    rank = {"ok": 0, "REGRESSED": 1, "never": 2}
    results.sort(key=lambda r: rank[r["state"]])
    best = results[0]
    if len(results) > 1:
        best = dict(best)
        best["channel"] += f" (also in {results[1]['channel']}: {results[1]['state']})"
    return best


def _classify_one(pkg, ch):
    for _ in (0,):
        d = get(f"{API}/{ch}/{pkg}")
        if not d or "latest_version" not in d:
            continue
        subs = defaultdict(set)
        when = defaultdict(str)   # version -> most recent upload_time of its files
        for f in d["files"]:
            subs[f["version"]].add(f["attrs"]["subdir"])
            ts = f.get("upload_time") or ""
            if ts > when[f["version"]]:
                when[f["version"]] = ts
        if not subs:
            continue

        def capable(v):
            return bool(subs[v] & {"linux-aarch64", "noarch"})

        # Primary signal: the most recently UPLOADED version. Version strings are
        # not parseable reliably enough to rank (see the module docstring).
        by_time = sorted(subs, key=lambda v: when[v])
        newest = by_time[-1]
        by_sort = sorted(subs, key=vkey)   # cross-check only

        earlier_ok = [v for v in by_time[:-1] if capable(v)]
        if capable(newest):
            state = "ok"
        elif earlier_ok:
            state = "REGRESSED"
        else:
            state = "never"
        return {
            "pkg": pkg, "channel": ch, "state": state, "newest": newest,
            "newest_uploaded": when[newest][:10],
            "last_good": earlier_ok[-1] if earlier_ok else "",
            "lost_after": earlier_ok[-1] if state == "REGRESSED" else "",
            "api_latest": d["latest_version"],
            "api_disagrees": d["latest_version"] != newest,
            "time_vs_sort_differ": by_sort[-1] != newest,
            "n_versions": len(subs),
        }
    return None


def main(argv):
    tsv_path = None
    if "--tsv" in argv:
        i = argv.index("--tsv")
        tsv_path = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]

    pkgs = argv or catalog()
    if not argv:
        print(f"catalog: {len(pkgs)} public repos", file=sys.stderr)

    rows = []
    for n, p in enumerate(pkgs, 1):
        rows.append(classify(p))
        if not argv and n % 50 == 0:
            print(f"  ...{n}/{len(pkgs)}", file=sys.stderr)

    by = defaultdict(list)
    for r in rows:
        by[r["state"]].append(r)

    regressed = sorted(by["REGRESSED"], key=lambda r: r["newest_uploaded"],
                       reverse=True)
    clean = [r for r in regressed if not r["time_vs_sort_differ"]]
    flagged = [r for r in regressed if r["time_vs_sort_differ"]]

    def table(rs, title):
        if not rs:
            return
        print(f"\n{title}")
        print(f"  {'package':<24}{'chan':<13}{'last arm64':<16}{'newest':<20}"
              f"{'uploaded':<12}")
        for r in rs:
            print(f"  {r['pkg']:<24}{r['channel']:<13}{r['lost_after']:<16}"
                  f"{r['newest']:<20}{r['newest_uploaded']:<12}")

    table(clean, "REGRESSED — arm64 existed, the current release dropped it:")
    table(flagged, "REGRESSED but NEEDS EYES — timestamp and version sort "
                   "disagree on which release is current,\nso this may be a "
                   "rebuild of an old version rather than a real regression:")

    total = len(rows)
    nf = len(by["not-found"])
    considered = total - nf
    print()
    print(f"considered      {considered} packages ({nf} not resolvable in "
          f"{'/'.join(CHANNELS)})")
    print(f"  ok            {len(by['ok'])}")
    print(f"  REGRESSED     {len(regressed)}   "
          f"({len(clean)} clean, {len(flagged)} need eyes)"
          + (f"  = {100*len(clean)/considered:.1f}% of catalog confirmed"
             if considered else ""))
    print(f"  never         {len(by['never'])}")
    dis = [r for r in rows if r["api_disagrees"]]
    print(f"\n  packages where the API's latest_version is NOT the most recently "
          f"uploaded version: {len(dis)}")
    if dis:
        print("    " + ", ".join(r["pkg"] for r in dis[:12])
              + (" ..." if len(dis) > 12 else ""))
    print("\nNote: capability here is file-level (linux-aarch64 or noarch), not a "
          "solve,\nso it overstates capability and the REGRESSED count is a LOWER "
          "bound.")

    if tsv_path:
        with open(tsv_path, "w") as fh:
            cols = ["pkg", "channel", "state", "lost_after", "newest",
                    "newest_uploaded", "api_latest", "api_disagrees",
                    "time_vs_sort_differ", "n_versions"]
            fh.write("\t".join(cols) + "\n")
            for r in sorted(rows, key=lambda r: (r["state"], r["pkg"])):
                fh.write("\t".join(str(r[c]) for c in cols) + "\n")
        print(f"\nwrote {tsv_path}")


if __name__ == "__main__":
    main(sys.argv[1:])
