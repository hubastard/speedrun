# The journey: Speedrun against other black-box test tools

One user journey on [Speedrun Bench](../app), written once for each tool, the way that tool's
tests are usually written, and timed on the same device:

1. Sign in with a phone number and a code, and dismiss the notification prompt.
2. Search the shop, open a product, pick a size, a color and a quantity, add it to the cart,
   check the cart.
3. Set a PIN on a keypad that a loading overlay covers for its first 1.5 s.
4. Scroll a 500-row list to row 60 and pick it.

About 40 steps: taps, typing, a keyboard search, assertions, scrolls, back navigation.

| Tool | Version | Platforms | Written as |
|---|---|---|---|
| Speedrun | this repo | Android, iOS | [`journey.yaml`](journey.yaml) (Maestro flow format) |
| [Maestro](https://maestro.dev) | 2.11 | Android, iOS | the same [`journey.yaml`](journey.yaml) |
| [Appium](https://appium.io) | 3.9, UiAutomator2 driver 8.7, XCUITest driver 12.22, WebdriverIO 10.1 | Android, iOS | [`appium/journey.mjs`](appium/journey.mjs) |
| [maestro-runner](https://github.com/devicelab-dev/maestro-runner) | 1.1.29, its default DeviceLab driver | Android, iOS | [`maestro-runner/journey.yaml`](maestro-runner/journey.yaml) (Maestro flow format) |
| [Argent](https://github.com/software-mansion/argent) | 0.31.0, its e2e runner (`argent e2e run`, no model in the loop) | Android, iOS | [`argent/journey.yaml`](argent/journey.yaml) (Argent's e2e format) |
| [XCUITest](https://developer.apple.com/documentation/xctest/user_interface_tests) | Xcode 27 | iOS | [`xcuitest/JourneyUITests/Journey.swift`](xcuitest/JourneyUITests/Journey.swift) |

All of them test the app from outside, through the platform's accessibility layer, with
nothing added to the app. Espresso is not in the list: it runs inside the app's own process,
built into the app's Android project.

## Results

Apple M1 Pro (16 GB), an Android 17 emulator and an iPhone 17 Pro simulator (iOS 26.2):
Speedrun (its current code) and Argent on 2026-10-29, maestro-runner on 2026-10-28, the others on
2026-10-27. The median of the passing runs, the pass count, and each run's time in seconds:

| Tool | Android emulator | iOS simulator |
|---|---|---|
| **Speedrun** | **20.9 s**, 3/3 passed (20.9, 21.2, 20.3) | **25.5 s**, 3/3 passed (25.5, 25.4, 25.6) |
| Appium | 59.4 s, 3/3 passed (59.4, 69.0, 59.1) | 94.1 s, 3/3 passed (94.1, 96.9, 92.7) |
| maestro-runner | 65.9 s, 2/3 passed (50.7, 81.1, 89.4 ✗) | 49.6 s, 3/3 passed (49.6, 49.9, 49.2) |
| Argent | 81.5 s, 3/3 passed (80.9, 84.1, 81.5) | 72.2 s, 3/3 passed (72.2, 72.3, 69.0) |
| XCUITest | | 81.2 s, 3/3 passed (80.5, 81.4, 81.2) |
| Maestro | 126.5 s, 2/3 passed (135.0, 184.9 ✗, 118.1) | 113.1 s, 2/3 passed (113.6, 86.7 ✗, 112.6) |

✗: failed (its time stops at the failure). Maestro's failed runs: on iOS its tap on the color
"Blue" was lost (the product page's photos page on their own, and in React Native a scroll
during a touch cancels the press); on Android its scroll to row 60 ran out of its 60 s.
maestro-runner's failed run: its scroll to row 60 ran out of its 60 s too (it took 21 and 45 s
in the other two; 13 s on iOS). On iOS, the simulator's Reduce Motion was on for maestro-runner
(it turns it on by default and leaves it on; `run.sh` turns it off before each tool) and for
Speedrun (`SPEEDRUN_REDUCE_MOTION=1`; 26.6 s without it): the app's animations end at once.
Speedrun also runs UIKit's animations 10x faster. Maestro, Appium, Argent and XCUITest ran with
animations at their normal speed.

Each tool runs the journey once to warm up (not counted), then three times, each after the
app's data is reset (not timed). A run's time is the wall clock of the tool's command, its
start-up included, as a CI job sees it.

## What each version needed

The ports follow each tool's usual style. What the app asked of each, beyond that:

- **Appium:** the app named in the session's capabilities (`bundleId`, `appPackage`), so that
  on iOS the driver waits for the app to go idle before each action (without it, typing on a
  screen still sliding in was lost); the first match of a selector (React Native reports a
  text twice on iOS); the first PIN key tapped until the PIN's dots show it (waiting for the
  overlay's spinner to go timed out on Android once in three runs: Appium still reported it
  displayed).
- **XCUITest:** a wait for the first key to be hittable while the loading overlay covers it
  (`tap()` would fail on it).
- **Speedrun and Maestro:** the same YAML file. The long-list scroll has a 60 s timeout:
  Maestro's 20 s default ran out on Android.
- **maestro-runner:** the same file, but its taps on the PIN keypad landed while the loading
  overlay still covered it, and were lost (the journey failed there in 4 runs of 4). Its copy
  taps the first key until the PIN's dots show it, as the Appium version does, a `repeat`
  whose check has a 300 ms timeout: with Maestro's 7 s, the check waited that out once the
  dots showed the key.

- **Argent:** written as its guide says for e2e tests: after each screen change, an `await`
  for an element of the new screen, then `await: { idle: true }` (the tree and the pixels hold
  still for 250 ms). Its taps landed on Android; on iOS the first PIN key's tap went to the
  loading overlay in its first run, and its YAML has no loop to tap until the dots show it and
  nothing to await (the overlay has no id, and its spinner stays mounted), so on iOS a 1 s
  `wait` comes before the keypad. Two of its idle waits, over the home screen with its
  ticker, run to their 7.5 s timeout on iOS (it then goes on, with a warning).

Every version checks the quantity after each `+` tap ("Qty 2", then "Qty 3"): a second tap
right after the first was lost on Appium for iOS.

The journey leaves out one step of the app's checkout flow: scrolling the product page to the
gift-wrap checkbox and tapping it. Right after a swipe, Maestro lost that tap in every run on
iOS and XCUITest in one run of three (the page was still gliding). The benchmark compares the
tools' speed on a journey they all pass; how often each passes the harder cases is the test
suite's job ([`../app/flows`](../app/flows), Speedrun and Maestro).

## Running it

```sh
../app/bench.sh install ios                # or android: Speedrun Bench, prebuilt, installed
(cd appium && npm install && npm run setup) # Appium, its two drivers, WebdriverIO
(cd ../agents && npm install)               # Argent, the version the agent benchmark pins
./run.sh ios                                # or: ./run.sh android speedrun appium
```

maestro-runner installs with `curl -fsSL https://open.devicelab.dev/install/maestro-runner |
bash` (in `~/.maestro-runner`); `run.sh` turns its usage stats off, and Argent's
(`DO_NOT_TRACK=1`). On iOS each tool's UI test runner is stopped before the next tool runs (a
simulator runs one at a time), and Argent's tool server and device services before each tool
(on Android they hold its one UI automation client).

`run.sh` takes the first adb device or the booted simulator (`DEVICE=<id>` picks one), runs
each tool (`RUNS=3` by default, after one warm-up), and writes `results/<platform>.md`, with
each run's output in `results/`. It needs `../../speedrun` (`./build.sh`), `maestro`, Node,
and Xcode for XCUITest. Shut the iOS simulator down for Android numbers.
