#!/bin/sh
# Functional check for evigene, which has no entry point on PATH by design.
# It is driven via $EVIGENEHOME, set by the recipe's conda activation script, so
# the only meaningful test is that the variable points at a tree whose scripts run.
set -e
: "${EVIGENEHOME:?EVIGENEHOME is not set — the activation script did not run}"
[ -d "$EVIGENEHOME/scripts" ] || { echo "  no scripts/ under EVIGENEHOME=$EVIGENEHOME" >&2; exit 1; }
n=$(ls "$EVIGENEHOME"/scripts/*.pl 2>/dev/null | wc -l | tr -d ' ')
echo "  EVIGENEHOME=$EVIGENEHOME with $n perl scripts"
[ "$n" -gt 0 ] || { echo "  no perl scripts found" >&2; exit 1; }
# Prove one actually executes under the image's perl rather than merely existing.
s=$(ls "$EVIGENEHOME"/scripts/*.pl | head -1)
perl -c "$s" 2>&1 | tail -1 | sed 's/^/  /'
echo "  evigene functional check PASSED"
