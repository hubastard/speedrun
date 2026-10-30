#!/usr/bin/env bash
# Builds NotifTest (an app asking for notification permission at launch, then showing
# "Granted" or "Denied") for the simulator and installs it on the booted one, or DEVICE.
# Needs Xcode. Then: ./speedrun test -p ios dev/flows/notifications
set -euo pipefail
cd "$(dirname "$0")"
OUT="$(mktemp -d -t notiftest.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/NotifTest.app"
mkdir -p "$APP"
cp NotifTest/Info.plist "$APP/"
xcrun -sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator -O \
  -o "$APP/NotifTest" NotifTest/main.swift
codesign -s - --force "$APP" >/dev/null 2>&1
xcrun simctl install "${DEVICE:-booted}" "$APP"
echo "Installed com.speedrun.notiftest"
