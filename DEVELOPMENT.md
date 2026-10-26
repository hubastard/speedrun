# speedrun: development notes

How speedrun is built and how it behaves in detail, for working on it. Using it:
`README.md`. Benchmarks and what is still slow: `TO_IMPROVE.md`.

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
- `agent/ios/` — the iOS agent: an XCUITest runner serving the same protocol, for simulators
  (see `agent/ios/README.md`).
- `host/` — the `speedrun` binary (Odin). One persistent TCP connection through
  `adb forward`, `TCP_NODELAY`, a reused receive buffer and arena-allocated strings.
  - `main.odin`: command line and the latency benchmark. Its steps locate their target with
    `FIND` (the app searches its own hierarchy, one round trip) and read the full `TREE` only
    when that finds no visible exact match.
  - `device.odin`: the agent's lifecycle. The agent APK is embedded in the binary; each run
    pushes it if the device does not have this build yet, starts it, forwards its port and
    stops it at exit (Ctrl-C too).
  - `yaml.odin`, `flow.odin`, `runner.odin`, `console.odin`: reads flow files, runs them and
    prints their progress (see below).
  - `js.odin`, `js/`: JavaScript for flows, on QuickJS-ng (vendored in `js/quickjs-ng`, MIT):
    `engine.c` wraps it, `prelude.js` sets up what flow scripts see, including `faker`
    with Datafaker's English word lists (`js/datafaker`, Apache-2.0).
  - `system.odin`: commands that change the device rather than tap the app (permissions,
    launch arguments, orientation, dark and airplane mode, location, media, recording).
  - `image.odin`, `image/`: screenshot cropping and comparison, with stb_image (vendored,
    public domain).
- `build.sh` — builds the agent APK, the JavaScript engine and the image codecs, then
  `./speedrun` around them.
  Run it once (and after changing `agent/android/` or `host/`); nothing rebuilds at run time.
- `bench.yaml`, `bench_scenario.yaml` — benchmark flows; `flows/features.yaml` — coverage of
  the supported commands, each tap checked by an assertion; `flows/javascript` (no
  app needed), `flows/device/settings.yaml` (Android) and `flows/ignite/device.yaml` (iOS)
  cover scripts and the device commands; `flows/notifications` the iOS notification alert
  (its test app: `flows/notifications/install.sh`).
- `compare.sh` — benchmarks against Maestro (see `TO_IMPROVE.md`).

## Setup

1. Android: the SDK with `adb` on PATH, an emulator running (or a device with USB debugging).
   iOS: Xcode (27 tested) and a booted simulator.
2. To build: JDK 17 (Gradle comes from the wrapper in `agent/android/`, 8.14.3, downloaded on first
   run), Odin and a C compiler (`cc`) on PATH; Xcode for the iOS agent (skipped without it).
   Then, once:

```
./build.sh
```

`./speedrun` then needs only `adb` (Android) or Xcode's command-line tools (iOS), and `curl`
for flows whose scripts make HTTP requests.

## Run

Maestro flow files run as they are:

```
./speedrun test bench_scenario.yaml -e TIMES=5
./speedrun test -p ios bench_scenario_ios.yaml -e TIMES=5   # iOS simulator
```

speedrun picks a connected Android device, else the one booted simulator; `--platform` and
`--device` (a serial or a simulator UDID) choose. On iOS it starts the agent's runner with
`xcodebuild test-without-building`, which takes 3–6 s, so the runner outlives the run: the
next run on that simulator reuses it and starts in ~0.2 s (a runner of an older build is
replaced). It stops after 10 idle minutes (`SPEEDRUN_IDLE_S`), or with
`./speedrun --stop-agent`. Apps are controlled with `xcrun simctl`.

### A drop-in for `maestro test`

`speedrun test` takes `maestro test`'s arguments, so `maestro test …` becomes
`speedrun test …` (global options such as `-p` and `--device` may come before `test`, as with
`maestro`). Ported from Maestro 2.11.0 and checked against it on the same flows:

- One flow file runs with the live view (`--no-ansi`/`--plain` for plain lines) and, when it
  fails, prints the debug output folder. Several files, folders, or any `--format` run as a
  suite: `Waiting for flows to complete...`, a `[Passed]`/`[Failed] name (time) (error)` line
  per flow, then `N/M Flows Passed in Xs` or `N/M Flows Failed`, exit status 1 on a failure.
