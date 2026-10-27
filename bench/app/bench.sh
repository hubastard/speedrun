#!/usr/bin/env bash
# The benchmark app (Speedrun Bench): builds it, runs its flows (flows/) as speedrun's
# regression suite, and compares speedrun with Maestro on the same flows.
#   ./bench.sh build ios|android      expo prebuild, a Release build, installed on the device
#   ./bench.sh test ios|android       the suite with speedrun (pass/fail, per-flow times)
#   ./bench.sh compare ios|android    the suite with speedrun, then with Maestro: a table per
#                                     flow in results/<platform>.md
#   ./bench.sh maestro ios|android    the suite with Maestro only (the table takes speedrun's
#                                     last results)
# Extra arguments go to `speedrun test` / `maestro test` (flow files instead of the folder,
# --include-tags ...). The device: DEVICE=<serial or simulator UDID>, else the first adb device
# (Android) or the booted simulator (iOS). Needs ../../speedrun (./build.sh); compare needs
# maestro; build needs Node, and Xcode or the Android SDK.
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:?usage: ./bench.sh build|test|maestro|compare ios|android [args...]}"
PLATFORM="${2:?usage: ./bench.sh build|test|maestro|compare ios|android [args...]}"
shift 2
SPEEDRUN="$(cd ../.. && pwd)/speedrun"
APP_ID=dev.speedrun.bench
RESULTS=results
mkdir -p "$RESULTS"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

case "$PLATFORM" in
  ios)
    DEVICE="${DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
    [ -n "$DEVICE" ] || { echo "No booted simulator: boot one (xcrun simctl boot <udid>)."; exit 1; }
    ;;
  android)
    DEVICE="${DEVICE:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
    [ -n "$DEVICE" ] || { echo "No Android device: start an emulator."; exit 1; }
    ;;
  *) echo "platform: ios or android"; exit 1 ;;
esac

build() {
  [ -d node_modules ] || npm install --no-audit --no-fund
  if [ "$PLATFORM" = ios ]; then
    CI=1 npx expo prebuild --platform ios
    xcodebuild -workspace ios/SpeedrunBench.xcworkspace -scheme SpeedrunBench -configuration Release \
      -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/build -quiet
    xcrun simctl install "$DEVICE" ios/build/Build/Products/Release-iphonesimulator/SpeedrunBench.app
  else
    CI=1 npx expo prebuild --platform android
    (cd android && ./gradlew -q assembleRelease)
    adb -s "$DEVICE" install -r android/app/build/outputs/apk/release/app-release.apk
  fi
  echo "== Installed $APP_ID on $DEVICE"
}

# Runs the suite with one tool; prints its wall clock. $1: speedrun or maestro.
run() {
  local tool="$1" report="$RESULTS/$PLATFORM-$1.xml"; shift
  # The flows folder, unless a flow file or folder is given.
  local flows=(flows) arg
  for arg in "$@"; do [ -e "$arg" ] && flows=(); done
  # On iOS speedrun keeps its agent between runs: stop it, so both tools start cold.
  [ "$PLATFORM" = ios ] && "$SPEEDRUN" --stop-agent >/dev/null 2>&1 || true
  local t0 t1 status=0
  t0=$(now_ms)
  if [ "$tool" = speedrun ]; then
    "$SPEEDRUN" test --device "$DEVICE" --format junit --output "$report" "$@" "${flows[@]}" || status=$?
  else
    maestro --device "$DEVICE" test --format junit --output "$report" "$@" "${flows[@]}" || status=$?
  fi
  t1=$(now_ms)
  [ "$PLATFORM" = ios ] && "$SPEEDRUN" --stop-agent >/dev/null 2>&1 || true
  echo "$((t1 - t0))" > "$RESULTS/$PLATFORM-$tool.wall"
  echo "== $tool: $(( (t1 - t0) / 1000 )) s wall clock, exit $status"
}

table() {
  python3 - "$PLATFORM" "$RESULTS" <<'PY'
import os, sys, xml.etree.ElementTree as ET
platform, results = sys.argv[1], sys.argv[2]
def load(tool):
    path = f"{results}/{platform}-{tool}.xml"
    if not os.path.exists(path): return None, None
    cases = {}
    for tc in ET.parse(path).getroot().iter("testcase"):
        failed = tc.find("failure") is not None or tc.find("error") is not None
        cases[tc.get("name")] = (float(tc.get("time") or 0), failed)
    wall = open(f"{results}/{platform}-{tool}.wall").read().strip()
    return cases, int(wall) / 1000
ours, ours_wall = load("speedrun")
theirs, theirs_wall = load("maestro")
def cell(c):
    if c is None: return "–"
    t, failed = c
    return f"{t:.0f} s" + (" ✗" if failed else "")
lines = [f"| Flow ({platform}) | speedrun | Maestro | Speedup |", "|---|---:|---:|---:|"]
names = sorted(set(ours or {}) | set(theirs or {}))
for n in names:
    a, b = (ours or {}).get(n), (theirs or {}).get(n)
    speed = f"{b[0] / a[0]:.1f}x" if a and b and a[0] > 0 and not a[1] and not b[1] else ""
    lines.append(f"| {n} | {cell(a)} | {cell(b)} | {speed} |")
def total(cases): return sum(t for t, _ in cases.values()) if cases else None
ta, tb = total(ours), total(theirs)
lines.append(f"| **All flows** | **{ta:.0f} s** | **{tb:.0f} s** | **{tb / ta:.1f}x** |" if ta and tb else
             f"| **All flows** | {ta or 0:.0f} s | {tb or 0:.0f} s | |")
if ours_wall and theirs_wall:
    lines.append(f"| **Wall clock** | **{ours_wall:.0f} s** | **{theirs_wall:.0f} s** | **{theirs_wall / ours_wall:.1f}x** |")
passed = lambda c: f"{sum(not f for _, f in c.values())}/{len(c)}" if c else "–"
lines.append(f"\nPassed: speedrun {passed(ours)}, Maestro {passed(theirs)}. ✗: failed.")
out = "\n".join(lines)
open(f"{results}/{platform}.md", "w").write(out + "\n")
print(out)
PY
}

case "$CMD" in
  build) build ;;
  test) run speedrun "$@"; table ;;
  maestro) run maestro "$@"; table ;;
  compare)
    run speedrun "$@"
    # Maestro draws its live view over the screen: start it on a clear one.
    if [ -t 1 ]; then printf '\033[H\033[2J'; fi
    run maestro "$@"
    table
    ;;
  *) echo "usage: ./bench.sh build|test|maestro|compare ios|android [args...]"; exit 1 ;;
esac
