#!/usr/bin/env bash
# Usage: ./race.sh <flow.yaml> [-e KEY=VALUE]...
# Starts the same flow with speedrun on one emulator and Maestro on another at the same
# moment, to watch both screens side by side. Each tool's time runs from that common start,
# start-up included. It is a demo: the two emulators share this machine's CPU, so measure
# with compare.sh (one tool at a time) instead.
#
# Devices: the first two in `adb devices`. With only one emulator, a second one is booted for
# Maestro: AVD <name>_race, created once with the first one's system image and hardware (an AVD
# cannot run twice unless every instance is read-only). It is left running for the next race;
# stop it with `adb -s <serial> emu kill`. SPEEDRUN_DEVICE and MAESTRO_DEVICE pick devices.
#   ./race.sh bench_scenario.yaml -e TIMES=3
set -euo pipefail
cd "$(dirname "$0")"

FLOW="${1:?usage: ./race.sh <flow.yaml> [-e KEY=VALUE]...}"
shift
[ -x ./speedrun ] || { echo "./speedrun not found: run ./build.sh first"; exit 1; }
command -v maestro >/dev/null || { echo "maestro not found on PATH"; exit 1; }
APP="$(sed -n 's/^appId:[[:space:]]*//p' "$FLOW" | head -1 | tr -d "\"'\r")"
[ -n "$APP" ] || { echo "no appId in $FLOW"; exit 1; }
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
EMULATOR="$SDK/emulator/emulator"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
devices() { adb devices | awk 'NR > 1 && $2 == "device" { print $1 }'; }

# Boots <avd>_race, the twin of the first emulator's AVD (created on first use), and prints
# its serial once booted.
boot_second() {
  local avd race dir sysimg device port serial pid
  avd="$(adb -s "$1" emu avd name | head -1 | tr -d '\r')"
  race="${avd}_race"
  [ -x "$EMULATOR" ] || { echo "emulator not found at $EMULATOR (set ANDROID_HOME)" >&2; return 1; }
  if ! "$EMULATOR" -list-avds 2>/dev/null | grep -qx "$race"; then
    [ -x "$AVDMANAGER" ] || { echo "avdmanager not found at $AVDMANAGER (SDK command-line tools)" >&2; return 1; }
    dir="$(adb -s "$1" emu avd path | head -1 | tr -d '\r')"
    sysimg="$(sed -n 's/^image.sysdir.1=//p' "$dir/config.ini" | sed 's#/$##; s#/#;#g')"
    device="$(sed -n 's/^hw.device.name=//p' "$dir/config.ini")"
    echo "== Creating AVD $race for Maestro: $sysimg, $device, same settings as $avd" >&2
    echo no | "$AVDMANAGER" -s create avd -n "$race" -k "$sysimg" -d "$device" >&2
    sed -e "s/^AvdId=.*/AvdId=$race/" -e "s/^avd.ini.displayname=.*/avd.ini.displayname=$race/" \
      "$dir/config.ini" >"${ANDROID_AVD_HOME:-$HOME/.android/avd}/$race.avd/config.ini"
  fi
  # Already running (adb can take a moment to list it again): use it.
  if pgrep -f "qemu-system.*-avd $race\$" >/dev/null || pgrep -f "qemu-system.*-avd $race " >/dev/null; then
    for _ in $(seq 1 60); do
      for serial in $(devices); do
        [ "$(adb -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')" = "$race" ] && { echo "$serial"; return 0; }
      done
      sleep 1
    done
    echo "$race is running, but adb does not list it" >&2
    return 1
  fi
  port=5556
  while adb devices | grep -q "^emulator-$port"; do port=$((port + 2)); done
  serial="emulator-$port"
  echo "== Booting $race for Maestro ($serial; the first boot takes a few minutes)" >&2
  # Its own session (setsid), so it outlives this terminal.
  nohup perl -MPOSIX=setsid -e 'setsid(); exec @ARGV' \
    "$EMULATOR" -avd "$race" -port "$port" -netdelay none -netspeed full -no-boot-anim \
    </dev/null >"${TMPDIR:-/tmp}/speedrun_race_emulator.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 600); do
    kill -0 "$pid" 2>/dev/null || { echo "the emulator exited:" >&2; tail -5 "${TMPDIR:-/tmp}/speedrun_race_emulator.log" >&2; return 1; }
    [ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && { echo "$serial"; return 0; }
    sleep 1
  done
  echo "$serial did not finish booting in 10 minutes" >&2
  return 1
}

DEVS=($(devices))
[ ${#DEVS[@]} -gt 0 ] || { echo "No device or emulator connected."; exit 1; }
SPEEDRUN_DEVICE="${SPEEDRUN_DEVICE:-${DEVS[0]}}"
if [ -z "${MAESTRO_DEVICE:-}" ]; then
  for d in "${DEVS[@]}"; do
    if [ "$d" != "$SPEEDRUN_DEVICE" ]; then MAESTRO_DEVICE="$d"; break; fi
  done
fi
if [ -z "${MAESTRO_DEVICE:-}" ]; then
  case "$SPEEDRUN_DEVICE" in
    emulator-*) MAESTRO_DEVICE="$(boot_second "$SPEEDRUN_DEVICE")" ;;
    *) echo "Maestro needs a second device: connect one or start an emulator."; exit 1 ;;
  esac
fi

# The same starting point on both: animations off (speedrun turns them off on its device
# anyway) and the app freshly on its first screen.
prepare() {
  local activity
  adb -s "$1" shell "settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0"
  activity="$(adb -s "$1" shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$APP" | tail -1 | tr -d '\r')"
  adb -s "$1" shell am force-stop "$APP"
  adb -s "$1" shell am start -W -n "$activity" >/dev/null
}
prepare "$SPEEDRUN_DEVICE" &
prepare "$MAESTRO_DEVICE" &
wait
sleep 1

