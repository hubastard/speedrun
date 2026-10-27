#!/usr/bin/env bash
# The benchmark app (Speedrun Bench): builds it, runs its flows (flows/) as speedrun's
# regression suite, and compares speedrun with Maestro on the same flows.
#   ./bench.sh build ios|android      expo prebuild, a Release build, installed on the device
#   ./bench.sh test ios|android       the suite with speedrun (pass/fail, per-flow times)
#   ./bench.sh compare ios|android    the suite with speedrun, then with Maestro: a table per
#                                     flow in results/<platform>.md
#   ./bench.sh maestro ios|android    the suite with Maestro only (the table takes speedrun's
#                                     last results)
#   ./bench.sh table ios|android      the table again, from the last results (RESULTS=<dir>)
# Each tool's per-command times go to results/<platform>-<tool>-debug: a flow Maestro fails
# gets an estimate of its full time (see table).
# Extra arguments go to `speedrun test` / `maestro test` (flow files instead of the folder,
# --include-tags ...). The device: DEVICE=<serial or simulator UDID>, else the first adb device
# (Android) or the booted simulator (iOS). Needs ../../speedrun (./build.sh); compare needs
# maestro; build needs Node, and Xcode or the Android SDK.
set -euo pipefail
cd "$(dirname "$0")"

CMD="${1:?usage: ./bench.sh build|test|maestro|compare|table ios|android [args...]}"
PLATFORM="${2:?usage: ./bench.sh build|test|maestro|compare|table ios|android [args...]}"
shift 2
SPEEDRUN="$(cd ../.. && pwd)/speedrun"
APP_ID=dev.speedrun.bench
RESULTS="${RESULTS:-results}"
mkdir -p "$RESULTS"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

case "$CMD:$PLATFORM" in
  table:ios | table:android) ;;
  *:ios)
    DEVICE="${DEVICE:-$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-Fa-f-]\{36\}\)) (Booted).*/\1/p' | head -1)}"
    [ -n "$DEVICE" ] || { echo "No booted simulator: boot one (xcrun simctl boot <udid>)."; exit 1; }
    ;;
  *:android)
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
  local tool="$1" report="$RESULTS/$PLATFORM-$1.xml" debug="$RESULTS/$PLATFORM-$1-debug"; shift
  rm -rf "$debug"
  # The flows folder, unless a flow file or folder is given.
  local flows=(flows) arg
  for arg in "$@"; do [ -e "$arg" ] && flows=(); done
  # On iOS speedrun keeps its agent between runs: stop it, so both tools start cold.
  [ "$PLATFORM" = ios ] && "$SPEEDRUN" --stop-agent >/dev/null 2>&1 || true
  local t0 t1 status=0
  t0=$(now_ms)
  if [ "$tool" = speedrun ]; then
    "$SPEEDRUN" test --device "$DEVICE" --format junit --output "$report" \
      --debug-output "$debug" --flatten-debug-output "$@" ${flows[@]+"${flows[@]}"} || status=$?
  else
    maestro --device "$DEVICE" test --format junit --output "$report" \
      --debug-output "$debug" --flatten-debug-output "$@" ${flows[@]+"${flows[@]}"} || status=$?
  fi
  t1=$(now_ms)
  [ "$PLATFORM" = ios ] && "$SPEEDRUN" --stop-agent >/dev/null 2>&1 || true
  echo "$((t1 - t0))" > "$RESULTS/$PLATFORM-$tool.wall"
  echo "== $tool: $(( (t1 - t0) / 1000 )) s wall clock, exit $status"
}

