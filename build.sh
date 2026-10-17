#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:-$HOME/Library/Caches/SoundOffBuild/SoundOff.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCHS="${ARCHS:-$(uname -m)}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soundoff-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
binaries=()
for arch in $ARCHS; do
  case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
  swiftc -O -target "$arch-apple-macos15.0" Sources/*.swift -o "$BUILD_DIR/SoundOff-$arch"
  binaries+=("$BUILD_DIR/SoundOff-$arch")
done
if [ "${#binaries[@]}" -eq 1 ]; then cp "${binaries[0]}" "$APP/Contents/MacOS/SoundOff"; else lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/SoundOff"; fi
cp Info.plist "$APP/Contents/Info.plist"
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier io.github.frankravizza.SoundOff "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s\n' "$APP"
