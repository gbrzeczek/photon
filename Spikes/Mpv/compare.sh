#!/bin/bash
# Compares window captures against frames decoded independently by Homebrew ffmpeg.
# Each frame carries its own noise, so SSIM peaks sharply on the true frame. Time-to-index mapping
# varies by container, so this sweeps +/-2 frames and reports the best match and its offset.
# The frame one second away is a negative control: a real match must beat it clearly.
# Usage: compare.sh <clips-dir> <run-dir>   (run-dir holds results.jsonl and captures)
CLIPS="$1"; RUN="$2"; TMP="$(mktemp -d)"
ssim() { ffmpeg -nostdin -hide_banner -nostats -i "$1" -i "$2" -lavfi "[0:v]format=gray[a];[1:v]format=gray[b];[a][b]ssim" -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p'; }
python3 -I -c '
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r.get("ok"):
        rd=r.get("rendered"); print(r["clip"], r["pausedAt"], r["play"]["container-fps"], r["screenCapture"], rd["file"] if isinstance(rd,dict) else "-")
' "$RUN/results.jsonl" | while read -r clip t fps shot rendered; do
  n=$(python3 -I -c "print(round($t*$fps))"); f=$(python3 -I -c "print(int(round($fps)))")
  w=$(( $(python3 -I -c "print(1 if $t<8 else 0)") == 1 ? n + f : n - f ))
  rm -f "$TMP"/*.png
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$CLIPS/$clip" -vf "select=between(n\,$((n > 2 ? n - 2 : 0))\,$((n + 2))),scale=2560:1440:flags=bicubic" -fps_mode passthrough -frames:v 5 "$TMP/c%d.png"
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$CLIPS/$clip" -vf "select=eq(n\,$w),scale=2560:1440:flags=bicubic" -fps_mode passthrough -frames:v 1 "$TMP/wrong.png"
  best=0; off=?; i=0
  for c in "$TMP"/c?.png; do
    v=$(ssim "$RUN/$shot" "$c"); o=$((i - (n > 2 ? 2 : n)))
    if python3 -I -c "exit(0 if $v>$best else 1)"; then best=$v; off=$o; bestf=$c; fi
    i=$((i + 1))
  done
  b=$(ssim "$RUN/$shot" "$TMP/wrong.png"); c="-"
  [ "$rendered" != "-" ] && c=$(ssim "$RUN/$rendered" "$bestf")
  printf "%-22s frame=%-4s best-offset=%-3s screen-vs-ref=%-9s screen-vs-wrong=%-9s readback-vs-ref=%s\n" "$clip" "$n" "$off" "$best" "$b" "$c"
done
rm -rf "$TMP"
