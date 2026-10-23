#!/usr/bin/env bash
# Builds ./speedrun: the Android agent APK first, then the Odin binary, which embeds it; and,
# when Xcode is installed, the iOS agent (an XCUITest runner for simulators, in
# agent/ios/build, which speedrun starts from there). Run it once, and again after changing
# agent/ or host/. Running flows never rebuilds anything.
set -euo pipefail
cd "$(dirname "$0")"

command -v odin >/dev/null || { echo "odin not found on PATH"; exit 1; }

echo "== Building the Android agent (Gradle)"
(cd agent/android && ./gradlew -q assembleDebug)

echo "== Building speedrun (Odin)"
odin build host -o:speed -out:speedrun

if command -v xcodebuild >/dev/null; then
  echo "== Building the iOS agent (Xcode, for simulators)"
  xcodebuild build-for-testing -quiet -project agent/ios/SpeedrunAgent.xcodeproj -scheme SpeedrunAgent \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath agent/ios/build
else
  echo "== No Xcode: skipping the iOS agent"
fi

echo "Done: ./speedrun --flow <file.yaml>"
