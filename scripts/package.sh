#!/bin/sh
# Build a distributable Riptide.app + DMG. Companion to run.sh (dev launch).
#
#   scripts/package.sh                      # dist/Riptide.app + dist/Riptide-<ver>.dmg
#   VERSION=1.2.0 scripts/package.sh        # set CFBundleShortVersionString
#   NOTARY_PROFILE=riptide scripts/package.sh   # also notarize + staple
#
# One-time setup for notarization:
#   xcrun notarytool store-credentials riptide --apple-id <id> --team-id YWM9Q6F35V
#
# mpv/ffmpeg are linked statically, so the bundle is the one executable plus
# an Info.plist plus the app icon (see assets/icon/).
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD)"
APP=dist/Riptide.app
# $RIPTIDE_DEVELOPER_ID, else the first valid Developer ID Application cert in the Keychain.
IDENTITY="${RIPTIDE_DEVELOPER_ID:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ {print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "no Developer ID Application certificate in the Keychain" >&2; exit 1; }

swift build -c release

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RiptideApp "$APP/Contents/MacOS/"
# Icon: the Icon Composer package gives Tahoe its glass/dark/tinted variants;
# AppIcon.icns (assets/icon/build.sh) is the flat fallback.
if [ -d assets/icon/Riptide.icon ]; then
  xcrun actool --compile "$APP/Contents/Resources" --app-icon Riptide --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$(mktemp)" assets/icon/Riptide.icon >/dev/null
  ICON=Riptide
else
  cp assets/AppIcon.icns "$APP/Contents/Resources/"; ICON=AppIcon
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>RiptideApp</string>
  <key>CFBundleIdentifier</key><string>com.northlab.riptide</string>
  <key>CFBundleName</key><string>Riptide</string>
  <key>CFBundleDisplayName</key><string>Riptide</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>$ICON</string>
  <key>CFBundleIconName</key><string>$ICON</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

codesign --force --options runtime --timestamp --entitlements scripts/Riptide.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/notarize.zip
fi

hdiutil create -quiet -volname Riptide -srcfolder "$APP" -ov "dist/Riptide-$VERSION.dmg"
echo "built dist/Riptide-$VERSION.dmg (v$VERSION build $BUILD)"
