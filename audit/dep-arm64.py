#!/usr/bin/env python3
"""dep-arm64.py — for one package+version, check EVERY dependency for arm64.

Why this exists: I checked a subset. Diagnosing `pycoqc=2.5.2` I looked at the
dependency the solver named (`h5py`) plus the two that looked suspicious (`numpy`,
`pandas`), concluded "h5py is the sole blocker", and said so in an upstream issue.
It was wrong — `pysam=0.15.3` has no arm64 either, and worse, the two fixes are
mutually exclusive (`pysam>=0.22` needs a newer Python ABI than `pandas 0.25.1`
permits). A solver reports the FIRST unsatisfiable constraint, not all of them, so
reading its error is never a complete diagnosis.

This reads the published artifact's own `depends` list — the authoritative record
of what that exact build requires, which can differ from the recipe on master —
and reports, per dependency, whether the pinned spec has arm64 and what the
nearest arm64-having version is.

Output tells you which of three situations you are in:
  ok         every pinned dependency has arm64; the package should solve
  1 blocker  a single dependency needs a bump -> a small, defensible deviation
  N blockers -> check whether the bumps are mutually compatible before promising
               anything; "one pin per line" can still be an unsatisfiable set

Usage:
    ./dep-arm64.py pycoqc 2.5.2
    ./dep-arm64.py gtdbtk 2.7.2 --channel bioconda
"""
import collections
import json
import re
import sys
import urllib.request

API = "https://api.anaconda.org/package"
ARM = {"linux-aarch64", "noarch"}


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=25) as r:
            return json.load(r)
    except Exception:
        return None


def vkey(s):
    out = []
    for part in s.replace("-", ".").replace("_", ".").split("."):
        num = ""
        while part and part[0].isdigit():
            num, part = num + part[0], part[1:]
        out.append((0, int(num), part) if num else (1, 0, part))
    return tuple(out)


def parse_spec(c):
    """"'>=1.7.0,<1.8.dev0' -> [('>=','1.7.0'), ('<','1.8.dev0')].

    Handles the conda forms that actually appear in `attrs.depends`: comma-joined
    comparators, a bare version (implicit ==), and trailing `.*` wildcards.
    """
    out = []
    if not c:
        return out
    for part in c.split(","):
        part = part.strip()
        if not part:
            continue
        m = re.match(r"^(>=|<=|==|!=|>|<|=)?\s*(.+)$", part)
        op, ver = (m.group(1) or "=="), m.group(2).strip()
        if ver.endswith(".*"):
            op, ver = "=pfx", ver[:-2]
        out.append((op, ver))
    return out


def satisfies(v, cons):
    """Does version v meet every constraint? Empty constraint list = yes."""
    for op, want in cons:
        a, b = vkey(v), vkey(want)
        if op == "=pfx":
            if not (v == want or v.startswith(want + ".")):
                return False
        elif op in ("==", "="):
            # conda treats a bare version as a prefix match (1.22 matches 1.22.1)
            if not (v == want or v.startswith(want + ".")):
                return False
        elif op == "!=" and a == b:
            return False
        elif op == ">=" and not a >= b:
            return False
        elif op == "<=" and not a <= b:
            return False
        elif op == ">" and not a > b:
            return False
        elif op == "<" and not a < b:
            return False
    return True


def subdirs(pkg):
    """version -> set(subdir), searching both channels; None if unknown."""
    for ch in ("conda-forge", "bioconda"):
        d = get(f"{API}/{ch}/{pkg}")
        if d and "latest_version" in d:
            m = collections.defaultdict(set)
            for f in d["files"]:
                m[f["version"]].add(f["attrs"]["subdir"])
            return ch, m
    return None, None


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    pkg, ver = argv[0], argv[1]
    chans = ("bioconda", "conda-forge")
    if "--channel" in argv:
        chans = (argv[argv.index("--channel") + 1],)

    art = None
    for ch in chans:
        d = get(f"{API}/{ch}/{pkg}")
        if not d or "latest_version" not in d:
            continue
        # Prefer a linux-aarch64 file's metadata if one exists, else noarch, else
        # any: we want the depends list of the build a user would get on arm64.
        cands = [f for f in d["files"] if f["version"] == ver]
        if not cands:
            continue
        for want in ("linux-aarch64", "noarch", None):
            for f in cands:
                if want is None or f["attrs"]["subdir"] == want:
                    art = (ch, f)
                    break
            if art:
                break
        if art:
            break
    if not art:
        raise SystemExit(f"dep-arm64: no artifact for {pkg}={ver}")

    ch, f = art
    print(f"{pkg}={ver}  channel={ch}  subdir={f['attrs']['subdir']}  "
          f"build={f['attrs'].get('build', '?')}")
    deps = f["attrs"].get("depends") or []
    print(f"{len(deps)} runtime dependencies\n")
    print(f"  {'dependency':<18}{'pinned spec':<26}{'arm64?':<9}nearest arm64")

    blockers = []
    for spec in deps:
        parts = spec.split(None, 1)
        name = parts[0]
        constraint = parts[1].strip() if len(parts) > 1 else ""

        dch, m = subdirs(name)
        if m is None:
            print(f"  {name:<18}{constraint or '(any)':<26}{'?':<9}not found")
            continue
        arm = sorted((v for v in m if m[v] & ARM), key=vkey)
        cons = parse_spec(constraint)
        match_arm = [v for v in arm if satisfies(v, cons)]

        if match_arm:
            print(f"  {name:<18}{constraint or '(any)':<26}{'yes':<9}")
            continue
        # Nothing with arm64 satisfies the pin. Report the nearest arm64 version
        # at or above the lowest bound, which is what a bump would target.
        lows = [v for op, v in cons if op in (">=", ">", "==", "=")]
        base = max(lows, key=vkey) if lows else None
        later = [v for v in arm if base is None or vkey(v) >= vkey(base)]
        near = f"-> {later[0]}" if later else "none at any version"
        print(f"  {name:<18}{constraint or '(any)':<26}{'NO':<9}{near}")
        blockers.append((name, constraint or "(any)", later[0] if later else None))

    print()
    if not blockers:
        print("  VERDICT: every pinned dependency has arm64 — expect this to solve.")
    elif len(blockers) == 1:
        n, e, t = blockers[0]
        print(f"  VERDICT: 1 blocker — {n} {e} -> {t}. A single-dependency deviation.")
    else:
        print(f"  VERDICT: {len(blockers)} blockers. Do NOT assume these are "
              f"independently fixable:")
        for n, e, t in blockers:
            print(f"    {n} {e} -> {t or 'nothing'}")
        print("  Bumping one can force another off its pin (pycoqc: pysam>=0.22 "
              "needs a newer\n  Python ABI than pandas 0.25.1 allows). Verify the "
              "whole set solves together.")


if __name__ == "__main__":
    main(sys.argv[1:])
