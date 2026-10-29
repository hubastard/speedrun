#!/usr/bin/env bash
# Builds speedrun and packs what it needs at run time into
# dist/speedrun-<version>-<os>-<arch>.tar.gz: the binary (the Android agent, the JavaScript
# engine and the image codecs are inside it) and, when Xcode is installed, the iOS agent next
# to it, where speedrun looks for it (agent/ios/build/Build/Products). The machine running it
# then needs only adb (Android) or Xcode (iOS): no Odin, C compiler or JDK.
#   ./package.sh                       # version from git: the tag, else the commit
#   SPEEDRUN_VERSION=0.1.0 ./package.sh
set -euo pipefail
cd "$(dirname "$0")"

export SPEEDRUN_VERSION="${SPEEDRUN_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
[ "${SPEEDRUN_NO_ANDROID:-}" != 1 ] || { echo "package.sh: a release needs the Android agent; unset SPEEDRUN_NO_ANDROID"; exit 1; }
./build.sh

os=$(uname -s | tr '[:upper:]' '[:lower:]')
[ "$os" = darwin ] && os=macos
arch=$(uname -m)
[ "$arch" = aarch64 ] && arch=arm64
name="speedrun-$SPEEDRUN_VERSION-$os-$arch"
stage="dist/$name"
rm -rf "$stage" "dist/$name.tar.gz"
mkdir -p "$stage"

cp speedrun "$stage/"
# The license, and those of the third-party code built into the binary (NOTICE lists them).
cp LICENSE NOTICE "$stage/"
mkdir -p "$stage/licenses"
cp host/js/quickjs-ng/LICENSE "$stage/licenses/quickjs-ng.txt"
cp host/js/datafaker/LICENSE "$stage/licenses/datafaker.txt"
sed -n '/This software is available under 2 licenses/,$p' host/image/stb_image.h > "$stage/licenses/stb.txt"
products=agent/ios/build/Build/Products
if [ -d "$products" ]; then
  # The test run file and the runner app; the Swift module is a build product only.
  mkdir -p "$stage/$products/Release-iphonesimulator"
  cp "$products"/*.xctestrun "$stage/$products/"
  cp -R "$products/Release-iphonesimulator/SpeedrunAgentUITests-Runner.app" "$stage/$products/Release-iphonesimulator/"
  ios="Android and iOS simulators (the iOS agent was built with $(xcodebuild -version | head -1))"
else
  ios="Android only (built without Xcode: no iOS agent)"
fi

cat > "$stage/README.txt" <<EOF
speedrun $SPEEDRUN_VERSION ($os $arch): $ios.

Run it from this folder, or put the folder on your PATH (a symlink to the binary works too):
  ./speedrun test flows/            # takes maestro test's options
  ./speedrun --help

Android needs adb on PATH and an emulator or device; iOS needs Xcode and a booted simulator.
Keep agent/ next to the binary: speedrun starts its iOS agent from there.

Licensed under the Apache License 2.0 (LICENSE); third-party code: NOTICE and licenses/.
EOF

tar -czf "dist/$name.tar.gz" -C dist "$name"
rm -rf "$stage"
# Its SHA-256, published next to it: install.sh installs nothing that does not match.
(cd dist && { sha256sum "$name.tar.gz" 2>/dev/null || shasum -a 256 "$name.tar.gz"; } > "$name.tar.gz.sha256")
echo "== dist/$name.tar.gz ($(du -h "dist/$name.tar.gz" | cut -f1)): $ios"
