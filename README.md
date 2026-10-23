# speedrun (Android)

A mobile E2E runner designed for speed. It runs Maestro flow files as they are, and proves
with numbers how fast one E2E step (read screen → find element → tap → wait until the UI
settles) can be, compared with the classic full-hierarchy dump and with Maestro running the
same files.

## Pieces

- `agent/android/` — Kotlin APK that runs on the device. One `UiAutomation` connection gives it the
  accessibility tree of every app, per-window frame stats and accessibility events. It
  listens on `127.0.0.1:7777` (on the device) and speaks a tiny binary protocol (documented
  at the top of `Agent.kt`): read the screen (`TREE`, `FIND`, `SCREEN` for all windows), act
  (`TAP`, `KEY`, `SWIPE`, `TYPE`, `ERASE`, `PRESS`), wait (`SETTLE`, `MARK`), plus `SHELL` and
  `SCREENSHOT`. Settle detection watches window switches, the active
  window's frames and accessibility events, then confirms with a main-thread idle probe.
  Two entry points share that logic (`Agent.kt`) and differ in how input is injected
  (`Injectors.kt`):
  - `ShellMain` (default): started with `app_process` as the shell user, which holds
    `INJECT_EVENTS`, so taps go straight to the hidden input manager, async (~1 ms per tap).
    It builds its own `UiAutomation` the way `uiautomator dump` does.
  - `AgentInstrumentation` (fallback, `--instrument`): injects through
    `UiAutomation`, which syncs input transactions before DOWN and after UP (~60 ms per tap).
- `agent/ios/` — the iOS agent, an XCUITest runner (in progress; see `agent/ios/README.md`).
- `host/` — the `speedrun` binary (Odin). One persistent TCP connection through
  `adb forward`, `TCP_NODELAY`, a reused receive buffer and arena-allocated strings.
  - `main.odin`: command line and the latency benchmark. Its steps locate their target with
    `FIND` (the app searches its own hierarchy, one round trip) and read the full `TREE` only
    when that finds no visible exact match.
  - `device.odin`: the agent's lifecycle. The agent APK is embedded in the binary; each run
    pushes it if the device does not have this build yet, starts it, forwards its port and
    stops it at exit (Ctrl-C too).
  - `yaml.odin`, `flow.odin`, `maestro.odin`, `console.odin`: runs Maestro flow files and
    prints them like Maestro does (see below).
- `build.sh` — builds the agent APK, then `./speedrun` around it. Run it once (and after
  changing `agent/android/` or `host/`); nothing rebuilds at run time.
- `bench.yaml`, `bench_scenario.yaml` — benchmark flows; `flows/features.yaml` — coverage of
  the supported Maestro commands, each tap checked by an assertion.
- `compare.sh` — runs one flow file with both tools and prints them side by side.

## Setup

1. Android SDK with `adb` on PATH, an emulator running (or a device with USB debugging).
2. To build: JDK 17 (Gradle comes from the wrapper in `agent/android/`, 8.14.3, downloaded on first
   run) and Odin on PATH. Then, once:

```
./build.sh
```

`./speedrun` then needs only `adb`.

## Run

Maestro flow files run as they are:

```
./speedrun --flow bench_scenario.yaml -e TIMES=5    # speedrun only
./compare.sh bench_scenario.yaml -e TIMES=5         # speedrun, then Maestro, side by side
./compare.sh flows/features.yaml                     # both tools must agree on every command
./race.sh bench_scenario.yaml -e TIMES=3            # both at once on two emulators, to watch
```

The latency breakdown (open the Settings app on the emulator first):

```
./speedrun --bench "Network & internet" 20
```

Run `--bench` with no target to list texts visible on the current screen. `./speedrun --help`
lists the options (`--port`, `--instrument`, `--plain`, `--timings`).

`bench_scenario.yaml` is 14 commands per iteration in Settings: navigation two levels deep,
scrolling both ways, and text input in a dialog (erase, type, assert, cancel, so nothing
changes). `compare.sh` starts the flow's app fresh before each tool, lines the two runs up
command by command (warning if their command sequences or statuses differ) and prints
medians per command, repeat iterations grouped. Then three totals per tool: the flow, the
time outside it (start-up and shutdown, measured as the whole run's wall clock minus the
flow: a slow tool costs that on every run) and the wall clock, all included. It needs
`maestro` and `python3` on PATH.
`--timings out.json` makes speedrun write its per-command record.

