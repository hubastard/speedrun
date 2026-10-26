# Things to improve

speedrun against Maestro on the same flow files: how it is measured, the latest numbers, and
the commands where speedrun is still closest to Maestro, with what is known about why.

## Measuring

```
./compare.sh bench_scenario.yaml -e TIMES=5                       # Android: speedrun, then Maestro
DEVICE=<simulator udid> ./compare.sh bench_scenario_ios.yaml -e TIMES=5
./compare.sh flows/features.yaml                                  # both must agree on every command
./race.sh bench_scenario.yaml -e TIMES=3                          # both at once on two emulators
```

`compare.sh` starts the flow's app fresh before each tool, lines the two runs up command by
command (warning if their command sequences or statuses differ) and prints medians per
command, repeat iterations grouped. Then three totals per tool: the flow, the time outside it
(start-up and shutdown, the whole run's wall clock minus the flow: a slow tool costs that on
every run) and the wall clock, all included. On iOS it stops speedrun's kept-alive agent
first, so both tools start cold. It needs `maestro` and `python3` on PATH. With several
devices connected it uses `DEVICE`, else `ANDROID_SERIAL`, else the first one.

`race.sh` is the demo: speedrun on one emulator and Maestro on another, started at the same
moment, so both screens can be watched side by side, with each tool's elapsed time and current
command until both finish. With a single emulator running, it creates `<avd>_race` once (same
system image and hardware settings) and boots it for Maestro; it stays up for the next race.
`SPEEDRUN_DEVICE`/`MAESTRO_DEVICE` choose the devices. Two emulators share the machine, so
numbers come from `compare.sh`, not from the race, and a freshly booted emulator is slower at
first.

The benchmark flows: `bench_scenario.yaml` (Android Settings, 14 commands per iteration:
navigation two levels deep, scrolling both ways, text input in a dialog), its iOS version
`bench_scenario_ios.yaml` (Settings on a simulator in English), and `flows/ignite/bench_rn.yaml`
(a React Native app: login, an API list, favorites, scrolling, text input, tabs). Shut the iOS
simulator down for Android numbers: memory pressure on a 16 GB Mac stalls the emulator. Stop
speedrun's iOS agent first (`./speedrun --stop-agent`): shut down under it, xcodebuild boots
the simulator again and runs `simctl diagnose`, which stalled an Android run.

## Latest results

| flow | device | speedrun | Maestro | ratio |
|---|---|---|---|---|
| `bench_scenario.yaml`, TIMES=3 (2026-10-26) | Android emulator (API 37), `-gpu host` | 10.5 s | 88.0 s | 8.4x |
| `bench_scenario_ios.yaml`, TIMES=3 (2026-10-26) | iPhone 17 Pro simulator, iOS 26.2 | 26.9 s | 78.8 s | 2.9x |
| `flows/ignite/bench_rn.yaml`, TIMES=3 (2026-10-26) | Android emulator, `-gpu host` | 31.2 s | 188.1 s | 6.0x |
| `flows/ignite/bench_rn.yaml`, TIMES=3 (2026-10-26) | iPhone 17 Pro simulator | 57.4 s | 169.4 s | 3.0x |
| `flows/ignite/device.yaml` | iOS simulator | 40.0 s | 49.4 s | 1.2x |
| Ignite's own flows (`apps/ignite/.maestro/flows`) | iOS simulator | 27.3 s | 37.9 s | 1.4x |

Flow times; outside the flow, start-up and shutdown cost speedrun 0.6–2.7 s on Android (the
most when it pushes a new agent build) and 4–5 s on iOS cold (~0.2 s once the runner is up),
Maestro 9–13 s. The `device.yaml` and Ignite rows predate the iOS speedups of 2026-10-24/25.

`bench_scenario.yaml` per command (median ms):

