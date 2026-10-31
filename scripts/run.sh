#!/bin/sh
# Use this instead of `swift run RiptideApp`.
#
# swift run leaves the binary ad-hoc signed, and the signature hash changes on
# every rebuild — so Keychain's "Always Allow" never sticks and macOS asks for
# the login password on each run. Re-signing with a stable identity keeps the
# designated requirement constant across builds: approve once, never again.
set -e
cd "$(dirname "$0")/.."
swift build "$@"
# Signing identity: $RIPTIDE_SIGN_ID, else the first valid "Apple Development"
# cert in the Keychain (by hash: -v skips revoked duplicates that share a name),
# else ad-hoc (works, but Keychain re-prompts every rebuild).
SIGN_ID="${RIPTIDE_SIGN_ID:-$(security find-identity -v -p codesigning | awk '/"Apple Development/ {print $2; exit}')}"
codesign --force --identifier com.northlab.riptide \
  --sign "${SIGN_ID:--}" \
  .build/debug/RiptideApp
exec .build/debug/RiptideApp