`race.sh` is the demo: it starts speedrun on one emulator and Maestro on another at the same
moment, so both screens can be watched side by side, and shows each tool's elapsed time and
current command until both finish. With a single emulator running, it creates
`<avd>_race` once (same system image and hardware settings) and boots it for Maestro; it
stays up for the next race. `SPEEDRUN_DEVICE`/`MAESTRO_DEVICE` choose the devices. Two
emulators share the machine, so numbers come from `compare.sh`, not from the race; and a
freshly booted emulator is slower at first, so the first race on it is not representative.
With several devices connected, `compare.sh` uses `ANDROID_SERIAL` or the first one, and
`./speedrun --device <serial>` picks one.

The agent starts as the shell user (`adb push` to `/data/local/tmp/speedrun-agent-<crc>.apk`,
skipped when that build is already there, then `app_process`); if it cannot start, speedrun
prints why and falls back to the instrumentation. `--instrument` forces the instrumentation.
Agent logs: `adb logcat -s SpeedrunAgent`.

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
4. **Flows** (`--flow`) — printed like `maestro test`. In a terminal, the live view: the
   whole flow as a list (🔲 pending, ⏳ running, ✅ done, ⚠️ warned, ⚪️ skipped, ❌ failed),
   redrawn in place, with the commands of a running repeat, retry or sub-flow nested under
   it and each finished command's time on the right. A flow longer than the terminal shows a
   window around the running command. When the output is piped, or with `--plain`, it is
   Maestro's plain format (`Tap on "X"... COMPLETED`) plus the time. Either way the run ends
   with the total and how many hierarchy reads it took. A failed lookup or assertion prints
   the windows and texts of the last read (below the view in live mode). `SPEEDRUN_DEBUG=1`
   prints every hierarchy read and shell command with its time (and implies `--plain`).

## Maestro flow files

The runner reads Maestro 2.11.0 syntax and follows Maestro's semantics, taken from its
source: how selectors match, which element wins, lookup timeouts and when they restart,
conditions, env scopes, gesture coordinates and key codes. It is strict: an unknown command
or field is an error, like in Maestro, and so is a Maestro command or field it does not
implement yet. A flow that loads therefore runs as written; nothing is skipped silently.
As in Maestro, `appId` does not open the app: a flow that needs it fresh starts with
`- launchApp`.

Supported:

- Config: `appId`, `name`, `env`, `onFlowStart`, `onFlowComplete` (other keys are ignored,
  as Maestro keeps them as metadata).
- Commands: `launchApp` (`appId`, `clearState`, `stopApp`), `stopApp`, `killApp`,
  `clearState`, `tapOn`, `doubleTapOn`, `longPressOn`, `assertVisible`, `assertNotVisible`,
  `extendedWaitUntil`, `inputText`, `eraseText`, `hideKeyboard`, `back`, `pressKey`,
  `scroll`, `scrollUntilVisible`, `swipe` (direction, from an element, start/end in pixels
  or percent), `waitForAnimationToEnd`, `openLink`, `takeScreenshot`, `clearKeychain`
  (a no-op on Android), `runFlow` (file or commands, `when`, `env`), `repeat` (`times`,
  `while`), `retry`. Every command takes `label` and `optional`.
- Selectors: `text` and `id` (case-insensitive regexes over the whole value; text also
  matches hint, content description and error; id also matches after the `/`), `index`,
  `enabled`, `selected`, `checked`, `focused`, `width`/`height`/`tolerance`, `below`,
  `above`, `leftOf`, `rightOf`, `containsChild`, `containsDescendants`, `childOf`; on taps
  also `point`, `repeat`, `delay`, `retryTapIfNoChange`, `waitToSettleTimeoutMs`.
