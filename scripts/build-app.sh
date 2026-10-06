#!/bin/zsh
# Build "Xcode Tailscale Bridge.app" into ./build with the Xcode project.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "${0:A:h}/.."

config=${(C)${1:-release}}
app="build/Xcode Tailscale Bridge.app"

# xcodebuild needs Xcode, not just the Command Line Tools.
if [[ -z ${DEVELOPER_DIR:-} && $(xcode-select -p) == */CommandLineTools ]]; then
  xcode=(/Applications/Xcode*.app(N))
  (( ${#xcode} )) || { echo "Xcode not found in /Applications" >&2; exit 1; }
  export DEVELOPER_DIR="${xcode[1]}/Contents/Developer"
fi

xcodebuild -quiet -project XcodeTailscaleBridge.xcodeproj -scheme XcodeTailscaleBridge \
  -configuration "$config" -destination "generic/platform=macOS" -derivedDataPath build/DerivedData build

rm -rf "$app"
ditto "build/DerivedData/Build/Products/$config/Xcode Tailscale Bridge.app" "$app"

echo "Built $app"
