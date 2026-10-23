#!/usr/bin/env bash
# Usage: ./compare.sh [iterations]
# Runs the multi-step scenario N times with this tool (./run.sh --scenario) and N times with
# Maestro (bench_scenario.yaml), each from a fresh Settings home screen, then prints both
# side by side, per command. Loop totals exclude each tool's start-up. Needs maestro and
# python3 on PATH (python3 reads Maestro's per-command report).
set -euo pipefail
cd "$(dirname "$0")"

ITERS="${1:-5}"
OUT="$(mktemp -d -t spike_compare.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }

command -v maestro >/dev/null || { echo "maestro not found on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on PATH"; exit 1; }

# run.sh stops its agent at exit, so Maestro's driver can take the UiAutomation slot after it.
./run.sh --scenario "$ITERS" | tee "$OUT/spike.txt"

echo
echo "== Maestro: maestro test -e TIMES=$ITERS bench_scenario.yaml"
adb shell am force-stop com.android.settings
adb shell am start -W -n com.android.settings/.Settings >/dev/null
t0=$(now_ms)
maestro test --debug-output "$OUT/maestro" --flatten-debug-output -e TIMES="$ITERS" bench_scenario.yaml
t1=$(now_ms)

python3 - "$OUT/spike.txt" "$OUT/maestro" "$((t1 - t0))" <<'PY'
import glob, json, re, statistics, sys

spike_txt, maestro_dir, maestro_wall_ms = sys.argv[1], sys.argv[2], int(sys.argv[3])

# This tool: per-command medians and totals from the host's report.
text = open(spike_txt).read()
ours = {int(m.group(1)): (m.group(2).strip(), float(m.group(3)))
        for m in re.finditer(r"^\s+(\d+) (.+?)\s+median\s+([\d.]+)", text, re.M)}
our_iter = float(re.search(r"ITERATION\s+median\s+([\d.]+)", text).group(1))
our_loop = float(re.search(r"LOOP TOTAL \(wall clock, \d+ iterations\): ([\d.]+) s", text).group(1))

# Maestro: commands.json lists the repeat block, then every command run inside it (depth 1).
report = json.load(open(glob.glob(f"{maestro_dir}/**/commands*.json", recursive=True)[0]))
inner = [e["metadata"] for e in report if e["metadata"].get("depth") == 1]
loop_ms = next(e["metadata"]["duration"] for e in report if "repeatCommand" in e["command"])
n = len(ours)
per_cmd = [[m["duration"] for m in inner[k::n]] for k in range(n)]
per_iter = [sum(m["duration"] for m in inner[i:i + n]) for i in range(0, len(inner), n)]

med = statistics.median
print("\n== Side by side (median ms per command; Maestro / this tool)")
print(f"   {'command':48s} {'this tool':>10s} {'Maestro':>10s} {'ratio':>7s}")
for k in range(1, n + 1):
    label, o = ours[k]
    m = med(per_cmd[k - 1])
    print(f"{k:2d} {label:48s} {o:10.0f} {m:10.0f} {m / o:6.1f}x")
m_iter = med(per_iter)
print(f"   {'ITERATION':48s} {our_iter:10.0f} {m_iter:10.0f} {m_iter / our_iter:6.1f}x")
print(f"   {'LOOP TOTAL (s, %d iterations)' % len(per_iter):48s} {our_loop:10.1f} {loop_ms / 1000:10.1f} {loop_ms / 1000 / our_loop:6.1f}x")
print(f"   (Maestro start-up, outside the loop: {(maestro_wall_ms - loop_ms) / 1000:.1f} s)")
PY