- Folders and `config.yaml` (or `--config`): `flows` globs (default `*`, the top level; `**`
  for subfolders; `!` excludes), `includeTags`/`excludeTags` with `--include-tags` /
  `--exclude-tags`, `executionOrder` (`flowsOrder`, `continueOnFailure`), `testOutputDir`.
  Flows run in Maestro's order and its error messages are kept.
- `-e`, and the variables Maestro sets for every flow: `MAESTRO_FILENAME`,
  `MAESTRO_DEVICE_UDID`, `MAESTRO_SHARD_ID`, `MAESTRO_SHARD_INDEX`, `MAESTRO_*` from the shell.
- `--format junit|html|html-detailed` with `--output` and `--test-suite-name` (default
  `report.xml` / `report.html`), with flow `tags` and `properties` (`junitId`,
  `junitClassname`).
- The debug output: `~/.maestro/tests/<yyyy-MM-dd_HHmmss>/<flow>/` with `commands.json`,
  `logs/maestro.log`, on a failure `screenshots/final.png`, and what `takeScreenshot` and
  `startRecording` write (`takeScreenshot/<path>.png`, `startRecording/<path>.mp4`, as in
  Maestro 2.11; a path leaving that folder is an error); `--debug-output`,
  `--flatten-debug-output`, `--test-output-dir` as in Maestro.
- `--shard-split N` / `--shard-all N` across connected devices (or `--device a,b`): one
  speedrun per device, `[shard N]` lines, a merged report and Maestro's summary box.
- `-c` / `--continuous`: reruns the flow when it or a flow it runs changes, or on Enter.

Accepted and ignored: `--headless`, `--screen-size` (web), `--api-url`, `--api-key`,
`--reinstall-driver`; `--analyze` (AI) says it is not supported; `--apple-team-id` (real iOS
devices) is an error. With several devices connected and no `--device`, Maestro asks which
one; speedrun takes a connected Android device, else the one booted simulator.

The latency breakdown (open the Settings app on the emulator first):

```
./speedrun --bench "Network & internet" 20
```

Run `--bench` with no target to list texts visible on the current screen. `./speedrun --help`
lists the options (`--port`, `--instrument`, `--plain`, `--timings`).

`--timings out.json` makes speedrun write its per-command record. With several devices
connected, `./speedrun --device <serial>` picks one.

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
4. **Flows** (`speedrun test`) — printed like `maestro test`. In a terminal, the live view: the
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
- Commands: `launchApp` (`appId`, `clearState`, `clearKeychain`, `stopApp`, `permissions`,
  `arguments`), `stopApp`, `killApp`, `clearState`, `setPermissions`, `tapOn`, `doubleTapOn`,
  `longPressOn`, `assertVisible`, `assertNotVisible`, `extendedWaitUntil`, `inputText`,
  `inputRandomText`/`Number`/`Email`/`PersonName`/`CityName`/`CountryName`/`ColorName`,
  `eraseText`, `hideKeyboard`, `back`, `pressKey`, `scroll`, `scrollUntilVisible`, `swipe`
  (direction, from an element, start/end in pixels or percent), `waitForAnimationToEnd`,
  `openLink` (`browser`, `autoVerify`), `takeScreenshot` (`cropOn`), `assertScreenshot`
  (`thresholdPercentage`, `cropOn`), `startRecording`, `stopRecording`, `addMedia`,
  `setLocation`, `travel`, `setOrientation`, `setDarkMode`, `toggleDarkMode`,
  `assertDarkMode`, `assertLightMode`, `setAirplaneMode`, `toggleAirplaneMode`,
  `clearKeychain` (a no-op on Android), `runFlow` (file or commands, `when`, `env`),
  `repeat` (`times`, `while`), `retry`, `evalScript`, `runScript` (`file`, `env`, `when`),
  `assertTrue`, `copyTextFrom`, `setClipboard`, `pasteText`, and the legacy `action: back`
  (and its other words). Every command takes `label` and `optional`.
