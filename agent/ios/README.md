# iOS agent (spike)

Steps 1 and 2 of the iOS plan: a Maestro baseline on the iOS Settings app, and a bare XCUITest
runner that times each building block an iOS agent would be made of. Nothing here is wired
into `speedrun` yet.

- `SpeedrunAgentUITests/` — the runner: one UI test that serves the Android agent's framing
  (`u8 op` + fields; `u32 length, u32 agent_us, body`) over TCP on `127.0.0.1:7778` (a
  simulator shares the Mac's loopback: no forwarding). Ops are listed in `Agent.swift`.
  Private XCTest API is reached through the Objective-C runtime and checked before each use
  (`Private.swift`): a missing method is an error naming it, not a crash.
- `spike/` — the Python client and the measurement scripts.
- `../../bench_scenario_ios.yaml` — the iOS version of `bench_scenario.yaml` (Settings, simulator
  in English), 12 commands per iteration.

Build and start (Xcode 27, a booted simulator):

```
xcodebuild build-for-testing -project agent/ios/SpeedrunAgent.xcodeproj -scheme SpeedrunAgent \
  -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath agent/ios/build
TEST_RUNNER_SPEEDRUN_PORT=7778 xcodebuild test-without-building \
  -xctestrun agent/ios/build/Build/Products/*.xctestrun -destination 'id=<udid>' &
python3 agent/ios/spike/measure.py        # Settings open on its home screen
```

## Results (2026-10-23, iPhone 17 Pro simulator, iOS 26.2, Xcode 27.0, a loaded Mac)

Maestro 2.11.0, `bench_scenario_ios.yaml -e TIMES=5`, all commands passed:

| command | median |
|---|---|
| tap (General / About / back button / search field / close) | 2.4–3.0 s |
| `scrollUntilVisible` down / up | 3.7 / 3.0 s |
| `eraseText: 25` | 2.0 s |
| `inputText` (14 characters) | 1.6 s |
| `assertVisible` | 0.2–0.3 s |
| per iteration | 26.0 s |
| start-up and shutdown, outside the flow | ~10 s |

Building blocks through the spike runner:

| block | time |
|---|---|
| runner start (`xcodebuild test-without-building` to first answered PING) | 3.7 s |
| round trip | 0.1 ms |
| full snapshot of Settings (168 nodes) | 70–90 ms (`dictionaryRepresentation` 70, walking `children` 90) |
| first element by label (`firstMatch`) | 53 ms found, 81 ms absent |
| screenshot (PNG) | 105 ms |
| tap (synthesized event, Maestro's 100 ms hold) until delivered | 334 ms (249 ms with a 20 ms hold) |
| screen starts changing | ~300 ms after the tap begins |
| XCTest quiescence (event loop + animations idle) after a push / pop | 1.2 s / 0.74 s after the tap |
| push content actually done (PNG diffs) | ~1.0 s after the tap |
| Maestro's static check (two equal screenshots) after a push / pop | 1.46 s / 1.15 s |
| typing 14 characters at Maestro's 30 chars/s | 648 ms (Maestro: plus 0.7 s of fixed sleeps) |
| erasing 25 characters at 30 chars/s | 1.0 s |

What it means:

- Taps are not where Maestro loses its time on iOS (it already synthesizes events directly).
  Its time goes to settling and to hierarchy reads: a tap command costs 2.4–3 s against
  ~1.0–1.3 s for tap + quiescence here. Expect about 2x per tap, less than Android's 4–5x,
  because the push animation itself takes ~1 s and nothing on iOS turns it off.
- XCTest's quiescence is a usable settle signal (it fires ~0.2 s after the content stops
  moving, ignoring the scroll indicator's fade), but in one push of five it fired ~0.44 s
  after the tap, before the transition began: settle needs a guard, as on Android.
- Lookups: `firstMatch` (53 ms) vs a full snapshot (70–90 ms) is a smaller gap than FIND vs
  TREE on Android; a trimmed snapshot (`XCAXClient_iOS requestSnapshotForElement:attributes:
  parameters:`, present in Xcode 27) is still to be measured.
- Typing faster than 30 chars/s lost characters in some runs (60: 1 of 3 correct, 100: 2 of
  3, 150–300: 3 of 3); unexplained so far, so 30 chars/s stays until it is understood.
- Writing `ReduceMotionEnabled` to the simulator's defaults did not change push timing.
- Start-up: 3.7 s here against ~10 s for Maestro, before keeping the runner alive between
  runs.

Next: a settle that combines quiescence with a guard against early idles, the trimmed
snapshot, the typing losses, then the agent's real ops and `speedrun` support for iOS
devices.
