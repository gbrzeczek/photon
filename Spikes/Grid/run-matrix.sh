#!/bin/bash
# Runs every backend and layout. Puts a floating window on screen for about 2 minutes.
# Usage: run-matrix.sh <output-prefix> [runs] [extra grid-spike args]
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?output prefix}"; RUNS="${2:-1}"; shift; shift
caffeinate -d -u -w $$ &
sleep 1
for run in $(seq 1 "$RUNS"); do
  for backend in collection layer; do
    for layout in square justified; do
      "$HERE/.build/release/grid-spike" --backend $backend --layout $layout --out "$OUT.jsonl" "$@"
      sleep 1
    done
  done
done
