#!/bin/bash
# Packages the macOS app as build/Mneme.app: release build, Info.plist with the microphone usage text,
# ad-hoc signature for this Mac, then the offscreen smoke test from inside the bundle.
# Usage: bash Scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== release build of the app"
swift build -c release --product MnemeApp
BIN_DIR=$(swift build -c release --show-bin-path)

APP=build/Mneme.app
VERSION=$(sed -n 's/.*version: "\([0-9][0-9.]*\)".*/\1/p' Sources/MnemeCLI/MnemeCommand.swift | head -n 1)
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=$(date +%Y%m%d%H%M)

echo "== assembling $APP (version $VERSION, build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MnemeApp" "$APP/Contents/MacOS/Mneme"
chmod 755 "$APP/Contents/MacOS/Mneme"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Mneme</string>
    <key>CFBundleExecutable</key>
    <string>Mneme</string>
    <key>CFBundleIdentifier</key>
    <string>local.mneme.Mneme</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Mneme</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Mneme records your voice notes. Recordings are stored and transcribed on this Mac only.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

# SwiftPM resource bundles would need extra handling inside an app bundle; none are expected.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  echo "warning: resource bundle $(basename "$bundle") exists in the build folder and is not packaged"
done

echo "== signing (ad hoc, for this Mac)"
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "== smoke test from the bundle"
"$APP/Contents/MacOS/Mneme" --smoke-test

echo "BUILD APP: OK  $(pwd)/$APP"
