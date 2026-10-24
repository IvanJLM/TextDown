#!/bin/zsh
# Builds a signed Release copy of TextDown and zips it for another Mac.
# Usage: ./scripts/package.sh   ->   dist/TextDown-<version>.zip
# On the other Mac: unzip, move TextDown.app to /Applications and open it once;
# it offers to become the default app for Markdown and text.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

IDENTITY="${TEXTDOWN_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"/ { print $2; exit }')
fi

xcodegen generate --quiet
xcodebuild -project TextDown.xcodeproj -scheme TextDown -configuration Release \
  -derivedDataPath build/DD -quiet build

APP="build/DD/Build/Products/Release/TextDown.app"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/TextDown-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"
