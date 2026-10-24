#!/usr/bin/env bash
# Builds ./speedrun: the Android agent APK first, then the Odin binary, which embeds it and
# links the JavaScript engine (host/js); and,
# when Xcode is installed, the iOS agent (an XCUITest runner for simulators, in
# agent/ios/build, which speedrun starts from there). Run it once, and again after changing
# agent/ or host/. Running flows never rebuilds anything.
set -euo pipefail
cd "$(dirname "$0")"

command -v odin >/dev/null || { echo "odin not found on PATH"; exit 1; }

echo "== Building the Android agent (Gradle)"
(cd agent/android && ./gradlew -q assembleDebug)

# QuickJS-ng and its C glue, linked into speedrun; rebuilt only when they change (~10 s).
JS=host/js
mkdir -p "$JS/build"
if [[ ! -f $JS/build/quickjs.o || $JS/quickjs-ng/quickjs-amalgam.c -nt $JS/build/quickjs.o ]]; then
  echo "== Building the JavaScript engine (QuickJS-ng)"
  cc -O2 -fPIC -DNDEBUG -c "$JS/quickjs-ng/quickjs-amalgam.c" -o "$JS/build/quickjs.o"
fi
if [[ ! -f $JS/build/libspeedrunjs.a || $JS/engine.c -nt $JS/build/libspeedrunjs.a || $JS/build/quickjs.o -nt $JS/build/libspeedrunjs.a ]]; then
  cc -O2 -fPIC -DNDEBUG -Wall -c "$JS/engine.c" -o "$JS/build/engine.o"
  rm -f "$JS/build/libspeedrunjs.a"
  ar rcs "$JS/build/libspeedrunjs.a" "$JS/build/quickjs.o" "$JS/build/engine.o"
fi

echo "== Building speedrun (Odin)"
odin build host -o:speed -out:speedrun

if command -v xcodebuild >/dev/null; then
  echo "== Building the iOS agent (Xcode, for simulators)"
  xcodebuild build-for-testing -quiet -project agent/ios/SpeedrunAgent.xcodeproj -scheme SpeedrunAgent \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath agent/ios/build
else
  echo "== No Xcode: skipping the iOS agent"
fi

echo "Done: ./speedrun test <flow file or folder>"
