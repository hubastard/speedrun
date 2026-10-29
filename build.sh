#!/usr/bin/env bash
# Builds ./speedrun: the Android agent APK and, when Xcode is installed, the iOS agent (an
# XCUITest runner for simulators) first, then the Odin binary, which embeds both and links
# the JavaScript engine (host/js) and the image codecs (host/image). The binary needs no file
# next to it. Run it once, and again after changing agent/ or host/. Running flows never
# rebuilds anything.
# SPEEDRUN_NO_ANDROID=1: an iOS-only speedrun, without the Android agent (no JDK or Gradle
# needed; CI's iOS job); it refuses Android devices, and package.sh refuses to pack it.
set -euo pipefail
cd "$(dirname "$0")"

command -v odin >/dev/null || { echo "odin not found on PATH"; exit 1; }

ANDROID=true
if [ "${SPEEDRUN_NO_ANDROID:-}" = 1 ]; then
  ANDROID=false
  echo "== No Android agent (SPEEDRUN_NO_ANDROID=1): an iOS-only build"
else
  echo "== Building the Android agent (Gradle)"
  (cd agent/android && ./gradlew -q assembleDebug)
fi

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

# stb_image and stb_image_write, for screenshots (cropOn, assertScreenshot).
IMG=host/image
mkdir -p "$IMG/build"
if [[ ! -f $IMG/build/libspeedrunimage.a || $IMG/image.c -nt $IMG/build/libspeedrunimage.a ]]; then
  echo "== Building the image codecs (stb)"
  cc -O2 -fPIC -DNDEBUG -c "$IMG/image.c" -o "$IMG/build/image.o"
  rm -f "$IMG/build/libspeedrunimage.a"
  ar rcs "$IMG/build/libspeedrunimage.a" "$IMG/build/image.o"
fi
# Their license, from the end of the header: speedrun --licenses prints it.
sed -n '/This software is available under 2 licenses/,$p' "$IMG/stb_image.h" > "$IMG/build/LICENSE.txt"

IOS_AGENT_ID=
if command -v xcodebuild >/dev/null; then
  echo "== Building the iOS agent (Xcode, for simulators)"
  xcodebuild build-for-testing -quiet -project agent/ios/SpeedrunAgent.xcodeproj -scheme SpeedrunAgent \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath agent/ios/build
  # Packed for the binary: the newest test run file and the runner app (the Swift module is a
  # build product only). Its id is a hash of their contents, not their times: it names the
  # folder speedrun unpacks it into and the runner build to reuse, so an unchanged agent keeps
  # its runner up across builds. Packed again only when the id changes.
  products=agent/ios/build/Build/Products
  xctestrun=$(cd "$products" && ls -t -- *.xctestrun | head -1)
  runner=Release-iphonesimulator/SpeedrunAgentUITests-Runner.app
  IOS_AGENT_ID=$(cd "$products" && find "$xctestrun" "$runner" -type f -print0 | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 | shasum -a 256 | cut -c 1-16)
  if [[ ! -f agent/ios/build/agent.tar.gz || "$(cat agent/ios/build/agent.id 2>/dev/null)" != "$IOS_AGENT_ID" ]]; then
    COPYFILE_DISABLE=1 tar -czf agent/ios/build/agent.tar.gz --no-xattrs --no-mac-metadata -C "$products" "$xctestrun" "$runner"
    echo "$IOS_AGENT_ID" > agent/ios/build/agent.id
  fi
else
  echo "== No Xcode: speedrun without its iOS agent"
fi

echo "== Building speedrun (Odin)"
# The version --version prints: SPEEDRUN_VERSION, else the git tag or commit.
VERSION="${SPEEDRUN_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
# Odin takes no empty -define: without the iOS agent, IOS_AGENT_ID keeps its default ("").
ios_define=()
[ -n "$IOS_AGENT_ID" ] && ios_define=(-define:IOS_AGENT_ID="$IOS_AGENT_ID")
odin build host -o:speed -out:speedrun -define:SPEEDRUN_VERSION="$VERSION" -define:ANDROID_AGENT=$ANDROID ${ios_define[@]+"${ios_define[@]}"}

echo "Done: ./speedrun test <flow file or folder>"
