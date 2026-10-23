#!/usr/bin/env bash
# Usage: ./compare.sh <flow.yaml> [-e KEY=VALUE]...
# Runs the same Maestro flow file with speedrun (./speedrun --flow) and with Maestro, each
# after a fresh start of the flow's app, then lines the two runs up command by command and
# prints the median time per command (repeat iterations grouped), then the totals: the flow,
# the time each tool spends outside it (start-up and shutdown: a slow tool costs that on
# every run too), and the wall clock. Needs ./speedrun (./build.sh), maestro and python3.
#   ./compare.sh bench_scenario.yaml -e TIMES=5
set -euo pipefail
cd "$(dirname "$0")"

FLOW="${1:?usage: ./compare.sh <flow.yaml> [-e KEY=VALUE]...}"
shift
OUT="$(mktemp -d -t speedrun_compare.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

[ -x ./speedrun ] || { echo "./speedrun not found: run ./build.sh first"; exit 1; }
command -v maestro >/dev/null || { echo "maestro not found on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on PATH"; exit 1; }
# With several devices connected (race.sh leaves a second emulator running), both tools run
# on ANDROID_SERIAL, or else on the first device.
DEVICE="${ANDROID_SERIAL:-$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
[ -n "$DEVICE" ] || { echo "No device or emulator connected."; exit 1; }
export ANDROID_SERIAL="$DEVICE"
APP="$(sed -n 's/^appId:[[:space:]]*//p' "$FLOW" | head -1 | tr -d "\"'\r")"
[ -n "$APP" ] || { echo "no appId in $FLOW"; exit 1; }

# Force-stop the app and open its launcher activity: both tools start from the same screen.
restart_app() {
  local activity
  activity="$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$APP" | tail -1 | tr -d '\r')"
  adb shell am force-stop "$APP"
  adb shell am start -W -n "$activity" >/dev/null
  sleep 1
}

echo "== speedrun: ./speedrun --flow $FLOW $*"
restart_app
# speedrun stops its agent at exit, so Maestro's driver can take the UiAutomation slot after it.
s0=$(now_ms)
./speedrun --device "$DEVICE" --flow "$FLOW" "$@" --timings "$OUT/speedrun.json"
s1=$(now_ms)

# Maestro draws its live view from the top of the screen, over whatever is there: start it on
# a clear screen. Scrollback keeps speedrun's run (no \e[3J).
if [ -t 1 ]; then printf '\033[H\033[2J'; else echo; fi
echo "== Maestro: maestro test $* $FLOW"
restart_app
t0=$(now_ms)
maestro --device "$DEVICE" test --debug-output "$OUT/maestro" --flatten-debug-output "$@" "$FLOW"
t1=$(now_ms)

python3 - "$OUT/speedrun.json" "$OUT/maestro" "$((s1 - s0))" "$((t1 - t0))" <<'PY'
import glob, json, statistics, sys

ours_path, maestro_dir = sys.argv[1], sys.argv[2]
ours_wall, theirs_wall = int(sys.argv[3]), int(sys.argv[4])
ours = json.load(open(ours_path))
report = json.load(open(glob.glob(f"{maestro_dir}/**/commands*.json", recursive=True)[0]))
theirs = [e for e in report
          if list(e["command"])[0] not in ("defineVariablesCommand", "applyConfigurationCommand")]

# Maestro's internal command names for the YAML commands speedrun runs.
NAMES = {
    "tapOnElement": {"tapOn", "doubleTapOn", "longPressOn"}, "tapOnPointV2Command": {"tapOn", "doubleTapOn", "longPressOn"},
    "assertConditionCommand": {"assertVisible", "assertNotVisible", "extendedWaitUntil"},
    "backPressCommand": {"back"}, "hideKeyboardCommand": {"hideKeyboard"},
    "inputTextCommand": {"inputText"}, "eraseTextCommand": {"eraseText"}, "pressKeyCommand": {"pressKey"},
    "scrollCommand": {"scroll"}, "scrollUntilVisible": {"scrollUntilVisible"}, "swipeCommand": {"swipe"},
    "waitForAnimationToEndCommand": {"waitForAnimationToEnd"}, "openLinkCommand": {"openLink"},
    "launchAppCommand": {"launchApp"}, "stopAppCommand": {"stopApp"}, "killAppCommand": {"killApp"},
    "clearStateCommand": {"clearState"}, "clearKeychainCommand": {"clearKeychain"},
    "runFlowCommand": {"runFlow"}, "repeatCommand": {"repeat"}, "retryCommand": {"retry"},
    "takeScreenshotCommand": {"takeScreenshot"},
}

# Both tools record commands in the order they start, containers before their children.
pairs = []
for i, (o, t) in enumerate(zip(ours, theirs)):
    key = list(t["command"])[0]
    if o["command"] not in NAMES.get(key, set()):
        print(f"\n!! The runs diverge at command #{i}: speedrun ran `{o['command']}`, Maestro ran `{key}`."
              " Only the commands before it are compared.")
        break
    if o["status"] != t["metadata"].get("status"):
        print(f"!! #{i} {o['description']}: {o['status']} in speedrun, {t['metadata'].get('status')} in Maestro")
    pairs.append((o, t["metadata"]))
if len(ours) != len(theirs) and len(pairs) == min(len(ours), len(theirs)):
    print(f"\n!! speedrun ran {len(ours)} commands, Maestro {len(theirs)}.")

groups = {}
for o, t in pairs:
    g = groups.setdefault(o["path"], {"o": o, "ours": [], "theirs": []})
    g["ours"].append(o["duration_ms"])
    g["theirs"].append(t.get("duration") or 0)

med = statistics.median
print("\n== Side by side: median ms per command (speedrun / Maestro)")
print(f"   {'command':52s} {'runs':>4s} {'speedrun':>10s} {'Maestro':>10s} {'ratio':>7s}")
for path, g in groups.items():
    o, m = med(g["ours"]), med(g["theirs"])
    indent = "  " * g["o"]["depth"]
    ratio = f"{m / o:6.1f}x" if o > 0 else "      -"
    print(f"   {(indent + g['o']['description'])[:52]:52s} {len(g['ours']):4d} {o:10.0f} {m:10.0f} {ratio}")
ours_total = sum(o["duration_ms"] for o, _ in pairs if o["depth"] == 0)
theirs_total = sum(t.get("duration") or 0 for o, t in pairs if o["depth"] == 0)

def total(label, o_ms, t_ms):
    print(f"   {label:52s} {'':4s} {o_ms / 1000:10.1f} {t_ms / 1000:10.1f} {t_ms / max(o_ms, 1):6.1f}x")

print()
total("FLOW (s)", ours_total, theirs_total)
# Each tool's whole run, from launching it to its exit, minus the flow: connecting to the
# device, starting its driver, and shutting down. Only meaningful when both runs match.
if len(pairs) == len(ours) == len(theirs):
    total("OUTSIDE THE FLOW: start-up + shutdown (s)", ours_wall - ours_total, theirs_wall - theirs_total)
else:
    print("   (the runs differ, so the time outside the flow cannot be split out)")
total("WALL CLOCK, ALL INCLUDED (s)", ours_wall, theirs_wall)
PY
