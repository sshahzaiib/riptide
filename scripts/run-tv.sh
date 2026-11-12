#!/bin/bash
# Build RiptideTV for the tvOS simulator and launch it.
#
# The team is pinned to a constant placeholder on purpose: the simulator keys
# Keychain items by "<team>.<bundle id>". Left empty, Xcode fills the prefix in
# from whatever code-signing-capable certificate it finds in the login
# keychain, so the prefix changes when certificates do and the saved tokens
# vanish. Simulator only; device builds use RIPTIDE_TV_TEAM via project.yml.
set -euo pipefail
DEV="Apple TV 4K (3rd generation)"
cd "$(dirname "$0")/../RiptideTV"
xcodegen generate --quiet
xcodebuild -project RiptideTV.xcodeproj -scheme RiptideTV \
  -destination "platform=tvOS Simulator,name=$DEV" -derivedDataPath build \
  build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="RIPTIDESIM" | tail -5
xcrun simctl boot "$DEV" 2>/dev/null || true
open -a Simulator 2>/dev/null || open -a DeviceHub 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl install booted build/Build/Products/Debug-appletvsimulator/RiptideTV.app
xcrun simctl launch booted com.northlab.riptide.tv
