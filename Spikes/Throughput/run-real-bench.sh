#!/bin/bash
# Spike 4 on a real drive. Read-only: every stage refuses a writable mount, and only the folders
# named here are touched. Output has counts and rates, never file names.
# Usage: run-real-bench.sh <mount> <bsd-device> <big-file> <folder>...
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/.build/release/throughput"
MOUNT="$1"; DEV="$2"; BIG="$3"; shift 3
remount() { # Read-only to read-only, never forced, so that stages start cold.
  diskutil unmount "$DEV" >/dev/null || { echo "unmount refused, stopping"; exit 1; }
  sleep 1
  diskutil mount readOnly "$DEV" >/dev/null || { echo "mount failed, stopping"; exit 1; }
  sleep 1
  [ "$(diskutil info "$DEV" | awk -F': *' '/Volume Read-Only/{print $2}' | cut -d' ' -f1)" = Yes ] || { echo "not read-only, stopping"; exit 1; }
}
echo "### device"; remount; "$BIN" device "$BIG" 15
for folder in "$@"; do
  for s in enumerate enumerate-fm; do echo "### $folder cold $s"; remount; "$BIN" bench "$MOUNT/$folder" $s; done
  echo "### $folder warm enumerate"; "$BIN" bench "$MOUNT/$folder" enumerate
done
ROOT="$MOUNT/$1"
for order in dir fileid random; do echo "### hash $order"; remount; "$BIN" bench "$ROOT" hash --files 3000 --order $order --seconds 90; done
for j in 1 4; do echo "### hash jobs $j"; remount; "$BIN" bench "$ROOT" hash --files 3000 --jobs $j --seconds 90; done
for j in 1 2 4 8; do echo "### metadata jobs $j"; remount; "$BIN" bench "$ROOT" metadata --files 3000 --jobs $j --seconds 60; done
for j in 1 2 4 8; do echo "### thumb-embedded jobs $j"; remount; "$BIN" bench "$ROOT" thumb-embedded --files 3000 --jobs $j --seconds 60; done
for j in 1 4 8; do echo "### thumb-full jobs $j"; remount; "$BIN" bench "$ROOT" thumb-full --files 1500 --jobs $j --seconds 60; done
echo "### done"; mount | grep -c "read-only.*fskit\|fskit.*read-only"
