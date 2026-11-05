#!/bin/bash
# Spike 5, the part that needs a person. Disk images aren't gated by TCC, so point this at a real
# SD card or USB drive (it only lists the top directory). Click Allow when macOS asks.
# Usage: verify-persistence.sh <mount-on-real-removable-media>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?mount point of a real removable volume}"
WORK="$HOME/PhotonSpikeResults/signing"; mkdir -p "$WORK"
[ -f "$WORK/cert/sha1.txt" ] || "$HERE/make-cert.sh" "$WORK/cert"
ID=$(cat "$WORK/cert/sha1.txt"); KC="$WORK/cert/spike.keychain-db"
security unlock-keychain -p spike-only "$KC"
LOG="$WORK/probe.log"; : > "$LOG"
BUNDLE=dev.photon.spike.signingprobe
tccutil reset SystemPolicyRemovableVolumes "$BUNDLE" >/dev/null 2>&1 || true

step() { # label, sign identity, keychain, expectation
  mkdir -p "$WORK/$1"
  "$HERE/build-app.sh" "$WORK/$1" "$1" "$2" "${3:-}" >/dev/null 2>&1
  echo; echo ">>> $1: $4"
  open -n -W "$WORK/$1/SigningProbe.app" --args "$TARGET" "$LOG"
  tail -1 "$LOG"
  read -r -p "Did macOS show a permission prompt for this build? [y/n] " answer
  echo "$1: prompted=$answer" >> "$LOG"
}
step self1 "$ID" "$KC" "first self-signed build. Expect a prompt: click Allow."
step self2 "$ID" "$KC" "rebuilt, different binary, same certificate. Expect NO prompt."
step self3 "$ID" "$KC" "rebuilt again. Expect NO prompt."
tccutil reset SystemPolicyRemovableVolumes "$BUNDLE" >/dev/null 2>&1 || true
step adhoc1 adhoc "" "control: ad-hoc build. Expect a prompt: click Allow."
step adhoc2 adhoc "" "control: ad-hoc rebuild. Expect a prompt again if ad-hoc really loses permission."
tccutil reset SystemPolicyRemovableVolumes "$BUNDLE" >/dev/null 2>&1 || true
echo; cat "$LOG"