- Conditions: `visible`, `notVisible`, `platform`, `true`.
- Env: `-e KEY=VALUE`, `MAESTRO_*` shell variables and `MAESTRO_FILENAME`, then the flow's
  `env:`, which wins (Maestro's order); sub-flows get their own scope. A default that `-e`
  can override is written as in Maestro: `env: { TIMES: ${TIMES || 1} }`. `${...}` takes a
  variable name, or `||` fallbacks over names and number or string literals.

Not supported yet (an error naming it): other JavaScript (`&&`, `??`, calls, arithmetic;
`evalScript`, `runScript`, `assertTrue`, `copyTextFrom`), `inputRandom*`, `setClipboard`,
`pasteText`, `setPermissions` and `launchApp.permissions`/`arguments`, `setLocation`,
`travel`, `setOrientation`, recording, `addMedia`, airplane and dark mode, AI commands,
`assertScreenshot`, `takeScreenshot.cropOn`, `openLink` with `browser`/`autoVerify`,
`traits`/`css` selectors, `waitUntilVisible: true`, non-ASCII `inputText`, web flows.

Known differences in how, not what:

- Hierarchy reads take 6–40 ms instead of hundreds, so lookups poll far more often within
  the same timeouts (17 s, 7 s optional, minus the time since the last interaction).
- Settle is the agent's (window switches, accessibility events, idle probe), not
  screenshot or hierarchy comparison; Maestro's extra settle before each tap is not repeated.
- `launchApp` grants the app's runtime permissions that are not granted yet. Maestro runs
  `pm grant` for every permission in the manifest; only runtime ones can change, so the end
  state is the same.
- Regexes use Odin's engine: Java-only syntax (lookaround, inline flags, `\p{...}`,
  possessive quantifiers) is rejected; patterns invalid in both match as plain text, like
  Maestro's fallback.
- When a selector matches in several windows, the active window's elements come first.
  Maestro gathers windows in a hash set, so its order there is arbitrary. Toasts are not in
  the hierarchy.

## Known limits (deliberate for now)

- **Settle cannot see frames on Android 12+.** `getWindowContentFrameStats()` reads the
  window's own layer, but windows draw into a child (BLAST) layer, so it reports no frames.
  Settle relies on window switches and an idle probe for screen transitions, and on
  accessibility events for in-place changes (scroll, typing). Apps send those at most every
  ~100 ms, so an in-place change costs a 120 ms quiet window. Ways under it: per-layer frames
  from SurfaceFlinger (`--frametimeline` has them, but a dump takes ~12 ms), or an in-app
  debug library that hooks `Choreographer` (the Espresso/Detox approach).
- **`SWIPE` timestamps are synthetic:** the gesture is injected at once with the timing of
  a real drag, so the app sees the right speed without the tool waiting it out. Only the
  first MOVE waits about one frame for the app (a scroll container must intercept it). Flows
  fling like `adb shell input swipe`, as Maestro does; without the fling flag the pointer
  stops before lifting and the content moves by the drag distance.
- **`TYPE` uses the virtual keyboard key map**, like `adb shell input text`: characters with
  no key sequence (most non-ASCII) are reported and the command fails. Key events go through
  the IME before the field, about 60 ms per key on the emulator, for Maestro too. The last
  key of `TYPE` and `ERASE` waits until the app has handled it: the IME applies DELs
  asynchronously, and spare DELs once deleted the first characters typed next.
- A full `TREE` read right after a screen change costs 25–70 ms: about 40 round trips to
  the app's main thread, since prefetching (at most 50 nodes per request) never spans
  sibling list items. Steps avoid it with `FIND` (~4 ms host view). Batched prefetch,
  warming the cache during settle and parallel fetches were measured and did not pay off.
  Later reads of the same screen are served from the accessibility cache (~3 ms).
- Only one `UiAutomation` client can exist at a time (agent, instrumentation or
  `uiautomator`); speedrun stops both kinds of agent before the baseline and at exit, and at
  start-up stops a Maestro driver left running by an interrupted Maestro run. Any other client
  holding it is reported, and the run stops.
- The shell agent relies on hidden APIs (`UiAutomation(Looper, IUiAutomationConnection)`,
  `InputManagerGlobal.injectInputEvent`), checked on Android 17 / API 37. Each one that is
  missing is logged and falls back (InputManager → UiAutomation injection; no UiAutomation →
  instrumentation).
- **A loaded host stalls the emulator.** Every hierarchy read waits on the target app's main
  thread; with the Mac busy, reads and shell commands were seen to block for 2–9 s and one
  `assertVisible` right after `launchApp` timed out. Rerun on a quieter machine before
  trusting a failure or a number.
- speedrun goes through the `adb` binary for `forward`/`push`/`install` (about 0.5 s of
  start-up per run). It could speak the adb wire protocol directly.
- Android only. iOS needs a separate XCUITest- or in-app-based agent.
- Animations are disabled by every run (normal practice for UI tests) and stay disabled;
  re-enable with `adb shell settings put global <name> 1` for `window_animation_scale`,
  `transition_animation_scale` and `animator_duration_scale`.
