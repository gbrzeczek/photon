#!/bin/bash
# Xcode build phase for Photon.app: copies Photon's own libmpv build from Vendor/mpv into the app's
# Frameworks folder, and its licenses into Resources.
#
# A checkout without it still builds, and the app has no fallback for MKV, WebM, AVI and the rest:
# PhotonVideo loads libmpv at run time and leaves the fallback out when it isn't there. Run
# scripts/mpv/build.sh to make it. A release requires it, and build-dmg.sh checks.
set -euo pipefail

SOURCE="${SRCROOT:?}/Vendor/mpv"
FRAMEWORKS="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
LICENSES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Licenses/libmpv"

if [ ! -f "$SOURCE/lib/libmpv.2.dylib" ]; then
    echo "warning: No libmpv in Vendor/mpv, so this build has no video fallback. Run scripts/mpv/build.sh."
    exit 0
fi

mkdir -p "$FRAMEWORKS" "$LICENSES"
for dylib in "$SOURCE"/lib/*.dylib; do
    ditto "$dylib" "$FRAMEWORKS/$(basename "$dylib")"
done
ditto "$SOURCE/LICENSES" "$LICENSES"
cp "$SOURCE/manifest.txt" "$LICENSES/manifest.txt"

# A local build signs them as Xcode signs the app. A release build has signing off here, and
# build-dmg.sh signs them with the certificate, inside out.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    for dylib in "$FRAMEWORKS"/*.dylib; do
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$dylib"
    done
fi
