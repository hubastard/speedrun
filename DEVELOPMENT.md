# Speedrun: development notes

How speedrun is built and how it behaves in detail, for working on it. Using it:
`README.md` and `docs/` (command line, Maestro compatibility, troubleshooting). Benchmarks and
what is still slow: `TO_IMPROVE.md`.

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
    stops it at exit (Ctrl-C too). On iOS the runner stays up for the next run; Ctrl-C ends
    only one that never answered, without asking it: it serves one client at a time, and
    the run's own connection is still open (a ping there waited forever, and Ctrl-C did
    nothing). A second Ctrl-C exits at once, whatever the cleanup is doing.
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
- `bench/app` — Speedrun Bench, a React Native app made to be tested, and its 19 flows: the
  regression suite (every command and selector, on Android and iOS with the same files) and
  the benchmark against Maestro (`bench/app/bench.sh`; see its README).
- `bench/settings` — the Settings benchmark, `bench_scenario_android.yaml` and
  `bench_scenario_ios.yaml`: 14 commands per lap on Android's and iOS's Settings app
  (navigation two levels deep, scrolling both ways, text input), `-e TIMES=3` for three laps;
  `./compare.sh bench/settings/bench_scenario_android.yaml -e TIMES=3`.
- `flows/features.yaml` — coverage of the supported commands on Android's Settings, each tap
  checked by an assertion; `flows/javascript` (no app needed) and
  `flows/device/settings.yaml` (Android) cover scripts and the device commands;
  `flows/notifications` the iOS notification alert (its test app:
  `flows/notifications/install.sh`).
- `compare.sh` — one flow with speedrun, then Maestro, side by side per command (see
  `TO_IMPROVE.md`).

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

## CI (GitHub Actions)

- `.github/workflows/release-linux.yml`: on a `v*` tag, builds speedrun on Ubuntu (Android
  only: the iOS agent needs a Mac) with `package.sh` and attaches
  `speedrun-<tag>-linux-x86_64.tar.gz` to the tag's release, creating the release if it has
  none yet. The macOS package is still built and attached by hand. Run it by hand
  (`gh workflow run release-linux.yml -f tag=v0.1.7`) to rebuild a tag.
- `.github/workflows/journey.yml`: after every push to `main`, builds speedrun and Speedrun
  Bench from source and runs the benchmark journey (`bench/journey/journey.yaml`) with
  speedrun on an Android 15 emulator (Ubuntu, KVM) and an iOS simulator (macOS runner, the
  newest Xcode installed). The JUnit report and the debug output are kept as artifacts.
- `.github/workflows/bench-app.yml`: when Speedrun Bench's sources change on `main`, builds
  it for an Android emulator and an iOS simulator and uploads both to the `bench-app`
  pre-release, named after the sources' hash (`bench/app/bench.sh hash`).
  `bench.sh install <platform>` and the Journey workflow download the app matching the
  checkout instead of building it (no Node needed), and build it only when none matches.

Both pin Odin (`ODIN_VERSION`) to the version speedrun is developed with.

## Run

Maestro flow files run as they are:

```
./speedrun test flows/features.yaml
./speedrun test -p ios bench/app/flows/        # the benchmark app's suite, on a simulator
```

Speedrun picks a connected Android device, else the one booted simulator; `--platform` and
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
- The debug output: `~/.speedrun/tests/<yyyy-MM-dd_HHmmss>/<flow>/` with `commands.json`,
  `logs/speedrun.log`, on a failure `screenshots/final.png`, and what `takeScreenshot` and
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
  screen: a sticky footer, iOS 26's floating search bar) and drags it just clear: up past a
  bar in the screen's bottom half, down past one in its top half; after two such drags it
  stops checking (a closed side drawer that Android still places on screen covered every row
  of an Ignite list).
