# speedrun

**Fast end-to-end UI tests for Android and iOS.**

speedrun runs mobile UI flows written in the Maestro flow format. Point it at the YAML files,
folders and config you already use with `maestro test` and most flows run as they are,
several times faster: on the flows of our benchmark app that both tools pass, **6.1x faster
than Maestro on Android** and 2.6x on iOS, and it passes flows that Maestro fails.

```
maestro test flows/      →      speedrun test flows/
```

- **Fast.** A tap that opens a screen takes about 0.3 s, where Maestro takes 2.5–4 s.
  Starting and stopping a run takes 1–3 s on Android, where Maestro takes 9–24 s.
- **Drop-in.** The same flow files, the same command-line options, and the same JUnit/HTML
  reports and debug output, so CI scripts keep working.
- **Waits for the app, not the clock.** Every step waits until the app has actually
  finished changing, then moves on at once.
- **Android and iOS.** Android emulators and devices, iOS simulators.

## Benchmark

speedrun and Maestro on [Speedrun Bench](bench/app), a React Native app made to be tested:
19 flows that cover every command and selector, on the screens that make tests slow or
flaky in real apps — animations that never stop, popups that show up late or one after
another, a keyboard over the checkout button, lists that load more as you scroll, native
modals and alerts, permission prompts. Both tools run the same flow files.

| Platform | Flows both pass | Whole suite, estimated | Flows passed |
|---|---:|---:|---|
| Android emulator | **6.1x faster** (16 flows: 7 min 12 s against 43 min 58 s) | ~5.8x | speedrun 19/19, Maestro 16/19 |
| iOS simulator | **2.6x faster** (8 flows: 2 min 58 s against 7 min 42 s) | ~4.1x | speedrun 19/19, Maestro 8/19 |

The first column times the flows that both tools pass. The time of a flow Maestro fails says
little (it fails some early, others after waiting out its timeouts), so the second estimates
the whole suite as if Maestro had finished those flows: its time up to the failing step, then
speedrun's time for the rest of the flow at Maestro's pace on that flow so far. speedrun ran
the whole suite in 8 min 14 s on Android and 11 min 5 s on iOS, start-up included (Maestro:
46 min 56 s and 40 min 19 s, counting its failed flows up to the failure).

The widest gap is on screens that never stop moving (a looping animation, a ticker, a number changing every frame): each
of Maestro's steps waits for a still screen until its timeout, 20–24 minutes for that flow
against 1.4–2.2 minutes. Maestro's `scrollUntilVisible` swipes across the screen's center:
it never moved a card list above the center, and it did not turn the pages of an onboarding
pager in time; on Android it also ran out of time on a feed that loads more posts as it
scrolls. On iOS it failed where React Native apps differ from UIKit ones: it does not read
the checked state of React Native checkboxes and radio buttons, its double tap is too slow
for a 300 ms double-tap window, it taps a list row half hidden under the list's edge outside
the list, it misses a button that a late banner pushed down, and its `hideKeyboard` gave up
on one screen.

