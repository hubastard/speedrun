# Speedrun against agent tools

The steps an AI agent takes to try out a feature of an app, driven through three tools that
let an agent use a mobile app, each through its MCP server and with the loop its
documentation recommends. Two tasks, each from a freshly installed app (its data reset before
each run, not timed):

- **Speedrun Bench** ([../app](../app), this repo's app): skip the onboarding, continue as a
  guest, open the shop, search "sneaker", check that "6 products" shows, open "City Sneaker",
  check that its sizes show.
- **A neutral app**: [tester-army](https://github.com/tester-army/e2e)'s `mobile-benchmark`,
  an app another team made to benchmark its own agent (built on agent-device), never tuned
  against: open Login Form, fill an unknown account's email and password, submit, check that
  "Invalid credentials" shows.

There is no model in the loop: [`bench.py`](bench.py) makes the calls an agent would make, the
same ones every run, so the tools are compared on what they cost an agent, not on what a model
decided. Per run it measures the wall time (session set-up and close included), the number of
calls, and everything the tools answered, which is what the agent reads: text in characters
and in tokens (characters / 4), screenshots in tokens (width x height / 750).

| Tool | Version | How the agent uses it |
|---|---|---|
| Speedrun | this repo | `session_start`, then `run` with the app's launch and `look` once, and a `run` per step; each answer says how the step went and what changed on screen. `session_stop` at the end. |
| [agent-device](https://github.com/callstackincubator/agent-device) | 0.21.33 | `open` with `foreground` (the first screen's elements), then `click`/`fill` with `settle` (acts, waits for the screen to settle, answers what changed) and `wait` for the checks; `close` at the end. |
| [Argent](https://github.com/software-mansion/argent) | 0.31.0 | `launch-app`, then `gesture-tap` at the centre of the element in the tree the last answer brought (its server waits for the screen to go idle after each action, then attaches a screenshot and the element tree; its rules: tap from that tree, `describe` only without one), `keyboard` to type, `await-ui-element` for the checks. |

## Animations

Each tool runs the app the way it comes, unless said otherwise:

- **iOS:** Speedrun launches apps with UIKit's animations 10x faster
  (`-UIAnimationDragCoefficient 0.1`, which UIKit reads once the `UIKit/UIPreferences` feature
  flag is on); agent-device and Argent run them at normal speed. Both take launch arguments,
  so `--animations fast` gives them Speedrun's setting too (the flag reaching the app checked
  with `ps -E`), and `--animations normal` turns Speedrun's off. In the tables: with
  animation optimization, all three tools at Speedrun's 10x; without, all three at normal
  speed.
- **Android:** Speedrun turns the system's animation scales off; the script sets them off
  before each tool, so all three run with them off.

## Results

2026-10-29, Apple M1 Pro (16 GB), an Android 17 emulator and an iPhone 17 Pro simulator
(iOS 26.2), one at a time. The median of 3 runs after a warm-up (each run's time in seconds);
every run passed. Speedrun with two lookup fixes that came out of this benchmark (see
DEVELOPMENT.md); before them, at normal speed on iOS, Speedrun Bench took 13.2 s.

**Speedrun Bench**

| Tool | Android | iOS, default settings | iOS, without animation optimization | iOS, with animation optimization | What the agent read |
|---|---|---|---|---|---|
| **Speedrun** | **4.5 s** (4.59, 4.51, 4.23) | **7.8 s** (7.78, 8.17, 7.79) | **11.3 s** (11.21, 11.29, 11.26) | **7.8 s** (7.95, 7.79, 7.79) | ~1,590 tokens (Android), ~1,360 (iOS) |
| agent-device | 8.2 s (8.24, 8.00, 8.29) | 12.5 s | 12.5 s (12.52, 12.15, 12.59) | 11.5 s (11.48, 11.42, 11.98) | ~2,260, ~1,680 |
| Argent | 13.0 s (13.02, 13.04, 12.88) | 11.8 s | 11.8 s (11.57, 11.80, 12.51) | 11.7 s (12.32, 11.33, 11.71) | ~11,370 + 10 screenshots (~2,160), ~6,250 + 10 (~2,640) |

**Neutral app** (tester-army's Login Form)

| Tool | Android | iOS, default settings | iOS, without animation optimization | iOS, with animation optimization | What the agent read |
|---|---|---|---|---|---|
| **Speedrun** | **4.0 s** (3.92, 3.98, 3.97) | **6.8 s** (6.85, 6.76, 6.74) | **8.5 s** (8.48, 8.59, 8.50) | **6.8 s** (6.78, 6.89, 6.77) | ~1,650 tokens (Android), ~1,820 (iOS) |
| agent-device | 4.9 s (5.26, 4.93, 4.88) | 11.3 s | 11.3 s (11.26, 11.31, 11.22) | 10.7 s (10.71, 10.72, 10.79) | ~2,350, ~1,440 |
| Argent | 11.9 s (11.91, 11.55, 12.18) | 10.5 s | 10.5 s (10.53, 10.49, 10.70) | 10.4 s (10.40, 10.43, 10.26) | ~10,090 + 9 screenshots (~1,940), ~5,200 + 9 (~2,380) |

What the numbers say:

- **Speedrun's 10x is most of its iOS lead on its own app**: at normal speed it is 5%
  faster than the next tool there (Argent), 1.2x on the neutral app. Given the same 10x, the
  other tools gain 1 s at most, probably because they wait for the screen to hold still for
  a fixed window (Argent 250 ms, agent-device 300-500 ms), which faster animations do not
  shorten, where Speedrun's settle ends when the app is done.
- **By MCP** agent-device saves its command line's start-up (Node, ~0.15 s a call): 14.0 s on
  iOS and 9.1 s on Android from its command line. Argent's MCP answers carry a screenshot and
  the element tree after every action, which it waits for the screen to go idle to take: from
  its command line, with `await-screen-idle` and `describe` called by the agent, it took
  11.7 s on Android and 12.2 s on iOS, in 21 calls.
- Speedrun's session start is timed in every run: 0.2 s on iOS and 0.5 s on Android, the
  device's agent already up (as for the other tools, started by the warm-up).

Also:

- Speedrun taps a field and types in two calls; agent-device's `fill` does both in one.
  Speedrun's `run` also takes several commands at once, and Argent's `run-sequence` several
  actions, neither used here.
- On iOS, agent-device's `open` returned before the app had drawn its first screen, so the
  script waits for the first element (as an agent seeing an empty screen would); and
  Argent's iOS tree gives no id for some elements (Skip), so its taps fall back to the
  element's label.
- On Speedrun Bench's iOS home screen, after "Continue as guest", Speedrun waits for the
  feed to load (1.2 s of skeleton) before answering, so its answer shows the feed; the other
  tools answer on the skeleton, which is still enough to tap the tab bar.

## Running it

```sh
../app/bench.sh install android     # or ios: Speedrun Bench, prebuilt, installed
npm install                         # agent-device and Argent, the versions above
python3 bench.py android            # or ios; tools: speedrun agent-device argent
python3 bench.py ios --animations default    # normal (the default), default or fast
NEUTRAL_APP=<e2e checkout>/apps/mobile-benchmark python3 bench.py ios --app neutral
python3 bench.py ios --via cli      # each tool's command line instead of its MCP server
```

The neutral app: tester-army/e2e (commit 0d3e403 here), `apps/mobile-benchmark` built for
Release, `ios/build/Build/Products/Release-iphonesimulator/e2eBenchmark.app` (Xcode) and
`android/app/build/outputs/apk/release/app-release.apk` (Gradle, JDK 17-21; installed by the
script). The script takes the first adb device or the booted simulator (`DEVICE=<id>` picks
one), stops on iOS if the simulator's Reduce Motion is on, resets the app before each run, and
stops each tool's background service before the next tool (one UI automation client at a
time). Argent's usage statistics are off (`DO_NOT_TRACK=1`). Each run's calls, with their
time and answer size, are in `results/`, and each MCP server's log. Shut the iOS simulator
down for Android numbers. On Android, agent-device installs a helper keyboard app
(`com.callstack.agentdevice.imehelper`) and leaves a background daemon running; Argent
installs `com.argent.androiddevtools`.