- A tap makes the same check (on iOS, the hit test confirms it: its tree is ordered by
  place on screen), and an element something fixed covers (outside the list around it: a
  sticky footer, the keyboard) is dragged just clear by that list, the nearest that scrolls
  the cover's way, then found again; up to two drags, while it moves. A drag can move the
  list less than the finger (half of a short one on Speedrun Bench's product page, on
  Android): the second goes as much farther. Still covered (the keyboard over a screen that
  does not scroll), it is tapped in the middle of the largest part that shows, unless that
  is a sliver (under a 60th of the screen's width) or under something else; else at its
  center, as before. On a 320x640 emulator (CI's default), the journey's size and quantity
  taps hit the product page's footer, and the sign-in's Next the keyboard; they now pass.
  A cover inside the same list (an OTP field's digit boxes drawn over its hidden input)
  moves with the element: no drag, the center.
- While its drags move the content, `scrollUntilVisible` stops on an element only once it
  shows as much as asked (`visibility`), and drags an element its list cuts on the side it
  comes in from (iOS) just far enough to bring it all in, a margin past the list's edge or
  past a bar over that edge. iOS 26 Settings' "Developer" row came in as a 7-point sliver
  inside the bottom toolbar: settled on, it was taken as covered, and the clearing drag,
  which compared the toolbar with the sliver's middle, went the wrong way, back off screen
  (a third drag; 2.5 s for the scroll, 1.4–1.8 s now). A full stride also pulls a list that
  ends just after the element past its end, and its bounce costs the settle ~0.1–0.4 s.
- Sideways, `scrollUntilVisible` drags across the list the element is in (iOS keeps an
  element its list has scrolled away in the hierarchy, with its frame), else across a list
  that scrolls sideways (Android's `HorizontalScrollView` and `ViewPager`, or items side by
  side; on iOS, content past a scroll view's left or right edge), the one under the screen's
  center first, and only then across the center, where Maestro drags; a drag that moves
  nothing moves on to the next. Its drags run from 90% of the screen's width, or a margin
  inside the list, to 10%: a drag that does not fling moves a list by its length, and a
  paging list turns the page only past half of it. Speedrun Bench's card list, above the
  center, failed after 20 s of drags that moved nothing; its card 25 now takes 9 drags,
  5.9 s on iOS, 1.7 s on Android (a `repeat` of flinging `swipe`s on the list: 37 s on
  iOS; the drag flow went from 74 s to 41 s on iOS, 40 s to 23 s on Android). Its
  onboarding pager sprang back after each drag of 40% on iOS; on Android two pages took
  5.6 s, now 1.2 s.
- While its drags move the content, an element partly shown that moved since the previous
  read is read again (for up to a second after the drag), not dragged on: the list moves on
  its own, a page snapping into place, a bounce off the list's end, and a drag stops it
  there and carries it past the element. Two pages of the onboarding pager took 7 drags and
  4.8 s (each of the last ones pulled the list past its end), now 2 and 1.6 s.
- A lookup that had to wait for its element settles once it shows, then finds it again: an
  element enters the hierarchy at its final place while it may still slide in (Stripe's
  payment sheet, presented once its SDK has loaded), and a tap then hits what is behind.
- A tap waits while a loading overlay covers its element. Apps draw one over a screen while it
  loads, see-through and fading in and out, with a spinner: the element shows through and
  stays in the hierarchy, but the overlay takes the tap, the settle does not wait for the
  spinner (an endless animation), and the fade shows nowhere (the hierarchy has no opacity;
  iOS drops a view once it is fully transparent). On iOS, while a spinner or progress bar
  shows outside the element, the agent asks what a touch at the element's center reaches
  (HIT: the accessibility hit test XCTest's isHittable uses, ~30 ms), and the overlay takes
  the tap when that is neither the element, inside it, nor one of its containers. The tree
  cannot tell: iOS orders siblings by their place on screen, not as drawn (an overlay from a
  screen's top edge comes before content below a padding), and reports a spinner at its own
  size whatever its view's (`flex: 1`). Android orders its tree by place on screen too, but
  its parents are the views' own: there the overlay is a node over the element's center,
  outside it and not one of its containers, that is a spinner or holds one. Once the overlay
  is gone, the screen settles and the element is found again; after the lookup's time (17 s)
  the tap goes ahead anyway. A payment app's amount keypad lost its first digit this way
  (v0.1.5 relied on the tree's order on both platforms, and missed it; v0.1.6 still did on
  Android); Speedrun Bench's PIN screen loads under such an overlay for 1.5 s. Maestro waits out
  the spinner (its screenshots change). Assertions still see the element, as Maestro's do.
- iOS: a tap in a system sheet or alert (another process's view, "Save Password?") that
  changes nothing is tapped again, up to 3 times: such sheets ignore touches while they
  present, and their buttons always act.
- iOS `doubleTapOn` (and tapOn's `repeat`) is one event record with a finger per tap, at
  least 200 ms apart (agent op 23 TAPS): one record per tap waits ~230 ms for testmanagerd;
  a second press on one path, and XCTest's own doubleTap, land as one tap in React Native.
  Each of those touches is held 100 ms: 10 ms ones missed double taps and repeats.
- An iOS tap is a touch held 20 ms (100 ms before). React Native gives a touch to the scroll
  view around it when a scroll event comes while it is down, even from a nested scroll view:
  a carousel paging itself every 2.5 s cancelled a press on a button beside it (3 taps in 40
  at 100 ms; Speedrun Bench's product page, every run of a flow tapping + and − there), as
  it does for a person. The shorter the touch, the rarer: 20 ms, 2 in 80; 10 ms, none. But
  UIKit's controls need it to span a display frame: a UISwitch never toggled at 12 ms, once
  in 6 at 15 ms, always from 17 ms. 20 ms also makes a tap ~100 ms faster.
- iOS reads React Native's checkbox and radio state from the value it spells them into
  ("checkbox, checked"), and a text field's focus from XCTest's keyboard focus
  (`hasKeyboardFocus`; `hasFocus` is the focus engine's).
- iOS `hideKeyboard` fails when the keyboard stays up, as Maestro's does ("Couldn't hide the
  keyboard"); the keyboard is found by its element (the number pad's delete key has another
  id).
- Android `SWIPE` waits when its back-dated down time would come before the last event
  injected: Android 17's input verifier drops a gesture whose down time goes backwards
  ("Down time went backwards"), and one that starts, in event time, before the previous one
  lifted came out reversed (touch resampling mixed the two: a swipe up after a swipe right
  read as down).
- On iOS a quiescence wait is cut at 2 s (XCTest's application-state timeout, set through
  `_XCTSetApplicationStateTimeout`, as WebDriverAgent does), then the settle waits for the
  event loop only and compares signatures: under an open context menu animations never
  finish, and XCTest waited 60 s after every long press that opened one.
- Found by the benchmark app (bench/app), fixed:
  - `runFlow: file:` with an absolute path is taken as is (Maestro's Path.resolve); it was
    joined onto the flow's folder.
  - A selector without text, id or size whose first filter is relative (`below`, `above`,
    `leftOf`, `rightOf`) orders its matches by distance, centers to the nearest anchor, then
    keeps the deepest (Maestro's relativeTo sorts by distance and its intersect keeps the
    first filter's order; with a text filter first, document order stays).
  - A tap whose element moved is repeated only if every text of its window is still there: a
    keypad's fourth digit replaced the title and showed an error above the keys, which moved
    them, and the repeated tap typed a fifth digit.
  - iOS typing: when the focus moves to another field after the first character (a code
    split into one box per digit), the rest goes one key at a time, each once the focus
    moved on (at most 400 ms): keys sent while the focus moves are lost.
  - A second `takeScreenshot` into the same folder failed: Odin's make_directory_all
    reports `.Exist` for a folder already there (make_dirs).
  - iOS's scroll indicators ("Horizontal scroll bar, 1 page", value "0%", a 30-point touch
    area over the list's bottom) no longer count as covers in `scrollUntilVisible`.
  - `scrollUntilVisible` measures an element's visible part against its whole frame where a
    scroll view cut it (iOS clipping kept only the visible part, so a row half under the
    list's edge counted as fully visible). It stopped with a row's visible part centered 5
    points above the screen's bottom, in the home indicator's strip, where iOS took the tap
    and then lost the next one.
  - A `when: visible` whose element shows up while it waits settles before it says yes, as
    find_element does: the tap that follows landed while a React Native modal was still
    presenting, and UIKit dropped it.
  - iOS SCREEN ends with a byte: 1 when the app's part differs from the signature the last
    SETTLE ended on (Screen.settledSignature). find_element and `when: visible`, finding
    their element on such a read, settle first: a popup that came up just after the last
    settle (a badge 0.8 s after a rating prompt closed) is still sliding in and takes no tap.
    Nothing changes between commands on most screens, so it costs nothing there (Settings
    13.6 s, as before).
  - `scrollUntilVisible` that drags an element already on screen (centering it, clearing a
    cover) waits for the drag to show before it ends, as it does before the next drag:
    Android's SWIPE is injected at once and played out by the app after, so the next read
    could still be the screen before the drag, and the tap that followed landed on a list
    starting to move, which React Native takes as a touch to stop it (1 run in 6 failed).
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
  otherwise wait 7 s after each. A condition's own `timeout` (a field Maestro does not
  have, so such a flow no longer runs there) overrides it for one check.
- `scrollUntilVisible` drags without a fling on both platforms, so the content stops as
  the touch lifts (Android: 50 ms, then still for 60 ms; iOS: see above). It reads the
  screen right after each drag and drags again as soon as the element is not on screen,
  the last drag shown; it settles only once the element shows, for the checks on visibility
  and centering on a still screen, as Maestro's. Maestro looks for the element for 500 ms
  before every swipe, then settles after it, a fling included. A drag moves the content by
  about its length (40% of the screen, 80% sideways, less the touch slop), less than a
  fling, so long lists take more of them, and `speed` changes nothing. In Android Settings
  this took a scroll from 0.8 s to 0.33 s.
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
- **`SWIPE` timestamps are synthetic for drags:** scrollUntilVisible's drag is injected at
  once with the timing of a real drag, so the app sees the right speed without the tool
  waiting it out. Only the first MOVE waits about one frame for the app (a scroll container
  must intercept it), and the lift ~25 ms after the moves, a frame later. The flow's `swipe`
  and `scroll` (the fling flag) play out in real time instead, as a finger's: sent at once, a
  React Native Gesture Handler pan sometimes ended with no movement (1 run in 3 of the
  benchmark app's gestures flow). Flows fling like `adb shell input swipe`, as Maestro does;
  without the fling flag the pointer stops before lifting and the content moves by the drag
  distance: a still MOVE more than
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
- Speedrun goes through the `adb` binary for `forward`/`push`/`install` (about 0.5 s of
  start-up per run). It could speak the adb wire protocol directly.
- Animations are disabled by every run (normal practice for UI tests) and stay disabled;
  re-enable with `adb shell settings put global <name> 1` for `window_animation_scale`,
  `transition_animation_scale` and `animator_duration_scale`.
