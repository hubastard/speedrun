#!/usr/bin/env bash
# The web benchmark: an app's tests with each tool, as a CI job runs them: one warm-up run,
# then RUNS timed runs (default 3). A run's time is the wall clock of the tool's command, its
# start-up included. The table goes to results/<app>.md: the median of the runs that passed
# (a failed run stops early), the pass count, and each run's time (✗: failed).
#   ./run.sh todomvc|rwa [tool...]     tools: speedrun playwright cypress maestro
# maestro runs only when named: on the Real World App, one run took over 30 minutes.
# Needs ../../speedrun (./build.sh), ./setup.sh run once, and maestro to run it. The app's
# servers are started on 127.0.0.1 and stopped at the end (left alone if already up).
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:?usage: ./run.sh todomvc|rwa [tool...]}"
shift
RUNS="${RUNS:-3}"
SPEEDRUN="$(cd ../.. && pwd)/speedrun"
export MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true CYPRESS_CRASH_REPORTS=0
case "$APP" in
  # Playwright's default viewport for every tool; the Real World App's own Cypress viewport.
  todomvc) SIZE=1280x720; FLOWS=todomvc/flow.yaml; URL=http://127.0.0.1:8791/ ;;
  rwa) SIZE=1280x1000; FLOWS=rwa/flows; URL=http://127.0.0.1:3001/ ;;
  *) echo "app: todomvc or rwa"; exit 1 ;;
esac
TOOLS=("${@:-speedrun playwright cypress}")
read -r -a TOOLS <<< "${TOOLS[*]}"
mkdir -p results

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

# The app's servers, in a process group of their own (the Real World App's are several).
SERVER_PID=
cleanup() { [ -n "$SERVER_PID" ] && kill -- -"$SERVER_PID" 2> /dev/null || true; }
trap cleanup EXIT
if ! curl -s -o /dev/null "$URL"; then
  case "$APP" in
    todomvc) perl -e 'setpgrp; exec @ARGV' python3 -m http.server 8791 --bind 127.0.0.1 --directory todomvc/site \
               > "results/$APP-server.log" 2>&1 & ;;
    rwa) perl -e 'chdir shift; setpgrp; exec @ARGV' rwa/app yarn start:ci > "results/$APP-server.log" 2>&1 & ;;
  esac
  SERVER_PID=$!
  for _ in $(seq 240); do
    if curl -s -o /dev/null "$URL" && { [ "$APP" != rwa ] || curl -s -o /dev/null http://127.0.0.1:3000/; }; then break; fi
    sleep 0.5
  done
fi

# One run of a tool; its exit status says whether every test passed. Each test resets the
# app itself (the Real World App's seed endpoint).
run_tool() {
  case "$1" in
    speedrun) "$SPEEDRUN" test --headless --screen-size "$SIZE" "$FLOWS" ;;
    playwright) npx playwright test -c "$APP/playwright" ;;
    cypress) npx cypress run --project "$APP/cypress" ;;
    maestro) maestro test --headless --screen-size "$SIZE" "$FLOWS" ;;
  esac
}

: > "results/$APP.txt.new"
for tool in "${TOOLS[@]}"; do
  times=()
  passed_times=()
  passed=0
  for i in $(seq 0 "$RUNS"); do
    rm -rf "$APP"/playwright/test-results "$APP"/cypress/cypress
    t0=$(now)
    status=0
    run_tool "$tool" > "results/$APP-$tool-$i.log" 2>&1 || status=$?
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
      times+=("$(printf '%.2f' "$secs")")
    else
      times+=("$(printf '%.2f' "$secs")✗")
    fi
  done
  median=-
  if [ "$passed" -gt 0 ]; then
    median=$(printf '%s\n' "${passed_times[@]}" | sort -n | awk '{ a[NR] = $1 } END { m = NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2; printf "%.2f s", m }')
  fi
  echo "$tool|$median|$passed/$RUNS|${times[*]}" >> "results/$APP.txt.new"
done

{
  echo "| Tool ($APP) | Median of passed runs | Passed | Runs (s) |"
  echo "|---|---:|---:|---|"
  while IFS='|' read -r tool median passed runs; do
    echo "| $tool | $median | $passed | $runs |"
  done < "results/$APP.txt.new"
} > "results/$APP.md"
rm "results/$APP.txt.new"
cat "results/$APP.md"