- Selectors: `text` and `id` (case-insensitive regexes over the whole value; text also
  matches hint, content description and error; id also matches after the `/`), `index`,
  `enabled`, `selected`, `checked`, `focused`, `width`/`height`/`tolerance`, `below`,
  `above`, `leftOf`, `rightOf`, `containsChild`, `containsDescendants`, `childOf`, `traits`
  (`text`, `square`, `long-text`); on taps also `point`, `repeat`, `delay`,
  `retryTapIfNoChange`, `waitToSettleTimeoutMs`, `waitUntilVisible`.
- Conditions: `visible`, `notVisible`, `platform`, `true`.
- Env: `-e KEY=VALUE`, `MAESTRO_*` shell variables and `MAESTRO_FILENAME`, then the flow's
  `env:`, which wins (Maestro's order); sub-flows get their own scope, with the caller's
  `env:` defined before the file's own. The values of one `env:` are evaluated before any is
  defined, so they do not see each other. A default that `-e` can override is written as in
  Maestro: `env: { TIMES: ${TIMES || 1} }`.
- JavaScript, as Maestro runs it on GraalJS, here on QuickJS-ng (one engine per flow):
  `${...}` anywhere in a command is a script whose value replaces it (`\${...}` stays as
  written); each command's scripts run once, before it does. Undeclared names are
  `undefined`, env variables are global strings, a script's own variables and globals do not
  outlive it; `output` and `maestro` (`platform`, `copiedText`) do. Also `json()`,
  `relativePoint()`, `console.log` (its lines show under the command, in `--plain` output
  too) and `http.get/post/put/delete/request` with okhttp's rules (`headers`, a string
  `body`, `multipartForm`; the reply's `ok`, `status`, `body`, lowercased `headers`), sent
  through `curl`. `faker` has Datafaker's common providers (`name`, `internet`, `address`,
  `number`, `lorem`, `text`, `phoneNumber`, `color`, `company`, `bool`), with its English
  word lists; another provider or method fails the command, naming the call. `inputRandom*`
  draw from the same generators.
- YAML as Maestro's parser reads it: a plain (unquoted) value containing `: ` is an error
  ("mapping values are not allowed here"); quote it.

Not supported (an error naming it): AI commands and web flows (`url:`, the `css` selector).

`openLink: autoVerify` on Android picks the flow's app in the "Open with" dialog by its name,
as Maestro does; the agent reads that name on the device (the app's label in the device's
language) where Maestro pulls and parses the APK. Then Chrome's first-run screens.

On iOS (simulators), the same commands run, with Maestro's iOS behavior: `back` does nothing
(use the navigation bar's `BackButton`), `killApp` is `stopApp`, only ENTER, BACKSPACE, HOME and
LOCK keys act, and the hierarchy is the foreground app plus the status bars with Maestro's
attribute mapping; `clearState` reinstalls the app, as Maestro does; `hideKeyboard` swipes as
Maestro's does; airplane mode does nothing (no simulator has it). Permissions (`launchApp`
grants all by default, as in Maestro) are written to the simulator's privacy database the
way Maestro's `applesimutils` does, so neither is needed; location goes through
`simctl privacy`. The notification-permission alert is answered as Maestro's runner does: a
read that shows it taps Allow or Don't Allow, after the last permissions given (a flow's
`notifications:`, else `all:`, `allow` by default with `launchApp`); reads come from SpringBoard
while it is the only active app, so the alert is in the hierarchy, as in Maestro. Not yet:
real devices; Safari web views and cross-process window offsets are not
added to the hierarchy. How differs from
Maestro's runner: settle is XCTest's quiescence checked against the screen instead of
comparing screenshots, and after the first character the rest of the text is typed as soon as
the field shows it, at 100 characters per second (Maestro: a fixed 0.5 s pause, then 30). A
field that does not expose its value (React Native groups it with its label) gets Maestro's
pacing. `eraseText` sends no more deletes than the focused field holds characters (its
value's length, the placeholder's while it shows one) and none to an empty field.
`swipe` and `scroll` are Maestro's exactly: a touch that glides over the duration and lifts
still moving, so the content flings on, and how far it goes depends on that.
`scrollUntilVisible` drags without a fling instead: fast, then its last 40 points at 200
points per second, so the content stops as the touch lifts (a flinging swipe moves it
farther, but drifts for ~2 s that a settle would wait out).
Apps that `launchApp` starts run their UIKit animations 10 times faster, the counterpart of
Android's animations being off: speedrun launches them with UIKit's
`UIAnimationDragCoefficient` at 0.1 (the setting behind the simulator's Slow Animations,
which uses 10) and the `UIKit/UIPreferences` feature flag under which UIKit reads it
(`SIMCTL_CHILD_FEATUREFLAGS_ENABLED`, added to any flags already set). A flow's own
`UIAnimationDragCoefficient` launch argument (1: normal speed) wins. A tap that pushes a
screen or brings up the keyboard settles in about half the time; scrolling momentum and React Native's
JavaScript-driven animations are not UIKit animations and keep their speed, and apps opened
another way (`openLink`, the system) run at normal speed.

