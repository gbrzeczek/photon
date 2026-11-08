#!/bin/bash
# Spike 3 on a real drive. Nothing here writes to the volume. Results stay in
# ~/PhotonSpikeResults, because they contain file names and must not be committed.
#
#   real-media.sh snapshot <mount> <label> [folder...]   Record identity.
#   real-media.sh compare <label-a> <label-b>
#
# Only run this on a drive that's already mounted read-only, so that nothing can write to the volume.
# A physical pull is no longer part of testing, by the user's decision. See docs/PLAN.md,
# Removable media checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/.build/release/volume-probe"
OUT="$HOME/PhotonSpikeResults"; mkdir -p "$OUT"
[ -x "$PROBE" ] || (cd "$HERE" && swift build -c release)

case "${1:-}" in
snapshot)
  mount="$2"; label="$3"; shift 3
  "$PROBE" snapshot "$mount" "$OUT/$label.json" 2000 "$@" ;;
compare)
  "$PROBE" compare "$OUT/$2.json" "$OUT/$3.json" | tee "$OUT/compare-$2-$3.txt" ;;
*) sed -n 2,10p "$0"; exit 2 ;;
esac
