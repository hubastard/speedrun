#!/usr/bin/env bash
# Usage: ./run.sh "<text of an on-screen element to tap>" [iterations]
#        ./run.sh --flow <flow.yaml> [-e KEY=VALUE]... [--timings <out.json>]
# Examples (open the Settings app on the emulator first):
#   ./run.sh "Network & internet" 20                     latency breakdown: tap + back loop
#   ./run.sh --flow bench_scenario.yaml -e TIMES=5       a Maestro flow file, run by this tool
# The agent runs as the shell user (app_process, InputManager injection). AGENT_MODE=instrument
# runs it as an instrumentation instead (UiAutomation injection, ~60 ms slower per action);
# that is also the automatic fallback when the shell agent cannot start.
set -euo pipefail
cd "$(dirname "$0")"

MODE=bench
FLOW_ARGS=()
if [ "${1:-}" = --flow ]; then
  MODE=flow
  shift
  FLOW_ARGS=("$@")
  [ ${#FLOW_ARGS[@]} -gt 0 ] || { echo "--flow needs a flow file"; exit 1; }
fi
TARGET="${1:-}"
ITERS="${2:-10}"
PORT="${PORT:-7777}"
AGENT_MODE="${AGENT_MODE:-shell}"
APK="agent/app/build/outputs/apk/debug/app-debug.apk"
DEVICE_APK="/data/local/tmp/agent.apk"
AGENT_NAME="spike-agent"   # process name of the shell agent (app_process --nice-name)
HOST_BIN="./spike_host"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

command -v adb  >/dev/null || { echo "adb not found on PATH"; exit 1; }
command -v odin >/dev/null || { echo "odin not found on PATH"; exit 1; }
[ -f "$APK" ] || { echo "Agent APK missing. Build it first:  (cd agent && ./gradlew assembleDebug)"; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "No device/emulator connected."; exit 1; }

# Only one UiAutomation client can exist at a time: stop both kinds of agent.
stop_agents() {
  adb shell am force-stop com.spike.agent >/dev/null 2>&1 || true
  # pidof matches the --nice-name cmdline (pkill matches comm, which is "main").
  adb shell "pids=\$(pidof $AGENT_NAME) && kill \$pids" >/dev/null 2>&1 || true
}

AGENT_PID=""
AGENT_OUT="$(mktemp -t spike_agent.XXXXXX)"
cleanup() {
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null || true
  stop_agents
  adb forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
  rm -f "$AGENT_OUT"
}
trap cleanup EXIT

echo "== Disabling animations (restore with: adb shell settings put global <name> 1)"
for s in window_animation_scale transition_animation_scale animator_duration_scale; do
  adb shell settings put global "$s" 0
done

stop_agents
if [ "$MODE" = bench ]; then
  echo
  echo "== Baseline: 'uiautomator dump' x5 (a full-hierarchy dump, the classic way to read the screen)"
  total=0
  for i in 1 2 3 4 5; do
    t0=$(now_ms)
    adb shell uiautomator dump /sdcard/spike_dump.xml >/dev/null 2>&1
    adb shell cat /sdcard/spike_dump.xml >/dev/null
    t1=$(now_ms)
    echo "  dump + read #$i: $((t1 - t0)) ms"
    total=$((total + t1 - t0))
  done
  echo "  average: $((total / 5)) ms per screen read"
fi

echo
echo "== Building host"
odin build host -o:speed -out:"$HOST_BIN"

# Prints "listening on ..." once it serves; exits early (reason on stdout and in logcat) if not.
start_shell_agent() {
  adb push "$APK" "$DEVICE_APK" >"$AGENT_OUT" 2>&1 || return 1
  adb shell "CLASSPATH=$DEVICE_APK exec app_process / --nice-name=$AGENT_NAME com.spike.agent.ShellMain $PORT" \
    >"$AGENT_OUT" 2>&1 &
  AGENT_PID=$!
  disown "$AGENT_PID"   # no "Terminated" message when we stop it at exit
  for _ in $(seq 1 100); do
    grep -q '^listening' "$AGENT_OUT" && return 0
    kill -0 "$AGENT_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

if [ "$AGENT_MODE" = shell ]; then
  echo "== Starting agent as the shell user (app_process)"
  if start_shell_agent; then
    sed 's/^/  agent: /' "$AGENT_OUT"
  else
    echo "  shell agent did not start. Its output, then the end of logcat:"
    sed 's/^/    /' "$AGENT_OUT"
    adb logcat -d -s 'SpikeAgent:*' 'AndroidRuntime:E' 'appproc:*' | tail -n 8 | sed 's/^/    /'
    echo "  falling back to the instrumentation agent"
    kill "$AGENT_PID" 2>/dev/null || true
    stop_agents
    AGENT_MODE=instrument
  fi
fi

if [ "$AGENT_MODE" = instrument ]; then
  echo "== Installing and starting agent (instrumentation)"
  adb install -r "$APK" >/dev/null
  adb shell am instrument -w --no-hidden-api-checks -e port "$PORT" com.spike.agent/.AgentInstrumentation >/dev/null 2>&1 &
  AGENT_PID=$!
  disown "$AGENT_PID"
fi

adb forward "tcp:$PORT" "tcp:$PORT" >/dev/null

if [ "$MODE" = flow ]; then
  "$HOST_BIN" "$PORT" --flow "${FLOW_ARGS[@]}"
else
  "$HOST_BIN" "$PORT" "$TARGET" "$ITERS"
fi
