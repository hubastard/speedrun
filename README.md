# Mobile E2E latency spike (Android)

Goal: prove, with numbers, how fast one E2E step (read screen → find element → tap → wait
until the UI settles) can be when the tooling is designed for speed, and compare it to the
classic full-hierarchy dump.

## Pieces

- `agent/` — Kotlin APK that runs on the device. One `UiAutomation` connection gives it the
  accessibility tree of every app and per-window frame stats. It listens on
  `127.0.0.1:7777` (on the device) and speaks a tiny binary protocol (documented at the top
  of `Agent.kt`). Settle detection watches the active window's frame stats plus a
  main-thread idle probe, with accessibility events as the fallback. Two entry points share
  that logic (`Agent.kt`) and differ in how input is injected (`Injectors.kt`):
  - `ShellMain` (default): started with `app_process` as the shell user, which holds
    `INJECT_EVENTS`, so taps go straight to the hidden input manager, async (~1 ms per tap).
    It builds its own `UiAutomation` the way `uiautomator dump` does.
  - `AgentInstrumentation` (fallback, `AGENT_MODE=instrument`): injects through
    `UiAutomation`, which syncs input transactions before DOWN and after UP (~60 ms per tap).
- `host/main.odin` — Odin client. One persistent TCP connection through `adb forward`,
  `TCP_NODELAY`, a reused receive buffer, the tree decoded into a `#soa` array, and all
  per-step strings in a virtual-memory arena freed in O(1) after each step.
- `run.sh` — disables animations, measures the `uiautomator dump` baseline, builds and
  starts everything, runs the benchmark.

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

The agent starts as the shell user (`adb push` to `/data/local/tmp/agent.apk`, then
`app_process`); if it cannot start, `run.sh` prints why and falls back to the
instrumentation. `AGENT_MODE=instrument ./run.sh ...` forces the instrumentation. Agent logs:
`adb logcat -s SpikeAgent`.

## What the output means

1. **Transport round trip** — the floor cost of any command. Expect well under 1 ms.
2. **Tree fetch** — device-side tree walk plus transfer and decode. Compare with the
   baseline `uiautomator dump` average printed earlier.
3. **Step loop**
   - *UI finished changing* — when the app actually stopped changing after the tap.
     This is the app's time, not the tool's.
   - *settle declared* — when the agent concluded it was settled. The gap to the line above
     is pure detection overhead.
   - *WHOLE STEP* — the number to put in the pitch.

## Known limits (deliberate for a spike)

- **~100 ms settle floor.** Android coalesces content-change accessibility events per window
  (about every 100 ms), so an outside observer needs a quiet window above that; it's set to
  120 ms. Ways under it: `UiAutomation.getWindowContentFrameStats()` for frame-precise
  timing, or an optional in-app debug library that hooks `Choreographer` (the Espresso/Detox
  approach).
- Full tree is re-walked each read. Next step: keep the tree on the device, apply changes
  from events, and send diffs.
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