| command | speedrun | Maestro |
|---|---|---|
| tap (Display & touch / Display size & text / About / Device name / Cancel) | 161–328 | 2073–3817 |
| back | 118–193 | 733–842 |
| `scrollUntilVisible` down / up | 334 / 324 (828 / 801 with flinging swipes) | 2305 / 2383 |
| `eraseText: 25` | 446 | 2060 |
| `inputText` (14 characters) | 255 | 2932 |
| `assertVisible` | 4–47 | 87–120 |
| `launchApp` | 121 (then the next command waits for the app's window) | 744 |

`bench_scenario_ios.yaml` per command (median ms):

| command | speedrun | Maestro |
|---|---|---|
| tap (General / About / back / search / close) | 539–1203 | 1554–2640 |
| `scrollUntilVisible` down / up | 812 / 100 (up: "General" already shows) | 3777 / 2901 |
| `eraseText: 25` | 666 | 1972 |
| `inputText` (14 characters) | 1261 | 1562 |
| `launchApp` | 596 | 1768 |

## Other tools on `bench_scenario.yaml` (2026-10-26)

Quick ports, not kept in the repo: the same 14 steps written the way each tool is normally
used, TIMES=3, on the same emulator, alternating the tools. The README's table is the wall
clock, measured with VS Code closed (load ~2): speedrun's whole command; Maestro's; Appium
from starting its server to stopping it; UI Automator's `./gradlew connectedDebugAndroidTest`
(build up to date, daemon warm: it installs the test, runs it and uninstalls it).

| tool | wall clock (median) | runs | flow alone |
|---|---|---|---|
| speedrun | 11.2 s | 10.8, 11.1, 11.2, 11.3, 11.3 | 10.4–10.9 s |
| UI Automator 2.3 (Kotlin, `UiObject2` + `Until`) | 48.9 s | 44.4, 53.4 | 35.1, 36.6 s |
| Appium 3.8, UiAutomator2 driver 8.7, WebdriverIO | 52.7 s | 51.8, 53.5 | 48.3, 48.9 s |
| Maestro 2.11.0 | 90.7 s | 87.5, 90.7, 96.5 | 88.0 s (the third) |

Earlier the same day, with VS Code and macOS's ANECompilerService busy (load 3–5), the
flows alone took: speedrun 12.6–20.3 s, UI Automator 35.9–47.5 s, Appium 57.4–60.1 s,
Maestro 96.8–103.3 s. speedrun's row is after `scrollUntilVisible` stopped flinging on
Android (13.9 s before: 13.5–15.6): per lap, its two scrolls took 1.6 s of 4.2 s, now 0.66
s of 3.3 s.

- Both ports needed an explicit wait for the dialog to close after Cancel: their tap returns
  at once and the next `back` went to the closing dialog, leaving the flow on the wrong
  screen. Without it Appium failed 2 runs of 4 (46.4 and 47.0 s when it passed) and UI
  Automator all 4.
- Where they beat speedrun: UI Automator's `clear()` and `setText` take 7 and 37 ms
  (speedrun's `eraseText`/`inputText`: 295 and 256 ms). They set the field's text through
  accessibility, skipping the keyboard; flows type through it, so that would change what
  apps see.
- UI Automator's taps return without waiting (50–100 ms); its next lookup waits instead
  (~0.8 s after a tap that opens a screen). Its `scrollUntil` takes 2.4 s down and 1.1–1.8 s
  up (speedrun: 0.8 s).

## Closest to Maestro

- **iOS typing into a field that hides its value (React Native): 1.2 s vs 1.5 s.** Nothing
  shows when the first character has landed, so typing falls back to a fixed 0.5 s wait,
  then 30 characters per second, as Maestro paces it. Idea: the keyboard's suggestion bar
  updates after each key and could be the signal instead.
- **iOS `inputText` in Settings' search field: 1.2–1.4 s vs 1.6 s.** Settings works ~65 ms
  per key (search results for every prefix); key-by-key typing is bound by that.
- **Long press: 1.0–1.2 s vs 3.9–4.7 s.** The hold is 0.8 s (2026-10-26; 3 s before), past
  the apps' usual 0.4–0.5 s delay. One that opens an iOS context menu costs ~3 s: the
  settle's quiescence wait is cut at 2 s (it took XCTest's 60 s before).
- **iOS Enter and taps that bring up or dismiss the keyboard: 0.64 s vs 0.62–0.79 s, 1.1 s
  vs 1.2 s.** The keyboard's animation runs outside the app, so the 10x UIKit animation speed
  set at launch does not reach it. Enter's settle sees the screen change until ~430 ms, then
  one more signature (~210 ms) confirms it; Maestro's 617 ms on 2026-10-26 was 790 ms on
  10-25, so it is level within Maestro's spread. Not waiting for testmanagerd's confirmation
  was slower for Enter (more signatures while the keyboard moves).
- **iOS taps in general: 0.5–0.65 s vs ~0.15 s for the same tap on Android.** testmanagerd
  confirms a synthesized event ~230 ms after it, the screen starts changing ~300 ms after the
  tap begins, and a snapshot costs ~70 ms. Not waiting for the confirmation gained little for
  taps (the app's reaction is the floor).
- **iOS `scrollUntilVisible`.** Its drags do not fling, so each moves ~340 points against
  ~540 for Maestro's swipe (more swipes for the same distance); a drag that reaches the end
  of a list waits ~0.4 s for the bounce.
- **Android `eraseText` and `back`: ~4.5x, the closest commands there.** `eraseText` sends
  all 25 DELs when the field holds fewer characters (iOS bounds them by the field's length):
  ~460 ms here. `scrollUntilVisible` (0.33 s vs 2.5 s) drags without a fling since
  2026-10-26; in a React Native list each drag moves ~1.5 rows, ~0.8 s for 4 drags.
- **iOS `launchApp`: 0.6–1.5 s vs 1.7–2.3 s.** The app's own start-up; SpringBoard's launch
  animation is not sped up (that would be a global, persistent simulator setting).

## Maestro on iOS, 2026-10-23 (before the iOS agent)

`bench_scenario_ios.yaml -e TIMES=5`, Maestro 2.11.0, all commands passed: taps 2.4–3.0 s,
`scrollUntilVisible` 3.7 / 3.0 s, `eraseText: 25` 2.0 s, `inputText` (14 characters) 1.6 s,
`assertVisible` 0.2–0.3 s, 26.0 s per iteration, ~10 s outside the flow. Its static-screen
check (two equal screenshots) took 1.46 s after a push and 1.15 s after a pop; its typing adds
0.7 s of fixed sleeps to 14 characters at 30 per second. Taps are not where it loses time
(it synthesizes events directly too): settling and hierarchy reads are.
