#!/bin/bash
# Builds SigningProbe.app. Usage: build-app.sh <out-dir> <build-label> <adhoc|sha1> [keychain]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$1"; LABEL="$2"; ID="$3"; KC="${4:-}"
APP="$OUT/SigningProbe.app"; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
# The label is compiled in, so every build really is a different binary with a different cdhash.
sed "s/\"?\"/\"$LABEL\"/" "$HERE/Sources/main.swift" > "$OUT/main.swift"
swiftc -O -target arm64-apple-macos15.0 "$OUT/main.swift" -o "$APP/Contents/MacOS/SigningProbe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.photon.spike.signingprobe</string>
<key>CFBundleName</key><string>SigningProbe</string>
<key>CFBundleExecutable</key><string>SigningProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$LABEL</string>
<key>CFBundleVersion</key><string>1</string>
<key>SpikeBuild</key><string>$LABEL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
if [ "$ID" = adhoc ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --keychain "$KC" --sign "$ID" --timestamp=none "$APP"
fi
