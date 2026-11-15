#!/bin/bash
# Makes the README's screenshots, in light and dark, from drawn landscapes rather than real photos.
#
#   scripts/screenshots/make.sh [<app>] [<output folder>]
#
# <app> defaults to a Release build made here, and <output folder> to docs/screenshots. The library and
# its media go in a temporary folder on the internal disk, and nothing touches the user's own library,
# settings or drives: PHOTON_LIBRARY points the app at the temporary library, which also gives it a
# settings domain of its own. The screen must be unlocked, because each shot is a capture of the window.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${2:-$ROOT/docs/screenshots}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/photon-screenshots.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${1:-}" ]; then
    APP="$1"
else
    xcodebuild build -project "$ROOT/Photon.xcodeproj" -scheme Photon -configuration Release \
        -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath "$WORK/build" -quiet
    APP="$WORK/build/Build/Products/Release/Photon.app"
fi
BINARY="$APP/Contents/MacOS/Photon"

swift build --package-path "$ROOT/Packages/PhotonKit" -c release --product photon-index -q
INDEX="$ROOT/Packages/PhotonKit/.build/release/photon-index"

mkdir -p "$WORK/library" "$WORK/empty" "$OUT"
"$INDEX" showcase "$WORK/Photos" --count 120 >/dev/null
"$INDEX" scan "$WORK/Photos" --database "$WORK/library/Library.sqlite" >/dev/null
"$INDEX" thumbnails "$WORK/Photos" --database "$WORK/library/Library.sqlite" >/dev/null

# One shot: a name, a library, then any PHOTON_ settings for it.
shoot() {
    local name="$1" library="$2"
    shift 2
    for appearance in light dark; do
        env PHOTON_LIBRARY="$library" PHOTON_RESET_SETTINGS=1 PHOTON_NO_VIEWER_RESTORE=1 \
            PHOTON_APPEARANCE="$appearance" PHOTON_SNAPSHOT="$OUT/$name-$appearance.png" \
            PHOTON_SNAPSHOT_DELAY="${DELAY:-4}" PHOTON_SNAPSHOT_QUIT=1 "$@" "$BINARY" >/dev/null
        # A full Retina window is more than a README needs. Smaller windows stay as they are.
        local width
        width=$(sips -g pixelWidth "$OUT/$name-$appearance.png" | awk '/pixelWidth/ { print $2 }')
        if [ "${width:-0}" -gt 1440 ]; then sips --resampleWidth 1440 "$OUT/$name-$appearance.png" >/dev/null; fi
        echo "$OUT/$name-$appearance.png"
    done
}

LIBRARY="$WORK/library/Library.sqlite"
shoot grid "$LIBRARY"
shoot viewer "$LIBRARY" PHOTON_VIEWER_ROW=14
shoot welcome "$WORK/empty/Library.sqlite"
shoot settings "$LIBRARY" PHOTON_OPEN_WINDOW=settings
shoot shortcuts "$LIBRARY" PHOTON_OPEN_WINDOW=keyboard-shortcuts
if [ -n "${ALL:-}" ]; then
    # Only for looking at, with ALL=1. The README doesn't show them.
    shoot storage "$LIBRARY" PHOTON_OPEN_WINDOW=storage
    shoot acknowledgements "$LIBRARY" PHOTON_OPEN_WINDOW=acknowledgements
fi
