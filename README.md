# Mobile E2E latency spike (Android)

Goal: prove, with numbers, how fast one E2E step (read screen → find element → tap → wait
until the UI settles) can be when the tooling is designed for speed, and compare it to the
classic full-hierarchy dump.

## Pieces

- `agent/` — Kotlin APK that runs on the device. One `UiAutomation` connection gives it the
  accessibility tree of every app, per-window frame stats and accessibility events. It
  listens on `127.0.0.1:7777` (on the device) and speaks a tiny binary protocol (documented
  at the top of `Agent.kt`): read the screen (`TREE`, `FIND`), act (`TAP`, `KEY`, `SWIPE`,
  `TYPE`, `ERASE`) and wait (`SETTLE`). Settle detection watches window switches, the active
  window's frames and accessibility events, then confirms with a main-thread idle probe.
  Two entry points share that logic (`Agent.kt`) and differ in how input is injected
  (`Injectors.kt`):
  - `ShellMain` (default): started with `app_process` as the shell user, which holds
    `INJECT_EVENTS`, so taps go straight to the hidden input manager, async (~1 ms per tap).
    It builds its own `UiAutomation` the way `uiautomator dump` does.
  - `AgentInstrumentation` (fallback, `AGENT_MODE=instrument`): injects through
    `UiAutomation`, which syncs input transactions before DOWN and after UP (~60 ms per tap).
- `host/main.odin` — Odin client. One persistent TCP connection through `adb forward`,
  `TCP_NODELAY`, a reused receive buffer, nodes decoded into a `#soa` array, and all
  per-step strings in a virtual-memory arena freed in O(1) after each step. Steps locate
  their target with `FIND` (the app searches its own hierarchy, one round trip) and read the
  full `TREE` only when that finds no visible exact match.
- `run.sh` — disables animations, measures the `uiautomator dump` baseline, builds and
  starts everything, runs the benchmark.
- `bench.yaml`, `bench_scenario.yaml` — the same two benchmarks as Maestro flows.
- `compare.sh` — runs the scenario with both tools and prints them side by side.

## Setup

1. Android SDK with `adb` on PATH, an emulator running (or a device with USB debugging).
2. JDK 17. Gradle comes from the wrapper in `agent/` (Gradle 8.14.3, downloaded on first run).
   Build the agent: `cd agent && ./gradlew assembleDebug`
3. Odin on PATH.

## Run

Open the Settings app on the emulator, then:

```
./run.sh "Network & internet" 20
```

Run with no target to list texts visible on the current screen.

A longer flow, 14 commands per iteration in Settings: navigation two levels deep, scrolling
both ways, and text input in a dialog (erase, type, assert, cancel, so nothing changes):

```
./run.sh --scenario 10      # this tool only (restarts Settings on its home screen)
./compare.sh 5              # this tool, then Maestro on bench_scenario.yaml, side by side
```

The scenario is `SCENARIO` in `host/main.odin`; `bench_scenario.yaml` is the same flow for
Maestro, command for command. Keep them in sync. `compare.sh` needs `maestro` and `python3`
on PATH; its totals exclude each tool's start-up (Maestro's is printed separately).

The agent starts as the shell user (`adb push` to `/data/local/tmp/agent.apk`, then
`app_process`); if it cannot start, `run.sh` prints why and falls back to the
instrumentation. `AGENT_MODE=instrument ./run.sh ...` forces the instrumentation. Agent logs:
`adb logcat -s SpikeAgent`.

## What the output means

1. **Transport round trip** — the floor cost of any command. Expect well under 1 ms.
2. **Tree fetch** — device-side tree walk plus transfer and decode. Compare with the
   baseline `uiautomator dump` average printed earlier.
3. **Step loop**
   - *FIND target on device* — locating the target after the previous screen settled.
     *TREE fallbacks* counts the rounds where `FIND` brought back no visible exact match and
     the full tree was read instead (e.g. text an app sets only through an accessibility
     delegate, which `FIND` cannot see).
   - *UI finished changing* — when the app actually stopped changing after the tap.
     This is the app's time, not the tool's.
   - *settle declared* — when the agent concluded it was settled. The gap to the line above
     is pure detection overhead.
   - *WHOLE STEP* — the number to put in the pitch.
4. **Scenario** (`--scenario`) — median time per command, named as in the Maestro flow, then
   per iteration split into finding elements, actions and settling (the app's time plus
   detection), and the change signals settle saw. *LOOP TOTAL* compares with the
   `repeat` block of `bench_scenario.yaml`.

## Known limits (deliberate for a spike)

- **Settle cannot see frames on Android 12+.** `getWindowContentFrameStats()` reads the
  window's own layer, but windows draw into a child (BLAST) layer, so it reports no frames.
  Settle relies on window switches and an idle probe for screen transitions, and on
  accessibility events for in-place changes (scroll, typing). Apps send those at most every
  ~100 ms, so an in-place change costs a 120 ms quiet window. Ways under it: per-layer frames
  from SurfaceFlinger (`--frametimeline` has them, but a dump takes ~12 ms), or an in-app
  debug library that hooks `Choreographer` (the Espresso/Detox approach).
- **`SWIPE` is a drag that never flings:** the pointer stops 60 ms before lifting, so the
  content moves by the drag distance (minus 16 dp of touch slop) and scrolling is
  deterministic. Its timestamps are synthetic and it is injected at once, except the first
  MOVE, which waits about one frame for the app (a scroll container must intercept it).
  Maestro flings, so scroll steps are not identical between the two tools.
- **`TYPE` uses the virtual keyboard key map**, like `adb shell input text`: characters with
  no key sequence (most non-ASCII) are reported and the command fails. Key events go through
  the IME before the field, about 60 ms per key on the emulator, for Maestro too.
- A full `TREE` read right after a screen change costs 25–70 ms: about 40 round trips to
  the app's main thread, since prefetching (at most 50 nodes per request) never spans
  sibling list items. Steps avoid it with `FIND` (~4 ms host view). Batched prefetch,
  warming the cache during settle and parallel fetches were measured and did not pay off.
  Later reads of the same screen are served from the accessibility cache (~3 ms).
- Only one `UiAutomation` client can exist at a time (agent, instrumentation or
  `uiautomator`); `run.sh` stops both kinds of agent before the baseline and at exit.
- The shell agent relies on hidden APIs (`UiAutomation(Looper, IUiAutomationConnection)`,
  `InputManagerGlobal.injectInputEvent`), checked on Android 17 / API 37. Each one that is
  missing is logged and falls back (InputManager → UiAutomation injection; no UiAutomation →
  instrumentation).
- Host goes through the `adb` binary for `forward`/`push`/`install`. A product would speak
  the adb wire protocol directly.
- Android only. iOS needs a separate XCUITest- or in-app-based agent.
- Animations are disabled by the script (normal practice for UI tests); re-enable afterwards.
