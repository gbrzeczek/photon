#!/bin/bash
# Builds Photon.app for release, signs it with the self-signed certificate, and packs it in a
# signed DMG. The release workflow runs this, and it runs the same way on a Mac.
#
# Usage: build-dmg.sh --identity <sha1> --build-number <n> --output <dir> [--keychain <path>]
#
#   --identity      SHA-1 fingerprint of the signing certificate. Ad-hoc signing ("-") is refused,
#                   because permissions such as removable-volume access are lost on each build.
#   --build-number  CFBundleVersion. Must grow with every release.
#   --output        Where Photon-<version>.dmg and its .sha256 are written.
#   --keychain      Keychain that holds the identity, if it isn't in the search list.
#
# Prints the version and the DMG's path as `version=` and `dmg=` lines, for the workflow.
set -euo pipefail

IDENTITY="" BUILD_NUMBER="" OUTPUT="" KEYCHAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) IDENTITY="${2:?}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:?}"; shift 2 ;;
    --output) OUTPUT="${2:?}"; shift 2 ;;
    --keychain) KEYCHAIN="${2:?}"; shift 2 ;;
    *) echo "error: unknown argument $1" >&2; exit 64 ;;
  esac
done
if [ -z "$IDENTITY" ] || [ -z "$BUILD_NUMBER" ] || [ -z "$OUTPUT" ]; then
  echo "usage: build-dmg.sh --identity <sha1> --build-number <n> --output <dir> [--keychain <path>]" >&2
  exit 64
fi
if ! [[ "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "error: --identity must be a certificate's SHA-1 fingerprint. Ad-hoc signing isn't used." >&2
  exit 64
fi
if ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --build-number must be a positive integer." >&2
  exit 64
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KEYCHAIN_ARGS=()
[ -n "$KEYCHAIN" ] && KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")

MARKETING_VERSION="$(xcodebuild -project "$ROOT/Photon.xcodeproj" -scheme Photon -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *MARKETING_VERSION = / { print $2; exit }')"
if [ -z "$MARKETING_VERSION" ]; then
  echo "error: couldn't read MARKETING_VERSION from the project." >&2
  exit 1
fi
VERSION="$MARKETING_VERSION.$BUILD_NUMBER"

# Xcode doesn't sign: a self-signed certificate isn't trusted on the build machine, and codesign
# accepts it when given the fingerprint and keychain. Building for the generic destination makes a
# universal binary, for Apple silicon and Intel Macs.
echo "Building Photon $VERSION"
xcodebuild build \
  -project "$ROOT/Photon.xcodeproj" \
  -scheme Photon \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$WORK/DerivedData" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet

APP="$WORK/DerivedData/Build/Products/Release/Photon.app"
if [ ! -d "$APP" ]; then
  echo "error: the build didn't produce $APP." >&2
  exit 1
fi

# Sign nested code first, deepest first, then the app itself. --deep is avoided, as Apple advises.
echo "Signing with $IDENTITY"
sign() {
  # The odd expansion keeps macOS's bash 3.2 from calling an empty array unbound.
  codesign --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --timestamp=none "$@"
}
while IFS= read -r nested; do
  sign "$nested"
done < <(find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \
  -o -name '*.appex' -o -name '*.app' \) -print)
sign "$APP"

codesign --verify --strict --deep --verbose=2 "$APP"
# A self-signed certificate gives a designated requirement of bundle identifier plus certificate,
# which stays the same across builds. A cdhash requirement would mean the signing went wrong.
REQUIREMENT="$(codesign --display --requirements - "$APP" 2>&1)"
echo "$REQUIREMENT"
if ! grep -q 'certificate leaf' <<< "$REQUIREMENT" || grep -q 'cdhash' <<< "$REQUIREMENT"; then
  echo "error: the designated requirement isn't tied to the certificate." >&2
  exit 1
fi
for arch in arm64 x86_64; do
  if ! lipo -archs "$APP/Contents/MacOS/Photon" | grep -qw "$arch"; then
    echo "error: Photon.app has no $arch slice." >&2
    exit 1
  fi
done
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [ "$PLIST_VERSION" != "$BUILD_NUMBER" ]; then
  echo "error: CFBundleVersion is $PLIST_VERSION, not $BUILD_NUMBER." >&2
  exit 1
fi

# The DMG holds the app and a link to Applications, for dragging across.
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Photon.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUTPUT/Photon-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Photon $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
sign "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
hdiutil verify "$DMG" >/dev/null
(cd "$OUTPUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "version=$VERSION"
echo "dmg=$DMG"
