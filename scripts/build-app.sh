#!/bin/zsh
# Build "Xcode Tailscale Bridge.app" into ./build.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "${0:A:h}/.."

config=${1:-release}
app="build/Xcode Tailscale Bridge.app"

swift build -c "$config"
bin=$(swift build -c "$config" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/XcodeTailscaleBridge" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
codesign --force --sign - "$app"

echo "Built $app"