Known differences in how, not what:

- Hierarchy reads take 6–40 ms instead of hundreds, so lookups poll far more often within
  the same timeouts (17 s, 7 s optional, minus the time since the last interaction).
- Settle is the agent's (window switches, accessibility events, idle probe), not
  screenshot or hierarchy comparison; Maestro's extra settle before each tap is not repeated.
- `launchApp` (and `setPermissions` with `all`) grants or revokes only the app's runtime
  permissions not yet in that state. Maestro runs `pm grant`/`revoke` for every permission
  in the manifest; only runtime ones can change, so the end state is the same.
- Android without Maestro's driver app: launch `arguments` are typed intent extras on
  `am start`; `setLocation`/`travel` use the shell's test location providers (gps, network,
  fused; Android 12+, the emulator's GPS before), sent again every 2 s while the flow runs;
  `addMedia` copies to `Pictures`/`Movies` and runs the media scanner.
- `launchApp` returns once the app is asked to start, as Maestro's does (`am start`,
  `simctl launch`). The next command that reads or touches the screen waits for the app's
  UI (Android: a window of the app whose root can be read, op 17 LAUNCHED), then settles;
  commands that do not (permissions, location, scripts) run while the app starts. Maestro
  does not wait: a `scrollUntilVisible` right after a slow launch swiped on the home
  screen.
- A tap whose element is still there afterwards, unchanged, moved and on the same screen
  (same containers, most of its window's texts) missed it, and is tapped again where it is
  now (an app laying out after it looked settled). A screen the tap opened can repeat the
  tapped text elsewhere, as iOS titles a pushed screen with the row that opened it: that is
  no miss.
- After `inputText` and `eraseText`, a screen that shows no change is taken as settled after
  300 ms (1 s after taps): the keys have been delivered by then (on iOS the settle concludes
  only once testmanagerd has confirmed them), and a field that does not expose its text
  (React Native) shows none. On iOS the keyboard's suggestion bar is left out of what a
  settle compares: it updates on its own a few hundred ms after each key (reads include it).
- On iOS, element bounds are cut to the scroll views, tables and collection views around
  them, as Android's accessibility bounds are; XCUITest frames are not (Maestro uses them as
  they are). A list header scrolled above the list's top edge kept a frame on screen:
  `scrollUntilVisible` stopped and the tap landed outside the list (Ignite's
  `FavoritePodcast` after drags that stop where they lift; flings bounced to the exact top).
