#!/bin/bash
# Spike 3 on a real drive. Nothing here writes to the volume. Results stay in
# ~/PhotonSpikeResults, because they contain file names and must not be committed.
#
#   real-media.sh snapshot <mount> <label> [folder...]   Record identity. Run, reconnect, run again.
#   real-media.sh compare <label-a> <label-b>
#   real-media.sh pull <mount> <big-file>    Read loop for pulling the cable. Needs a read-only mount.
#
# Mount read-only first, so that nothing can write to the volume and macOS adds nothing:
#   diskutil unmount <mount>
#   diskutil mount readOnly <device, for example disk5s1>
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
pull)
  if [ "$(diskutil info "$2" | awk -F': *' '/Volume Read-Only/{print $2}' | cut -d' ' -f1)" != "Yes" ]; then
    echo "Refusing: $2 is not mounted read-only. See the top of this script."; exit 1
  fi
  "$PROBE" read-until-error "$3" | tee "$OUT/pull-$(date +%H%M%S).txt" ;;
*) sed -n 2,12p "$0"; exit 2 ;;
esac