How the numbers were taken: `bench/app/bench.sh compare android|ios` (speedrun's suite,
then Maestro's, on the same device), on 2026-10-27, Apple M1 Pro with 16 GB, an Android 17
emulator and an iPhone 17 Pro simulator (iOS 26.2). The per-flow tables are in the app's
[README](bench/app/README.md).

On native screens, the system Settings app (`bench_scenario.yaml` and
`bench_scenario_ios.yaml`: 14 commands, navigation, scrolling and text input, run three
times), with `./compare.sh <flow> -e TIMES=3`:

| Platform | speedrun | Maestro 2.11 | speedrun is |
|---|---:|---:|---:|
| Android emulator | **13.4 s** | 113.1 s | 8.4x faster |
| iOS simulator | **32.8 s** | 90.5 s | 2.8x faster |

speedrun runs a small agent on the device. The agent reads the screen in a few milliseconds
and tells exactly when the app has settled, instead of comparing screenshots or sleeping.

## Requirements

- macOS (tested on Apple silicon).
- **Android:** the Android SDK platform tools (`adb` on your PATH), plus a running emulator
  or a device with USB debugging on. Tested on Android 17.
- **iOS:** Xcode (tested with Xcode 27) and a booted simulator. Real iOS devices are not
  supported yet.
- `curl`, for flows whose scripts make HTTP requests.

## Installation

### From a package

A package is one archive per platform (`speedrun-<version>-macos-arm64.tar.gz`): the
`speedrun` binary, with the Android agent inside it, and the iOS agent next to it. The machine
running it needs only `adb` for Android and Xcode for iOS: no compiler.

```
tar -xzf speedrun-<version>-macos-arm64.tar.gz
export PATH="$PWD/speedrun-<version>-macos-arm64:$PATH"   # or symlink the binary into your PATH
speedrun --version
```

Keep the `agent/` folder next to the binary: speedrun starts its iOS agent from there. That
agent is built with one Xcode (the archive's `README.txt` names it); a much different Xcode may
not run it, and building from source fixes that.

### From source

To build speedrun you need JDK 17, the [Odin](https://odin-lang.org) compiler and a C
compiler (`cc`) on your PATH, plus Xcode for iOS support.

```
git clone https://github.com/hubastard/speedrun.git
cd speedrun
./build.sh
export PATH="$PWD:$PATH"     # add to your shell profile to keep it
```

`./build.sh` produces the `speedrun` binary with everything it needs. Without Xcode, it
builds Android support only. `./package.sh` builds and packs it into a package for this
platform, in `dist/` (`SPEEDRUN_VERSION=1.2.3 ./package.sh` names the version; by default it
is the git tag or commit).

## Quick start

Start an emulator (or boot a simulator), then run a flow:

```yaml
# login.yaml
appId: com.example.app
---
- launchApp:
    clearState: true
- tapOn: "Email"
- inputText: "user@example.com"
- tapOn: "Password"
- inputText: ${PASSWORD}
- tapOn: "Sign in"
- assertVisible: "Welcome"
```

```
speedrun test login.yaml -e PASSWORD=secret            # Android device or emulator
speedrun test -p ios login.yaml -e PASSWORD=secret     # iOS simulator
```

In a terminal you get a live view of the flow, with each step's time. When a step fails,
speedrun shows what was on screen and where the screenshot and logs were saved.

Run a whole folder as a suite, with a JUnit report for CI:

```
speedrun test flows/ --format junit --output report.xml
```

## Command line

```
speedrun test [options] <flow file or folder>...
```

speedrun takes `maestro test`'s options. `-p` and `--device` may also come before `test`.

| Option | |
|---|---|
| `-e`, `--env KEY=VALUE` | Set a variable for the flows (repeatable). |
| `--config <file>` | Workspace config (default: `config.yaml` in the folder). |
| `--include-tags a,b` / `--exclude-tags a,b` | Run only the flows with, or without, these tags. |
| `--format junit\|html\|html-detailed\|noop` | Write a report. |
| `--output <file>` | Report path (default `report.xml` / `report.html`). |
| `--test-suite-name <name>` | Suite name in the report. |
| `--debug-output <dir>` | Where each run's logs, screenshots and recordings go (default `~/.maestro/tests/<date>/`). |
| `--flatten-debug-output` | Write them straight into that folder, without a dated subfolder. |
| `--test-output-dir <dir>` | The same, taking precedence over `--debug-output` (or `testOutputDir` in the config). |
| `-p`, `--platform android\|ios` | Platform (default: a connected Android device, else the booted simulator). |
| `--device`, `--udid <id>[,<id>...]` | Device serial (`adb devices`) or simulator UDID (`xcrun simctl list devices booted`). |
| `--shard-split <n>` | Split the flows across n devices. |
| `--shard-all <n>` | Run every flow on each of n devices. |
| `-c`, `--continuous` | Rerun the flow when its files change, or when you press Enter. |

speedrun's own options:

| Option | |
|---|---|
| `--plain`, `--no-ansi` | Plain line-by-line output instead of the live view (the default when the output is not a terminal). |
| `--timings <file.json>` | Write each command's timing to a JSON file. |
| `--port <n>` | The agent's port (default 7777 on Android, 7778 on iOS). |
| `--instrument` | Android: run the agent as an instrumentation (a fallback; ~60 ms slower per action). |

Other commands:

```
speedrun --stop-agent      # stop the iOS agent kept running between runs
speedrun --version
speedrun --help
```

Environment variables:

| Variable | |
|---|---|
| `SPEEDRUN_IDLE_S` | iOS: seconds of inactivity before the agent stops (default 600). |
| `SPEEDRUN_DEBUG=1` | Print every screen read and shell command with its time. |
| `SPEEDRUN_LONG_PRESS_MS` | How long `longPressOn` holds, for an app whose own long-press delay is longer than usual. |
| `SPEEDRUN_CONDITION_TIMEOUT_MS` | How long a `when: visible` (or `notVisible`) waits for its element (default 7000, as Maestro). See [Conditions](#conditions-take-up-to-7-s). |
| `MAESTRO_*` | Passed to flows as variables, as in Maestro. |

speedrun exits with status 1 when a flow fails. A suite prints one line per flow, then
`N/M Flows Passed` or `N/M Flows Failed`.

## Maestro compatibility

speedrun reads Maestro 2.11 flow syntax and follows its behavior: how selectors match, which
element wins, timeouts, conditions, variables and scripts. Like Maestro, it is strict. An
unknown command or field is an error, and so is a Maestro feature speedrun does not support
yet. So a flow that loads runs as written; nothing is skipped silently.

**Commands:** `launchApp` (`clearState`, `clearKeychain`, `stopApp`, `permissions`,
`arguments`), `stopApp`, `killApp`, `clearState`, `setPermissions`, `tapOn`, `doubleTapOn`,
`longPressOn`, `assertVisible`, `assertNotVisible`, `assertTrue`, `extendedWaitUntil`,
`inputText`, `inputRandomText`/`Number`/`Email`/`PersonName`/`CityName`/`CountryName`/`ColorName`,
`eraseText`, `hideKeyboard`, `back`, `pressKey`, `scroll`, `scrollUntilVisible`, `swipe`,
`waitForAnimationToEnd`, `openLink`, `takeScreenshot`, `assertScreenshot`,
`startRecording`, `stopRecording`, `addMedia`, `setLocation`, `travel`, `setOrientation`,
`setDarkMode`, `toggleDarkMode`, `assertDarkMode`, `assertLightMode`, `setAirplaneMode`,
`toggleAirplaneMode`, `clearKeychain`, `copyTextFrom`, `setClipboard`, `pasteText`,
`runFlow`, `repeat`, `retry`, `evalScript`, `runScript`. Every command takes `label` and
`optional`.

**Selectors:** `text`, `id`, `index`, `enabled`, `selected`, `checked`, `focused`,
`width`/`height`/`tolerance`, `below`, `above`, `leftOf`, `rightOf`, `containsChild`,
`containsDescendants`, `childOf`, `traits`, and on taps `point`, `repeat`, `delay`,
`retryTapIfNoChange`, `waitToSettleTimeoutMs`, `waitUntilVisible`.

**Flow config:** `appId`, `name`, `env`, `tags`, `properties`, `onFlowStart`,
`onFlowComplete`. **Conditions:** `visible`, `notVisible`, `platform`, `true`.

**Workspaces:** `config.yaml` with `flows` globs, `includeTags`/`excludeTags`,
`executionOrder` and `testOutputDir`.

**JavaScript:** `${...}` expressions, `evalScript` and `runScript`, with `output`, `maestro`
(`platform`, `copiedText`), `json()`, `relativePoint()`, `console.log`, `http`
(get, post, put, delete, request) and `faker` (Datafaker's common providers).

**Not supported:** AI commands, web flows (`url:`, the `css` selector), real iOS devices,
`--analyze`. `--headless`, `--screen-size`, `--api-url`, `--api-key` and
`--reinstall-driver` are accepted and ignored.

### Differences you may notice

- **Steps run back to back.** speedrun reads the screen in milliseconds, so lookups retry
  far more often within the same timeouts, and a step starts as soon as the app has settled.
- **Android animations are turned off** by every run, as is usual for UI tests, and stay
  off. To turn them back on: `adb shell settings put global window_animation_scale 1` (and
  the same for `transition_animation_scale` and `animator_duration_scale`).
- **iOS apps started by `launchApp` animate 10x faster.** This speeds up screen transitions
  without changing what the flow sees. A flow can pass the launch argument
  `UIAnimationDragCoefficient: 1` to keep normal speed.
- **`scrollUntilVisible` scrolls without momentum**, so the list stops where the finger
  lifts. It takes more, shorter swipes, and its `speed` has no effect. `swipe` and `scroll`
  fling as in Maestro.
- **`scrollUntilVisible` scrolls the element clear of what is drawn over it** (a sticky
  footer, a floating search bar), so a tap that follows lands on it. Maestro stops once the
  element is on screen, under the footer or not.
- **`longPressOn` holds for 1.2 s**, where Maestro holds 3 s: past the 0.4–0.8 s after which
  apps take a touch as a long press (on Android, at least the device's touch & hold delay
  plus 0.7 s). For an app that waits longer, set `SPEEDRUN_LONG_PRESS_MS`.
- **iOS `doubleTapOn` lands as a double tap in React Native apps**: its two taps are one
  gesture, 200 ms apart (Maestro's arrive too far apart for a 300 ms double-tap window).
- **Several devices connected and no `--device`:** Maestro asks which one to use. speedrun
  takes the first Android device, else the booted simulator.
- **Regular expressions:** Java-only syntax (lookarounds, inline flags, `\p{...}`) is
  rejected. A pattern that is invalid in both tools matches as plain text, as in Maestro.
- **iOS: what a list has scrolled out of view is not visible**, as on Android: an element's
  bounds are cut to the scrolling area around it, and taps aim at the part that shows.
  Maestro counts an element as visible when its frame is on screen, even if the list hides it.
- **Not in the screen hierarchy:** Android toasts, and iOS Safari web views.
- **iOS screens with an endless animation settle anyway.** An element that moves on every
  read (a looping animation, a marquee) while the rest of the screen holds still is left
  out of the wait.

### Conditions take up to 7 s

A `when: visible` whose element is not there waits up to 7 s for it to show, as in
Maestro, counted from the end of the last command that touched the app. Several checks in a
row share that wait: the first one waits it out, the next ones read the screen once.

Flows that dismiss popups "if they show" (notification prompts, ratings, surveys) after
every action spend most of their time there. If your popups show up early or not at all,
shorten the wait, then rerun the suite a few times to check that no popup is missed:

```sh
SPEEDRUN_CONDITION_TIMEOUT_MS=2000 speedrun test .maestro/
```

`assertVisible`, `extendedWaitUntil` and the lookups of `tapOn` and the like keep their own
timeouts.

## Troubleshooting

- **The first iOS run takes a few seconds.** speedrun starts its agent on the simulator
  (3–6 s) and keeps it running, so later runs start in about 0.2 s. It stops after 10 idle
  minutes, or with `speedrun --stop-agent`.
- **"Another UiAutomation client is running on the device".** Android allows only one UI
  automation tool at a time. speedrun stops Maestro's leftover driver itself; stop any other
  tool (Appium, `uiautomator`, an instrumentation test) before running.
- **Slow or flaky runs on a busy machine.** An emulator stalls when the host is short of
  memory or CPU. Shut iOS simulators down while testing on Android (run
  `speedrun --stop-agent` first), and rerun before trusting a failure.
- **More detail:** `SPEEDRUN_DEBUG=1 speedrun test …` prints every screen read and shell
  command with its time. Agent logs on Android: `adb logcat -s SpeedrunAgent`.

## Third-party software

speedrun includes [QuickJS-ng](https://github.com/quickjs-ng/quickjs) (MIT),
[Datafaker](https://github.com/datafaker-net/datafaker)'s English word lists (Apache-2.0)
and [stb_image](https://github.com/nothings/stb) (public domain).

## Contributing

How speedrun works inside: [`DEVELOPMENT.md`](DEVELOPMENT.md). Benchmarks and what is still
slow: [`TO_IMPROVE.md`](TO_IMPROVE.md).
