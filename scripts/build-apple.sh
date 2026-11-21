#!/usr/bin/env bash
# Generate the Xcode project and build the iOS app (which embeds the watch app).
#   ./scripts/build-apple.sh            simulator build, no signing (CI and quick checks)
#   ./scripts/build-apple.sh device     signed build for a real iPhone, registers profiles if needed
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/apple"
xcodegen generate --quiet

common=(-project CoachW.xcodeproj -scheme CoachW -derivedDataPath "$root/.build/DerivedData" -quiet)
if [[ "${1:-}" == "device" ]]; then
  xcodebuild "${common[@]}" -destination 'generic/platform=iOS' -allowProvisioningUpdates build
else
  xcodebuild "${common[@]}" -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
fi
