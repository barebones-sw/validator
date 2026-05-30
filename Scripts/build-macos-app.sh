#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/vnu-swift-module-cache}"
export CLANG_MODULE_CACHE_PATH

swift build -c release --product vnu-swift

APP="$ROOT/.build/NuValidator.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/vnu-swift" "$APP/Contents/MacOS/vnu-swift"
cp "$ROOT/resources/NuValidator/Info.plist" "$APP/Contents/Info.plist"

echo "$APP"
