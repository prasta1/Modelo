#!/bin/bash
# Rebuild a signed Release and install it. Run this every ~7 days (free
# personal-team profiles expire weekly) or after any change.
# Relies on Developer.xcconfig (gitignored) for your team + bundle ID.
# See AGENTS.md "Build, test, validate & install" for rationale.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=$(security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject | sed -n 's/.*OU *= *\([^,/]*\).*/\1/p')
[ -n "$TEAM_ID" ] || { echo "No Apple Development certificate found"; exit 1; }

xcodegen generate
xcodebuild -project Modelo.xcodeproj -scheme Modelo -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build-release build \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" \
  | grep -E 'error:|warning:|BUILD' || true

APP=build-release/Build/Products/Release/Modelo.app
[ -d "$APP" ] || { echo "Build product missing"; exit 1; }
codesign --verify "$APP"

osascript -e 'tell application "Modelo" to quit' 2>/dev/null || true
sleep 1
rm -rf /Applications/Modelo.app
cp -R "$APP" /Applications/
codesign --verify /Applications/Modelo.app
open /Applications/Modelo.app

# When the fresh profile lapses and the app stops launching with
# "Launchd job spawn failed" (POSIX 163), just re-run this script.
security cms -D -i /Applications/Modelo.app/Contents/embedded.provisionprofile 2>/dev/null \
  | plutil -extract ExpirationDate raw -o - - | sed 's/^/Profile expires: /'