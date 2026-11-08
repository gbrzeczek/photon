#!/bin/bash
# Attaches and detaches one disk image for RemovableMediaUITests, whose runner is sandboxed and can't.
# It only acts on the image path it's given, found in `hdiutil info`, and refuses anything that isn't
# a disk image file. Stop it with Ctrl-C.
#
# Usage: removable-media-helper.sh <image.dmg>
set -uo pipefail
IMAGE="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
[ -f "$IMAGE" ] || { echo "No such image: $IMAGE"; exit 1; }
case "$IMAGE" in /Volumes/*) echo "Refusing an image on a mounted drive."; exit 1 ;; esac

BOX="$HOME/Library/Containers/app.photon.PhotonUITests.xctrunner/Data/tmp"
mkdir -p "$BOX"

device() {
  python3 - "$IMAGE" <<'PY'
import plistlib, subprocess, sys
info = plistlib.loads(subprocess.check_output(["hdiutil", "info", "-plist"]))
for image in info.get("images", []):
    if image.get("image-path") == sys.argv[1]:
        print(min((e["dev-entry"] for e in image.get("system-entities", []) if "dev-entry" in e), key=len))
PY
}

echo "Serving $IMAGE"
while true; do
  if [ -f "$BOX/photon-image-command" ]; then
    command=$(cat "$BOX/photon-image-command")
    case "$command" in
      attach) [ -n "$(device)" ] || hdiutil attach -nobrowse -quiet "$IMAGE" 2>/dev/null ;;
      detach) d=$(device); [ -z "$d" ] || hdiutil detach "$d" -quiet ;;
      force) d=$(device); [ -z "$d" ] || hdiutil detach "$d" -force -quiet ;;
    esac
    if [ -n "$(device)" ]; then echo attached; else echo detached; fi > "$BOX/photon-image-state"
    rm -f "$BOX/photon-image-command"
  fi
  sleep 0.1
done