# The table in results/<platform>.md. A flow Maestro fails counts its time up to the failure,
# which says little: it fails some flows early, others after waiting out timeouts. So it also
# gets an estimate of its full time: Maestro's time up to the failing step, plus speedrun's time
# for the rest of the flow (that step included) at Maestro's pace on the flow so far (its time
# over speedrun's for the same steps; before 5 s of them, its pace on the flows both passed).
table() {
  python3 - "$PLATFORM" "$RESULTS" <<'PY'
import glob, json, os, re, sys, xml.etree.ElementTree as ET
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

# Per-command times: Maestro names a flow's folder after the flow, speedrun after its file.
stems = {}
for f in glob.glob("flows/*.yaml"):
    m = re.search(r"^name: *(.+)$", open(f).read(), re.M)
    if m: stems[m[1].strip()] = os.path.basename(f)[:-5]
def steps(tool, name):
    """The flow's top-level commands: (command, status, ms). Maestro marks nesting with a
    depth; speedrun's nested commands start within their runFlow / repeat / retry."""
    for folder in (name, stems.get(name)):
        path = f"{results}/{platform}-{tool}-debug/{folder}/commands.json"
        if folder and os.path.exists(path): break
    else:
        return None
    out, end = [], -1
    for c in json.load(open(path)):
        cmd, m = next(iter(c["command"])), c["metadata"]
        if cmd in ("defineVariablesCommand", "applyConfigurationCommand"): continue
        ts, ms = m.get("timestamp", 0), m.get("duration") or 0
        if m.get("depth", 0) > 0 or ("depth" not in m and ts < end): continue
        out.append((cmd, m["status"], ms))
        if cmd in ("runFlowCommand", "repeatCommand", "retryCommand"): end = ts + ms
    return out
both = [n for n in (ours or {}) if n in (theirs or {}) and not ours[n][1] and not theirs[n][1]]
pace_all = sum(theirs[n][0] for n in both) / sum(ours[n][0] for n in both) if both else None
def estimate(name):
    m, s = steps("maestro", name), steps("speedrun", name)
    if not m or not s: return None
    k = next((i for i, c in enumerate(m) if c[1] == "FAILED"), None)
    # The same commands up to the failure, or the runs went different ways.
    if k is None or len(s) <= k or any(m[i][0] != s[i][0] for i in range(k + 1)): return None
    m_before, s_before = sum(c[2] for c in m[:k]), sum(c[2] for c in s[:k])
    pace = m_before / s_before if s_before >= 5000 else pace_all
    if not pace: return None
    return theirs[name][0] - sum(c[2] for c in m[k:]) / 1000 + sum(c[2] for c in s[k:]) / 1000 * pace

def cell(c, est=None):
    if c is None: return "–"
    t, failed = c
    return f"{t:.0f} s" + (" ✗" if failed else "") + (f" (~{est:.0f} s)" if est else "")
lines = [f"| Flow ({platform}) | speedrun | Maestro | Speedup |", "|---|---:|---:|---:|"]
names = sorted(set(ours or {}) | set(theirs or {}))
estimated = {}
for n in names:
    a, b = (ours or {}).get(n), (theirs or {}).get(n)
    est = estimate(n) if a and b and not a[1] and b[1] else None
    speed = ""
    if a and b and a[0] > 0 and not a[1]:
        if not b[1]: speed = f"{b[0] / a[0]:.1f}x"
        elif est: speed = f"~{est / a[0]:.1f}x"
    if est: estimated[n] = est
    lines.append(f"| {n} | {cell(a)} | {cell(b, est)} | {speed} |")
def total(cases, only=None): return sum(t for n, (t, _) in cases.items() if only is None or n in only) if cases else None
ta, tb = total(ours), total(theirs)
lines.append(f"| **All flows** | **{ta:.0f} s** | **{tb:.0f} s** | **{tb / ta:.1f}x** |" if ta and tb else
             f"| **All flows** | {ta or 0:.0f} s | {tb or 0:.0f} s | |")
if both and len(both) < len(names):
    ba, bb = total(ours, both), total(theirs, both)
    lines.append(f"| **Flows both passed ({len(both)})** | **{ba:.0f} s** | **{bb:.0f} s** | **{bb / ba:.1f}x** |")
failed_maestro = [n for n in names if theirs and n in theirs and theirs[n][1]]
if ta and tb and failed_maestro and all(n in estimated for n in failed_maestro if ours and n in ours and not ours[n][1]):
    te = sum(estimated.get(n, theirs[n][0]) for n in theirs)
    lines.append(f"| **All flows, Maestro's failures estimated** | **{ta:.0f} s** | **~{te:.0f} s** | **~{te / ta:.1f}x** |")
if ours_wall and theirs_wall:
    lines.append(f"| **Wall clock** | **{ours_wall:.0f} s** | **{theirs_wall:.0f} s** | **{theirs_wall / ours_wall:.1f}x** |")
passed = lambda c: f"{sum(not f for _, f in c.values())}/{len(c)}" if c else "–"
lines.append(f"\nPassed: speedrun {passed(ours)}, Maestro {passed(theirs)}. ✗: failed (its time up to the "
             "failure); ~: estimated, had Maestro finished the flow.")
out = "\n".join(lines)
open(f"{results}/{platform}.md", "w").write(out + "\n")
print(out)
PY
}

case "$CMD" in
  build) build ;;
  test) run speedrun "$@"; table ;;
  maestro) run maestro "$@"; table ;;
  table) table ;;
  compare)
    run speedrun "$@"
    # Maestro draws its live view over the screen: start it on a clear one.
    if [ -t 1 ]; then printf '\033[H\033[2J'; fi
    run maestro "$@"
    table
    ;;
  *) echo "usage: ./bench.sh build|test|maestro|compare|table ios|android [args...]"; exit 1 ;;
esac
