#!/usr/bin/env bash
# Builds a distributable build/AudIO-<version>.dmg: the app with the driver bundled inside.
# Signed with the self-signed "AudIO Code Signing" certificate when available (see
# scripts/signing.sh), ad-hoc otherwise. Either way it isn't notarized – recipients allow it
# once under System Settings › Privacy & Security › "Open Anyway" (see README).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION=release scripts/app.sh build

version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
staging="build/dmg"
dmg="build/AudIO-$version.dmg"

rm -rf "$staging" "$dmg"
mkdir -p "$staging"
cp -R build/AudIO.app "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "AudIO $version" -srcfolder "$staging" -format UDZO -ov "$dmg" >/dev/null
rm -rf "$staging"
echo "Created $dmg"
