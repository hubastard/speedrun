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
| `bench_scenario.yaml`, TIMES=3 (2026-10-26) | Android emulator (API 37), `-gpu host` | 15.0 s | 96.8 s | 6.5x |
| `bench_scenario_ios.yaml`, TIMES=3 (2026-10-25) | iPhone 17 Pro simulator, iOS 26.2 | 33.0 s | 78.8 s | 2.4x |
| `flows/ignite/bench_rn.yaml`, TIMES=3 (2026-10-25) | Android emulator, `-gpu host` | 58.2 s | 195.9 s | 3.4x |
| `flows/ignite/bench_rn.yaml`, TIMES=3 (2026-10-25) | iPhone 17 Pro simulator | 75.1 s | 169.9 s | 2.3x |
| `flows/ignite/device.yaml` | iOS simulator | 40.0 s | 49.4 s | 1.2x |
| Ignite's own flows (`apps/ignite/.maestro/flows`) | iOS simulator | 27.3 s | 37.9 s | 1.4x |

Flow times; outside the flow, start-up and shutdown cost speedrun 0.6–2.7 s on Android (the
most when it pushes a new agent build) and 4–5 s on iOS cold (~0.2 s once the runner is up),
Maestro 9–13 s. The `device.yaml` and Ignite rows predate the iOS speedups of 2026-10-24/25.

`bench_scenario.yaml` per command (median ms):

| command | speedrun | Maestro |
|---|---|---|
| tap (Display & touch / Display size & text / About / Device name / Cancel) | 157–319 | 2583–3785 |
| back | 121–176 | 759–898 |
| `scrollUntilVisible` down / up | 828 / 801 | 2492 / 2452 |
| `eraseText: 25` | 350 | 2115 |
| `inputText` (14 characters) | 248 | 3570 |
| `assertVisible` | 4–64 | 84–509 |
| `launchApp` | 870 (100 in another run) | 1015 (405) |

`bench_scenario_ios.yaml` per command (median ms):

| command | speedrun | Maestro |
|---|---|---|
| tap (General / About / back / search / close) | 578–1058 | 1780–2894 |
| `scrollUntilVisible` down / up | 1264 / 1407 | 3535 / 2964 |
| `eraseText: 25` | 857 (650 since) | 1949 |
| `inputText` (14 characters) | 1197 | 1573 |
| `launchApp` | 641 | 1743 |

## Closest to Maestro

- **iOS typing into a field that hides its value (React Native): 1.2 s vs 1.5 s.** Nothing
  shows when the first character has landed, so typing falls back to a fixed 0.5 s wait,
  then 30 characters per second, as Maestro paces it. Idea: the keyboard's suggestion bar
  updates after each key and could be the signal instead.
- **iOS `inputText` in Settings' search field: 1.2–1.4 s vs 1.6 s.** Settings works ~65 ms
  per key (search results for every prefix); key-by-key typing is bound by that.
- **Long press: 3.2–3.4 s vs 3.9–4.7 s.** The press lasts 3 s, as the command defines it.
- **iOS Enter and taps that bring up or dismiss the keyboard: 0.64 s vs 0.79 s, 1.0 s vs
  1.2 s.** The keyboard's animation runs outside the app, so the 10x UIKit animation speed
  set at launch does not reach it.
- **iOS taps in general: 0.5–0.65 s vs ~0.15 s for the same tap on Android.** testmanagerd
  confirms a synthesized event ~230 ms after it, the screen starts changing ~300 ms after the
  tap begins, and a snapshot costs ~70 ms. Not waiting for the confirmation gained little for
  taps (the app's reaction is the floor).
- **iOS `scrollUntilVisible`.** Its drags do not fling, so each moves ~340 points against
  ~540 for Maestro's swipe (more swipes for the same distance); the 500 ms lookup before the
  first swipe is kept; a drag that reaches the end of a list waits ~0.4 s for the bounce.
- **Android `scrollUntilVisible`: 0.8 s vs 2.5 s, its closest command there.** The swipe
  flings and the final settle waits for the list to stop; iOS's drag that stops at lift-up
  could apply. `eraseText` also sends all 25 DELs when the field holds fewer characters (iOS
  bounds them by the field's length): 350 ms here, ~60 ms per key under software rendering.
- **iOS `launchApp`: 0.6–1.5 s vs 1.7–2.3 s.** The app's own start-up; SpringBoard's launch
  animation is not sped up (that would be a global, persistent simulator setting).

## Maestro on iOS, 2026-10-23 (before the iOS agent)

`bench_scenario_ios.yaml -e TIMES=5`, Maestro 2.11.0, all commands passed: taps 2.4–3.0 s,
`scrollUntilVisible` 3.7 / 3.0 s, `eraseText: 25` 2.0 s, `inputText` (14 characters) 1.6 s,
`assertVisible` 0.2–0.3 s, 26.0 s per iteration, ~10 s outside the flow. Its static-screen
check (two equal screenshots) took 1.46 s after a push and 1.15 s after a pop; its typing adds
0.7 s of fixed sleeps to 14 characters at 30 per second. Taps are not where it loses time
(it synthesizes events directly too): settling and hierarchy reads are.
