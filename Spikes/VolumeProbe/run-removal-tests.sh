#!/bin/bash
# Spike 3, removal on disk images. `hdiutil detach -force` is a stand-in for a pulled cable: it
# shows the process-level outcome, not the delays of a real USB failure.
# Usage: run-removal-tests.sh <scratch-dir> [fs]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/.build/release/volume-probe"
WORK="${1:?scratch dir}"; FS="${2:-ExFAT}"
mkdir -p "$WORK"
tag=$(echo "$FS" | tr -cd 'A-Za-z0-9'); img="$WORK/rm-$tag.dmg"
rm -f "$img"
hdiutil create -quiet -size 900m -fs "$FS" -volname PTESTRM -layout MBRSPUD "$img" 2>/dev/null || hdiutil create -quiet -size 900m -fs "$FS" -volname PTESTRM "$img"
m=$(hdiutil attach -nobrowse "$img" | tail -1 | sed -E 's#.*(/Volumes/.*)$#\1#')
head -c $((600*1024*1024)) /dev/urandom > "$m/big.bin"
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=6000x4000:d=0.04" -frames:v 1 -q:v 2 "$m/big.jpg"
ls -l "$m"
hdiutil detach "$m" -quiet

for mode in read mapped imagesource; do
  file=big.bin; [ "$mode" = imagesource ] && file=big.jpg
  echo; echo "### force detach under mode=$mode file=$file ($FS)"
  # A fresh mount, so that the page cache holds nothing for this file.
  m=$(hdiutil attach -nobrowse "$img" | tail -1 | sed -E 's#.*(/Volumes/.*)$#\1#')
  fifo="$WORK/in.$mode"; rm -f "$fifo"; mkfifo "$fifo"
  "$PROBE" read-across-removal "$m/$file" "$mode" < "$fifo" > "$WORK/out.$mode" 2>&1 &
  pid=$!
  exec 9>"$fifo"
  for _ in $(seq 1 100); do grep -q READY "$WORK/out.$mode" && break; sleep 0.05; done
  start=$(python3 -c 'import time;print(time.time())')
  hdiutil detach "$m" -force -quiet; detach=$?
  echo "detach exit $detach, took $(python3 -c "import time;print(round(time.time()-$start,3))")s"
  echo go >&9; exec 9>&-
  for _ in $(seq 1 200); do kill -0 $pid 2>/dev/null || break; sleep 0.05; done
  if kill -0 $pid 2>/dev/null; then echo "PROCESS HUNG after 10s"; kill -9 $pid; fi
  wait $pid; status=$?
  cat "$WORK/out.$mode"
  echo "child exit status $status$( [ $status -gt 128 ] && echo " (signal $((status-128)))")"
done

for mode in close hold; do
  echo; echo "### polite eject with an open handle, handle policy=$mode ($FS)"
  m=$(hdiutil attach -nobrowse "$img" | tail -1 | sed -E 's#.*(/Volumes/.*)$#\1#')
  "$PROBE" watch-unmount "$m/big.bin" "$mode" > "$WORK/out.watch" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do grep -q READY "$WORK/out.watch" && break; sleep 0.05; done
  sleep 0.5
  diskutil unmount "$m" 2>&1 | tail -1; echo "diskutil exit ${PIPESTATUS[0]}"
  sleep 1
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  cat "$WORK/out.watch"
  if [ -d "$m" ] && mount | grep -q "$m"; then hdiutil detach "$m" -force -quiet; fi
done
rm -f "$img"
