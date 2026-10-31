#!/bin/bash
# Build RiptideTV for the tvOS simulator and launch it. Set RIPTIDE_TV_TEAM for signing.
set -euo pipefail
DEV="Apple TV 4K (3rd generation)"
cd "$(dirname "$0")/../RiptideTV"
xcodegen generate --quiet
xcodebuild -project RiptideTV.xcodeproj -scheme RiptideTV \
  -destination "platform=tvOS Simulator,name=$DEV" -derivedDataPath build \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" | tail -5
xcrun simctl boot "$DEV" 2>/dev/null || true
open -a Simulator 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl install booted build/Build/Products/Debug-appletvsimulator/RiptideTV.app
xcrun simctl launch booted com.northlab.riptide.tv
