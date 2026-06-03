#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="$ROOT/.build/xcode-derived"
xcodebuild \
    -project "$ROOT/NuValidator.xcodeproj" \
    -scheme NuValidator \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build

APP="$ROOT/.build/NuValidator.app"
rm -rf "$APP"
cp -R "$DERIVED_DATA/Build/Products/Release/NuValidator.app" "$APP"

echo "$APP"
