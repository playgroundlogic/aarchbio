#!/usr/bin/env bash
# upstream-status.sh — poll the upstream issues aarchbio has filed (UPSTREAM.md)
# and report, per row, whether the arm64 gap they describe is still real.
#
# Two independent signals, because they can disagree and the disagreement is the
# interesting part:
#   issue_state — has upstream acted on the report?
#   arm64_now   — does the tool ACTUALLY install on arm64 at the version we want?
#
# A closed issue with arm64_now=no was closed without a fix (or the build hasn't
# published yet). An open issue with arm64_now=yes means upstream fixed it in
# passing and our tracking issue can be closed. Never trust one signal alone.
#
# `arm64_now` is a real micromamba SOLVE via builder/classify.sh, not a check for
# whether a linux-aarch64/noarch FILE exists. That distinction is the whole reason
# these issues exist: every tool below is itself noarch, so a file listing says
# "arm64 fine" while the solve fails on a pinned dependency. A file check here
# would report every pin gap as already fixed. (See GAPS.md, "Re-diagnosis".)
#
# Solving needs Docker and takes ~10s per row. Skip it with SOLVE=0 to poll only
# the issue states.
#
# Usage:  ./upstream-status.sh        # states + solves
#         SOLVE=0 ./upstream-status.sh
set -uo pipefail
cd "$(dirname "$0")"
SOLVE="${SOLVE:-1}"

# aarchbio_issue  upstream_repo  upstream_issue  tool  version_we_want
# The tool/version is what a solve must satisfy for the gap to be closed — for a
# pin-relaxation ask that is the DEPENDENT tool, not the pinned dependency.
FILED="
40	bioconda/bioconda-recipes	68788	galah	0.5.2
39	bioconda/bioconda-recipes	68789	myloasm	0.6.0
26	bioconda/bioconda-recipes	68790	metamdbg	1.4
44	bioconda/bioconda-recipes	68791	gatk4-spark	4.7.0.0
25	bioconda/bioconda-recipes	68792	gtdbtk	2.7.2
4	bioconda/bioconda-recipes	68792	comebin	1.1.0
12	bioconda/bioconda-recipes	68793	pycoqc	2.5.2
13	conda-forge/tiara-feedstock	2	tiara	1.0.3
"

printf "aarchbio\tupstream\tissue_state\tarm64_now\ttarget\n"
printf '%s\n' "$FILED" | while IFS=$'\t' read -r ours repo num tool ver; do
  [ -z "${ours:-}" ] && continue

  state="$(gh issue view "$num" --repo "$repo" --json state,stateReason \
            --jq '.state + (if (.stateReason // "") != "" then " (" + .stateReason + ")" else "" end)' \
            2>/dev/null)"

  if [ "$SOLVE" = "1" ]; then
    # classify.sh emits `ok=0|1`; ok=1 means the arm64 solve succeeded.
    ok="$(../builder/classify.sh "$tool" "$ver" 2>/dev/null | sed -n 's/^ok=//p' | tail -1)"
    case "$ok" in
      1) arm="yes — FIXED, close #$ours" ;;
      0) arm="no" ;;
      *) arm="?" ;;
    esac
  else
    arm="skipped"
  fi

  printf "#%s\t%s#%s\t%s\t%s\t%s\n" "$ours" "${repo##*/}" "$num" "${state:-?}" "$arm" "$tool=$ver"
done
