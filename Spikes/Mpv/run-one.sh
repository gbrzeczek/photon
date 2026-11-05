#!/bin/bash
# One bounded run of mpv-spike that refuses to start while the sibling's lock exists.
# Usage: LOCK=<file> run-one.sh <seconds> <mpv-spike args...>
HERE="$(cd "$(dirname "$0")" && pwd)"
SECS="$1"; shift
if [ -n "${LOCK:-}" ] && [ -e "$LOCK" ]; then echo LOCKED; exit 75; fi
perl -e 'alarm shift; exec @ARGV' "$SECS" "$HERE/.build/out/Products/Release/mpv-spike" "$@" ${LOCK:+--lock "$LOCK"}