OUT="$(mktemp -d -t speedrun_race.XXXXXX)"
echo "== Race: $FLOW $*"
echo "   speedrun on $SPEEDRUN_DEVICE, Maestro on $MAESTRO_DEVICE (each emulator window shows its port)"
START=$(now_ms)
./speedrun --device "$SPEEDRUN_DEVICE" --flow "$FLOW" "$@" --plain >"$OUT/speedrun.log" 2>&1 &
S_PID=$!
maestro --device "$MAESTRO_DEVICE" test "$@" "$FLOW" >"$OUT/maestro.log" 2>&1 &
M_PID=$!
# Background jobs ignore Ctrl-C, so pass it on: both tools clean up on SIGTERM. Any other
# early exit stops them too.
trap 'kill -TERM $S_PID $M_PID 2>/dev/null; wait; echo; echo "stopped (logs: $OUT)"; exit 130' INT TERM
trap 'kill -TERM $S_PID $M_PID 2>/dev/null || true' EXIT

COLS=$(tput cols 2>/dev/null || echo 100)
S_END="" M_END="" S_RC=0 M_RC=0
# The command a log ends on, without ANSI codes, fit to the terminal.
last_line() {
  { tail -c 4000 "$1" | tr '\r' '\n' | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -1 |
    sed 's/^[[:space:]]*//' | cut -c1-$((COLS - 36)); } || true # an empty log is fine
}
row() { # name device end rc log
  local mark secs what
  if [ -z "$3" ]; then
    mark="⏳"; secs=$(( $(now_ms) - START )); what="$(last_line "$5")"
  else
    secs=$(( $3 - START ))
    if [ "$4" = 0 ]; then mark="✅"; what="passed"; else mark="❌"; what="failed (exit $4)"; fi
  fi
  printf '\033[2K   %-9s %-14s %s %6.1f s   %s\n' "$1" "$2" "$mark" "$(echo "$secs" | awk '{ print $1 / 1000 }')" "$what"
}
drawn=0
while :; do
  if [ -z "$S_END" ] && ! kill -0 "$S_PID" 2>/dev/null; then S_END=$(now_ms); wait "$S_PID" || S_RC=$?; fi
  if [ -z "$M_END" ] && ! kill -0 "$M_PID" 2>/dev/null; then M_END=$(now_ms); wait "$M_PID" || M_RC=$?; fi
  if [ -t 1 ]; then
    [ $drawn = 1 ] && printf '\033[2F'
    row speedrun "$SPEEDRUN_DEVICE" "$S_END" "$S_RC" "$OUT/speedrun.log"
    row Maestro "$MAESTRO_DEVICE" "$M_END" "$M_RC" "$OUT/maestro.log"
    drawn=1
  fi
  [ -n "$S_END" ] && [ -n "$M_END" ] && break
  sleep 0.2
done
trap - INT TERM EXIT

if [ ! -t 1 ]; then
  row speedrun "$SPEEDRUN_DEVICE" "$S_END" "$S_RC" "$OUT/speedrun.log"
  row Maestro "$MAESTRO_DEVICE" "$M_END" "$M_RC" "$OUT/maestro.log"
fi
if [ "$S_RC" = 0 ] && [ "$M_RC" = 0 ]; then
  awk -v s=$((S_END - START)) -v m=$((M_END - START)) 'BEGIN { printf "   Maestro took %.1fx as long, start-up included.\n", m / s }'
  rm -rf "$OUT"
else
  echo "   A run failed. Logs: $OUT/speedrun.log, $OUT/maestro.log"
fi
