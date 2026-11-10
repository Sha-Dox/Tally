#!/bin/zsh
# Builds a distributable Tally-<version>.zip in build/ without installing.
# Signs ad-hoc by default; set SIGN_IDENTITY to a "Developer ID Application"
# identity (and notarize the zip) before sharing it outside this Mac.
set -euo pipefail
cd "${0:A:h}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

APP=build/Tally.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Tally" "$APP/Contents/MacOS/Tally"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" --timestamp=none "$APP"
codesign --verify --strict "$APP"

ZIP="build/Tally-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP"