- `longPressOn` holds past the app's long-press delay instead of Maestro's 3 s: 500 ms (iOS's
  recognizers, React Native, Flutter) or Android's `long_press_timeout` setting (400 ms by
  default, 1.5 s at most), whichever is longer, plus 700 ms; `SPEEDRUN_LONG_PRESS_MS`
  overrides it (300 ms of margin was too little for an app's own 800 ms delay). A React
  Native favorite toggle went from 3.3 s to ~1.4 s.
- `scrollUntilVisible` checks that nothing is drawn over the element's center (a node later
  in the tree, outside its subtree and outside any other scroll view, smaller than half the
  screen: a sticky footer, iOS 26's floating search bar) and drags it just clear; after two
  such drags it stops checking (a closed side drawer that Android still places on screen
  covered every row of an Ignite list).
- A lookup that had to wait for its element settles once it shows, then finds it again: an
  element enters the hierarchy at its final place while it may still slide in (Stripe's
  payment sheet, presented once its SDK has loaded), and a tap then hits what is behind.
- iOS: a tap in a system sheet or alert (another process's view, "Save Password?") that
  changes nothing is tapped again, up to 3 times: such sheets ignore touches while they
  present, and their buttons always act.
- iOS `doubleTapOn` (and tapOn's `repeat`) is one event record with a finger per tap, at
  least 200 ms apart (agent op 23 TAPS): one record per tap waits ~230 ms for testmanagerd;
  a second press on one path, and XCTest's own doubleTap, land as one tap in React Native.
- iOS reads React Native's checkbox and radio state from the value it spells them into
  ("checkbox, checked"), and a text field's focus from XCTest's keyboard focus
  (`hasKeyboardFocus`; `hasFocus` is the focus engine's).
- iOS `hideKeyboard` fails when the keyboard stays up, as Maestro's does ("Couldn't hide the
  keyboard"); the keyboard is found by its element (the number pad's delete key has another
  id).
- Android `SWIPE` waits when its back-dated down time would come before the last gesture's
  (a tap just before): Android 17's input verifier drops such a gesture ("Down time went
  backwards").
- On iOS a quiescence wait is cut at 2 s (XCTest's application-state timeout, set through
  `_XCTSetApplicationStateTimeout`, as WebDriverAgent does), then the settle waits for the
  event loop only and compares signatures: under an open context menu animations never
  finish, and XCTest waited 60 s after every long press that opened one.
- iOS screens with an endless animation: an element moving on every read (an Animated or
  Reanimated loop updates the model layer every frame, so its accessibility frame changes)
  kept signatures from ever agreeing, and each settle ran to its 10 s timeout. Screen tracks
  each node by identity (depth, type, flags, texts, id; the n-th alike told apart by order)
  and when it began moving on every read; one moving for 500 ms while at most a third of
  the nodes move is restless: its frame is left out of the signature and its node carries
  flag 128 (`Restless`), which the host's hash skips too. A scroll or a JS-driven
  transition moves most nodes and is still waited for. Core Animation loops (spinners,
  Lottie) never counted: the model layer does not move and XCTest's quiescence ignores
  repeating animations. Measured on a test app: 14.3 s to 6.1 s for 10 commands, the
  same as with no animation.
- `SPEEDRUN_CONDITION_TIMEOUT_MS` replaces the 7 s of a `when:` check (not of an
  assertion or a lookup): flows that dismiss popups "if they show" after every action
  otherwise wait 7 s after each.
- `scrollUntilVisible` drags without a fling on both platforms, so the content stops as
  the touch lifts (Android: 50 ms, then still for 60 ms; iOS: see above). It reads the
  screen right after each drag and drags again as soon as the element is not on screen,
  the last drag shown; it settles only once the element shows, for the checks on visibility
  and centering on a still screen, as Maestro's. Maestro looks for the element for 500 ms
  before every swipe, then settles after it, a fling included. A drag moves the content by
  about its length (40% of the screen, less the touch slop), less than a fling, so long
  lists take more of them, and `speed` changes nothing. In Android Settings this took a
  scroll from 0.8 s to 0.33 s.
- Android `setLocation`/`travel` set the providers from the agent (one binder call each);
  `cmd location` is the fallback when the agent runs as the instrumentation.
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
  stops before lifting and the content moves by the drag distance: a still MOVE more than
  VelocityTracker's 40 ms "pointer stopped" threshold after the last moving one clears the
  velocity. Lifting late is not enough for `ScrollView` (React Native's lists), which reads
  the velocity before adding the UP to its tracker; `RecyclerView` adds it first.
- **`TYPE` uses the virtual keyboard key map**, like `adb shell input text`. Text with a
  character no key produces (most non-ASCII, emoji) goes in whole through accessibility
  instead: it replaces the focused field's selection and the cursor moves after it, as the
  IME Maestro switches to for such text commits it, without switching IMEs. With no focused
  editable field the command fails. Key events go through the IME before the field, about
  60 ms per key on the emulator. The last
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
- Animations are disabled by every run (normal practice for UI tests) and stay disabled;
  re-enable with `adb shell settings put global <name> 1` for `window_animation_scale`,
  `transition_animation_scale` and `animator_duration_scale`.
