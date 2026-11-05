#!/bin/bash
# Spike 3 on disk images only. Creates its own images in a scratch directory on the internal
# disk and never touches a real volume. Usage: run-image-tests.sh <scratch-dir> [fs ...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/.build/release/volume-probe"
WORK="${1:?scratch dir}"; shift
FILESYSTEMS=("$@"); [ ${#FILESYSTEMS[@]} -eq 0 ] && FILESYSTEMS=(ExFAT "MS-DOS FAT32" HFS+ APFS)
mkdir -p "$WORK"

attach() { hdiutil attach -nobrowse "$1" | tail -1 | sed -E 's#.*(/Volumes/.*)$#\1#'; }
detach() { hdiutil detach "$1" -quiet || hdiutil detach "$1" -force -quiet; }
section() { echo; echo "### $*"; }
compare() { "$PROBE" compare "$1" "$2"; }

for fs in "${FILESYSTEMS[@]}"; do
  tag=$(echo "$fs" | tr -cd 'A-Za-z0-9')
  label="PTEST$tag"; label=${label:0:11}
  img="$WORK/$tag.dmg"; rm -f "$img"
  echo; echo "========== $fs =========="
  hdiutil create -quiet -size 256m -fs "$fs" -volname "$label" -layout MBRSPUD "$img" 2>/dev/null \
    || hdiutil create -quiet -size 256m -fs "$fs" -volname "$label" "$img"
  m=$(attach "$img")
  mkdir -p "$m/DCIM/100CANON" "$m/DCIM/101CANON"
  for i in $(seq 1 40); do head -c $((4096 * (i + 1))) /dev/urandom > "$m/DCIM/100CANON/IMG_$(printf %04d $i).JPG"; done
  cp "$m/DCIM/100CANON/IMG_0001.JPG" "$m/DCIM/101CANON/COPY.JPG"
  sync
  "$PROBE" snapshot "$m" "$WORK/$tag-0.json"
  detach "$m"; sleep 1

  section "$fs: remount"
  m=$(attach "$img"); "$PROBE" snapshot "$m" "$WORK/$tag-1.json" >/dev/null
  compare "$WORK/$tag-0.json" "$WORK/$tag-1.json"

  section "$fs: file IDs through file operations (each compared with the state before it)"
  d="$m/DCIM/100CANON"
  id() { stat -f %i "$1"; }
  a=$(id "$d/IMG_0002.JPG"); mv "$d/IMG_0002.JPG" "$d/RENAMED.JPG"; b=$(id "$d/RENAMED.JPG"); echo "rename in same directory: $a -> $b"
  a=$(id "$d/IMG_0003.JPG"); mv "$d/IMG_0003.JPG" "$m/DCIM/101CANON/MOVED.JPG"; b=$(id "$m/DCIM/101CANON/MOVED.JPG"); echo "move across directories: $a -> $b"
  a=$(id "$d/IMG_0004.JPG"); dd if=/dev/urandom of="$d/IMG_0004.JPG" bs=4096 count=1 conv=notrunc 2>/dev/null; b=$(id "$d/IMG_0004.JPG"); echo "overwrite in place: $a -> $b"
  a=$(id "$d/IMG_0005.JPG"); head -c 90000 /dev/urandom > "$d/IMG_0005.tmp"; mv -f "$d/IMG_0005.tmp" "$d/IMG_0005.JPG"; b=$(id "$d/IMG_0005.JPG"); echo "atomic replace, as editors do: $a -> $b"
  a=$(id "$d/IMG_0006.JPG"); rm "$d/IMG_0006.JPG"; head -c 8192 /dev/urandom > "$d/NEWFILE.JPG"; b=$(id "$d/NEWFILE.JPG"); echo "delete, then a different new file: $a -> $b $( [ "$a" = "$b" ] && echo '(ID REUSED by unrelated content)')"
  sync
  "$PROBE" snapshot "$m" "$WORK/$tag-2.json" >/dev/null
  detach "$m"; sleep 1
  m=$(attach "$img"); "$PROBE" snapshot "$m" "$WORK/$tag-3.json" >/dev/null
  a=$(stat -f %i "$m/DCIM/100CANON/RENAMED.JPG"); echo "renamed file after remount: $a"
  a=$(stat -f %i "$m/DCIM/101CANON/MOVED.JPG"); echo "moved file after remount: $a"
  section "$fs: is a file ID reused by unrelated content?"
  # Delete the lowest-numbered files, remount so the allocator restarts, then write new ones.
  d="$m/DCIM/100CANON"
  old=$(stat -f %i "$d"/IMG_0007.JPG "$d"/IMG_0008.JPG "$d"/IMG_0009.JPG | tr '\n' ' ')
  rm "$d"/IMG_0007.JPG "$d"/IMG_0008.JPG "$d"/IMG_0009.JPG; sync
  detach "$m"; sleep 1; m=$(attach "$img"); d="$m/DCIM/100CANON"
  for n in 1 2 3 4 5 6; do head -c 16384 /dev/urandom > "$d/REUSE_$n.JPG"; done; sync
  new=$(stat -f %i "$d"/REUSE_*.JPG | tr '\n' ' ')
  echo "deleted IDs: $old"; echo "new IDs: $new"
  hit=0; for o in $old; do for n in $new; do [ "$o" = "$n" ] && hit=1; done; done
  [ $hit = 1 ] && echo "RESULT: ID reused by unrelated content" || echo "RESULT: no reuse seen"
  sync; "$PROBE" snapshot "$m" "$WORK/$tag-2.json" >/dev/null
  detach "$m"; sleep 1
  m=$(attach "$img"); "$PROBE" snapshot "$m" "$WORK/$tag-3.json" >/dev/null
  section "$fs: remount after edits"
  compare "$WORK/$tag-2.json" "$WORK/$tag-3.json"
  detach "$m"; sleep 1

  section "$fs: byte-for-byte clone mounted beside the original (a cloned drive)"
  cp "$img" "$WORK/$tag-clone.dmg"
  m=$(attach "$img"); c=$(attach "$WORK/$tag-clone.dmg")
  echo "original at $m, clone at ${c:-NOT MOUNTED}"
  "$PROBE" snapshot "$m" "$WORK/$tag-4.json" >/dev/null
  if [ -n "$c" ] && [ -d "$c" ]; then
    "$PROBE" snapshot "$c" "$WORK/$tag-5.json" >/dev/null
    compare "$WORK/$tag-4.json" "$WORK/$tag-5.json"
    detach "$c"
  fi
  detach "$m"; sleep 1; rm -f "$WORK/$tag-clone.dmg"

  section "$fs: reformat with the same name"
  m=$(attach "$img")
  dev=$(diskutil info "$m" | awk -F': *' '/Device Node/{print $2}')
  if [ "$fs" = "APFS" ]; then
    echo "skipped: APFS reformat is per-container"
  else
    case "$fs" in ExFAT) f=ExFAT;; HFS+) f=HFS+;; *) f="MS-DOS FAT32";; esac
    diskutil eraseVolume "$f" "$label" "$dev" >/dev/null
    sleep 1
    mkdir -p "/Volumes/$label/DCIM"; head -c 8192 /dev/urandom > "/Volumes/$label/DCIM/A.JPG"; sync
    "$PROBE" snapshot "/Volumes/$label" "$WORK/$tag-6.json" >/dev/null
    compare "$WORK/$tag-4.json" "$WORK/$tag-6.json" | head -3
    m="/Volumes/$label"
  fi
  detach "$m"; sleep 1

  section "$fs: read-only mount"
  if [ "$fs" = "APFS" ]; then echo "skipped: APFS mounts through a synthesized container disk"; continue; fi
  dev=$(hdiutil attach -nobrowse -nomount "$img" | head -1 | awk '{print $1}')
  # MBR images have a partition; mount it when present.
  part=$(diskutil list "$dev" | awk '/s1$/{print $NF}' | head -1); part=${part:-${dev#/dev/}}
  diskutil mount readOnly "/dev/$part" >/dev/null 2>&1 || diskutil mount readOnly "$dev" >/dev/null
  m=$(diskutil info "/dev/$part" | awk -F': *' '/Mount Point/{print $2}')
  "$PROBE" snapshot "$m" "$WORK/$tag-7.json" >/dev/null
  grep '"isReadOnly"' "$WORK/$tag-7.json"
  touch "$m/x" 2>&1 | head -1
  hdiutil detach "$dev" -quiet
  sleep 1
done
echo; echo "done"
