# speedrun

**Fast end-to-end UI tests for Android and iOS.**

speedrun runs mobile UI flows written in the Maestro flow format. Point it at the YAML files,
folders and config you already use with `maestro test` and most flows run as they are,
several times faster: **8x faster than Maestro on our Android benchmark**, 3x on iOS.

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

The same scenario in each tool, on the Settings app: it goes two screens deep, scrolls down
and back up, and types into a field (14 steps per lap on Android, 12 on iOS), 3 laps. Times
are wall clock, from starting the command to its exit, so each tool's start-up counts.

Android emulator:

| Tool | Wall clock | speedrun is |
|---|---:|---:|
| **speedrun** | **11 s** | — |
| tester-army e2e 0.17 | 32 s | 2.9x faster |
| UI Automator 2.3 (Google, native) | 49 s | 4.4x faster |
| Appium 3.8 (UiAutomator2 driver) | 53 s | 4.7x faster |
| Maestro 2.11 | 91 s | 8.2x faster |

iOS simulator:

| Tool | Wall clock | speedrun is |
|---|---:|---:|
| **speedrun** | **31 s** | — |
| tester-army e2e 0.17 | 65 s | 2.1x faster |
| Maestro 2.11 | 93 s | 3.0x faster |

How the numbers were taken:

- The flows are [`bench_scenario.yaml`](bench_scenario.yaml) and its iOS version
  [`bench_scenario_ios.yaml`](bench_scenario_ios.yaml), run as they are by `speedrun test`
  and `maestro test`.
- The other tools ran the same steps, each written the way that tool is normally used:
  tester-army's e2e as a TypeScript test with locators and no AI steps
  ([`bench/tester-army`](bench/tester-army)), Appium with WebdriverIO, UI Automator as a
  Kotlin instrumentation test.
- e2e's time is `e2e run`, with the helper it leaves running from the previous run (its
  first run takes 12–24 s more). Appium's runs from starting the Appium server to stopping
  it. UI Automator's is `./gradlew connectedDebugAndroidTest`, with the test already built
  and Gradle's daemon running. speedrun's iOS time includes starting its agent.
- Each time is the median of 2–5 runs on a quiet machine.
- Measured on 2026-10-26: Apple M1 Pro with 16 GB, Android 17 emulator, iPhone 17 Pro
  simulator (iOS 26.2).
- Espresso and Detox run inside the app under test, so they cannot drive a system app like
  Settings. Appium and XCUITest were not measured on iOS.

Against Maestro on a React Native app (wall clock):

| Platform | speedrun | Maestro | speedrun is |
|---|---:|---:|---:|
| Android emulator | 32 s | 196 s | 6.2x faster |
| iOS simulator | 60 s | 180 s | 3.0x faster |

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

speedrun is built from source. To build it you need JDK 17, the [Odin](https://odin-lang.org)
compiler and a C compiler (`cc`) on your PATH, plus Xcode for iOS support.

```
git clone https://github.com/hubastard/speedrun.git
cd speedrun
./build.sh
export PATH="$PWD:$PATH"     # add to your shell profile to keep it
```

`./build.sh` produces the `speedrun` binary with everything it needs. Without Xcode, it
builds Android support only.

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
speedrun --help
```

Environment variables:

| Variable | |
|---|---|
| `SPEEDRUN_IDLE_S` | iOS: seconds of inactivity before the agent stops (default 600). |
| `SPEEDRUN_DEBUG=1` | Print every screen read and shell command with its time. |
| `SPEEDRUN_LONG_PRESS_MS` | How long `longPressOn` holds, for an app whose own long-press delay is longer than usual. |
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
