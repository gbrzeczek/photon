#!/bin/bash
# Spike 5, the part that needs a person. Disk images aren't gated by TCC, so point this at a real
# USB drive (it only lists the top directory). Click Allow when macOS asks.
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
  before=$(wc -l < "$LOG")
  open -n "$WORK/$1/SigningProbe.app" --args "$TARGET" "$LOG"
  # A pending prompt blocks the probe's opendir, so the logged time shows whether one appeared.
  for _ in $(seq 1 120); do [ "$(wc -l < "$LOG")" -gt "$before" ] && break; sleep 1; done
  if [ "$(wc -l < "$LOG")" -gt "$before" ]; then tail -1 "$LOG"; else echo "no answer after 120 s"; pkill -f SigningProbe; fi
}
step self1 "$ID" "$KC" "first self-signed build. Expect a prompt: click Allow."
step self2 "$ID" "$KC" "rebuilt, different binary, same certificate. Expect NO prompt."
step self3 "$ID" "$KC" "rebuilt again. Expect NO prompt."
tccutil reset SystemPolicyRemovableVolumes "$BUNDLE" >/dev/null 2>&1 || true
step adhoc1 adhoc "" "control: ad-hoc build. Expect a prompt: click Allow."
step adhoc2 adhoc "" "control: ad-hoc rebuild. Expect a prompt again if ad-hoc really loses permission."
tccutil reset SystemPolicyRemovableVolumes "$BUNDLE" >/dev/null 2>&1 || true
echo; cat "$LOG"
