#!/bin/bash
# Spike 4 on scratch exFAT images. These numbers validate the tool and show CPU cost per file.
# They are NOT real drive numbers. Usage: run-image-bench.sh <scratch-dir> [photo-count] [enum-count]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/.build/release/throughput"
WORK="${1:?scratch dir}"; PHOTOS="${2:-1500}"; ENUM="${3:-100000}"
mkdir -p "$WORK"
attach() { hdiutil attach -nobrowse -owners on "$1" 2>/dev/null | tail -1 | sed -E 's#.*(/Volumes/.*)$#\1#'; }

img="$WORK/lib.sparseimage"
if [ ! -f "$img" ]; then
  hdiutil create -quiet -size 12g -fs ExFAT -volname PTHRU -type SPARSE -layout MBRSPUD "$img"
  m=$(attach "$img"); "$BIN" generate "$m" "$PHOTOS"; du -sh "$m"; hdiutil detach "$m" -quiet; sleep 1
fi
run() { # Fresh mount per stage, so that nothing is left in the unified buffer cache.
  m=$(attach "$img"); "$BIN" bench "$m" "$@" --allow-writable; hdiutil detach "$m" -quiet; sleep 1
}
for s in enumerate enumerate-fm; do run $s; done
for order in dir fileid random; do run hash --files "$PHOTOS" --order $order; done
for j in 1 2 4 8; do run metadata --files "$PHOTOS" --jobs $j; done
for j in 1 2 4 8; do run thumb-embedded --files "$PHOTOS" --jobs $j; done
for j in 1 2 4 8; do run thumb-full --files "$PHOTOS" --jobs $j --seconds 60; done

big="$WORK/enum.sparseimage"
if [ ! -f "$big" ]; then
  hdiutil create -quiet -size 2g -fs ExFAT -volname PENUM -type SPARSE -layout MBRSPUD "$big"
  m=$(attach "$big")
  python3 - "$m" "$ENUM" <<'PY'
import os, sys
root, n = sys.argv[1], int(sys.argv[2])
for i in range(n):
    d = f"{root}/DCIM/{100 + i // 500}PHOTO"
    if i % 500 == 0: os.makedirs(d)
    open(f"{d}/IMG_{i:06d}.JPG", "wb").close()
PY
  hdiutil detach "$m" -quiet; sleep 1
fi
for s in enumerate enumerate enumerate-fm; do m=$(attach "$big"); "$BIN" bench "$m" $s --allow-writable; hdiutil detach "$m" -quiet; sleep 1; done
