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
# Cert hash, not name: the name is ambiguous (a revoked duplicate exists).
# "Apple Development: zaibansari20@gmail.com (GSK3AYXNYW)", valid one.
codesign --force --identifier com.northlab.riptide \
  --sign 4C0E315942792A22B816A1228C4866640AEB3E65 \
  .build/debug/RiptideApp
exec .build/debug/RiptideApp
