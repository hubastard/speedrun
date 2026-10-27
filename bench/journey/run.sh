#!/usr/bin/env bash
# The benchmark journey (journey.yaml) with each tool on one device, as a user runs it again
# and again: one warm-up run, then RUNS timed runs (default 3), each after the app's data is
# reset (not timed). A run's time is the wall clock of the tool's command, its start-up
# included. The table goes to results/<platform>.md: the median of the runs that passed (a
# failed run stops early), the pass count, and each run's time (✗: failed).
#   ./run.sh android|ios [tool...]     tools: speedrun maestro appium xcuitest (iOS only)
# Needs ../../speedrun (./build.sh), Speedrun Bench installed (../app/bench.sh build <platform>),
# maestro, Node (cd appium && npm install && npm run setup), and Xcode for xcuitest.
# The device: DEVICE=<serial or simulator UDID>, else the first adb device (Android) or the
# booted simulator (iOS).
set -euo pipefail
cd "$(dirname "$0")"

PLATFORM="${1:?usage: ./run.sh android|ios [tool...]}"
shift
RUNS="${RUNS:-3}"
APP_ID=dev.speedrun.bench
SPEEDRUN="$(cd ../.. && pwd)/speedrun"
IOS_APP=../app/ios/build/Build/Products/Release-iphonesimulator/SpeedrunBench.app
mkdir -p results

case "$PLATFORM" in
  android)
    DEVICE="${DEVICE:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
    TOOLS=("${@:-speedrun maestro appium}")
    ;;
  ios)
    DEVICE="${DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
    TOOLS=("${@:-speedrun maestro appium xcuitest}")
    ;;
  *) echo "platform: android or ios"; exit 1 ;;
esac
[ -n "$DEVICE" ] || { echo "No device."; exit 1; }
read -r -a TOOLS <<< "${TOOLS[*]}"

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

reset_app() {
  if [ "$PLATFORM" = android ]; then
    adb -s "$DEVICE" shell pm clear "$APP_ID" > /dev/null
  else
    xcrun simctl uninstall "$DEVICE" "$APP_ID"
    xcrun simctl install "$DEVICE" "$IOS_APP"
  fi
}

# One run of a tool; its exit status says whether the journey passed.
run_tool() {
  case "$1" in
    speedrun) "$SPEEDRUN" test --device "$DEVICE" --plain journey.yaml ;;
    maestro) maestro --device "$DEVICE" test journey.yaml ;;
    appium) node appium/journey.mjs "$PLATFORM" "$DEVICE" ;;
    xcuitest) xcodebuild test-without-building -xctestrun "$(ls xcuitest/build/Build/Products/*.xctestrun)" \
                -destination "id=$DEVICE" ;;
  esac
}

APPIUM_PID=
cleanup() { [ -n "$APPIUM_PID" ] && kill "$APPIUM_PID" 2> /dev/null || true; }
trap cleanup EXIT

for tool in "${TOOLS[@]}"; do
  case "$tool" in
    appium)
      # The server is started once, as in a test suite; each run opens its own session.
      APPIUM_HOME=appium/.appium appium/node_modules/.bin/appium --port 4723 --log-level error \
        > results/appium-server.log 2>&1 &
      APPIUM_PID=$!
      until curl -s localhost:4723/status > /dev/null; do sleep 0.5; done
      ;;
    xcuitest)
      xcodebuild build-for-testing -quiet -project xcuitest/Journey.xcodeproj -scheme Journey \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath xcuitest/build
      ;;
  esac
  times=()
  passed_times=()
  passed=0
  for i in $(seq 0 "$RUNS"); do
    reset_app
    t0=$(now)
    status=0
    run_tool "$tool" > "results/$PLATFORM-$tool-$i.log" 2>&1 || status=$?
    t1=$(now)
    secs=$(echo "$t1 - $t0" | bc)
    if [ "$i" = 0 ]; then
      echo "== $tool: warm-up ${secs} s, exit $status"
      continue
    fi
    echo "== $tool: run $i ${secs} s, exit $status"
    if [ "$status" = 0 ]; then
      passed=$((passed + 1))
      passed_times+=("$secs")
      times+=("$(printf '%.1f' "$secs")")
    else
      times+=("$(printf '%.1f' "$secs")✗")
    fi
  done
  median=-
  if [ "$passed" -gt 0 ]; then
    median=$(printf '%s\n' "${passed_times[@]}" | sort -n | awk '{ a[NR] = $1 } END { m = NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2; printf "%.1f s", m }')
  fi
  echo "$tool|$median|$passed/$RUNS|${times[*]}" >> "results/$PLATFORM.txt.new"
  if [ "$tool" = appium ]; then kill "$APPIUM_PID"; wait "$APPIUM_PID" 2> /dev/null || true; APPIUM_PID=; fi
done

{
  echo "| Tool ($PLATFORM) | Median of passed runs | Passed | Runs (s) |"
  echo "|---|---:|---:|---|"
  while IFS='|' read -r tool median passed runs; do
    echo "| $tool | $median | $passed | $runs |"
  done < "results/$PLATFORM.txt.new"
} > "results/$PLATFORM.md"
rm "results/$PLATFORM.txt.new"
cat "results/$PLATFORM.md"
