#!/usr/bin/env bash
# The benchmark journey (journey.yaml) with each tool on one device, as a user runs it again
# and again: one warm-up run, then RUNS timed runs (default 3), each after the app's data is
# reset (not timed). A run's time is the wall clock of the tool's command, its start-up
# included. The table goes to results/<platform>.md: the median of the runs that passed (a
# failed run stops early), the pass count, and each run's time (✗: failed).
#   ./run.sh android|ios [tool...]     tools: speedrun maestro maestro-runner appium argent xcuitest (iOS only)
# Needs ../../speedrun (./build.sh), Speedrun Bench installed (../app/bench.sh install <platform>),
# maestro, maestro-runner (~/.maestro-runner/bin, or MAESTRO_RUNNER=<path>), Node (cd appium &&
# npm install && npm run setup; Argent: cd ../agents && npm install), and Xcode for xcuitest.
# The device: DEVICE=<serial or simulator UDID>, else the first adb device (Android) or the
# booted simulator (iOS).
set -euo pipefail
cd "$(dirname "$0")"

PLATFORM="${1:?usage: ./run.sh android|ios [tool...]}"
shift
RUNS="${RUNS:-3}"
APP_ID=dev.speedrun.bench
SPEEDRUN="$(cd ../.. && pwd)/speedrun"
ARGENT=../agents/node_modules/.bin/argent
IOS_APP=../app/prebuilt/SpeedrunBench.app
mkdir -p results

case "$PLATFORM" in
  android)
    DEVICE="${DEVICE:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
    TOOLS=("${@:-speedrun maestro maestro-runner appium argent}")
    ;;
  ios)
    DEVICE="${DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
    TOOLS=("${@:-speedrun maestro maestro-runner appium argent xcuitest}")
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
    # Its default driver (DeviceLab), usage stats off; its own journey (one wait more).
    maestro-runner) MAESTRO_RUNNER_NO_TELEMETRY=1 "${MAESTRO_RUNNER:-$HOME/.maestro-runner/bin/maestro-runner}" \
                      --platform "$PLATFORM" --device "$DEVICE" test --output results/maestro-runner --flatten \
                      maestro-runner/journey.yaml ;;
    appium) node appium/journey.mjs "$PLATFORM" "$DEVICE" ;;
    # Its e2e runner (no model in the loop), usage stats off; its own journey (argent/).
    argent) DO_NOT_TRACK=1 "$ARGENT" e2e run argent/journey.yaml --platform "$PLATFORM" --device "$DEVICE" ;;
    xcuitest) xcodebuild test-without-building -xctestrun "$(ls xcuitest/build/Build/Products/*.xctestrun)" \
                -destination "id=$DEVICE" ;;
  esac
}

APPIUM_PID=
cleanup() { [ -n "$APPIUM_PID" ] && kill "$APPIUM_PID" 2> /dev/null || true; }
trap cleanup EXIT

stop_argent() {
  DO_NOT_TRACK=1 "$ARGENT" run stop-all-simulator-servers --args "{\"devices\": [\"$DEVICE\"]}" > /dev/null 2>&1 || true
  DO_NOT_TRACK=1 "$ARGENT" server stop > /dev/null 2>&1 || true
}

for tool in "${TOOLS[@]}"; do
  # Argent's services hold the device's UI automation (Android's one UiAutomation client):
  # gone before each tool, its own warm-up starting them again.
  [ -x "$ARGENT" ] && stop_argent
  if [ "$PLATFORM" = ios ]; then
    # A simulator runs one UI test runner at a time: the previous tool's goes (the warm-up
    # starts this tool's).
    "$SPEEDRUN" --stop-agent > /dev/null 2>&1 || true
    xcrun simctl terminate "$DEVICE" dev.devicelab.agent.uitests.xctrunner 2> /dev/null || true
    # maestro-runner turns on Reduce Motion (the app's animations end at once) and leaves it on:
    # each tool starts with it off (the app reads it when it starts, after reset_app).
    xcrun simctl spawn "$DEVICE" defaults write com.apple.Accessibility ReduceMotionEnabled -bool false
  fi
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
  # Argent keeps a tool server and the device's services running: gone before the next tool.
  if [ "$tool" = argent ]; then stop_argent; fi
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
