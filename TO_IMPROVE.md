# Things to improve

speedrun against Maestro on the same flow files: how it is measured, the latest numbers, and
the commands where speedrun is still closest to Maestro, with what is known about why.

## Open questions from the benchmark app (bench/app, 2026-10-26)

- **A tap on an element under the keyboard hits the keyboard** (Maestro too): the target's
  center is inside the keyboard's frame, so the tap types a key or a suggestion, and the
  next typing goes to the field that still has the focus. speedrun could fail such a tap at
  once ("covered by the keyboard: hideKeyboard first") instead of typing junk; that would
  fail flows that pass by accident today, so it is not done.
- **One field per digit, the focus jumping after each key**: both tools lose digits on iOS
  (Maestro 2/2 runs failed, speedrun most). speedrun types key by key once it sees the focus
  move, which helps but does not make it reliable; the app now uses one field drawn as six
  boxes, as code-entry libraries do.
- **iOS `setPermissions` takes effect at the next launch** (the TCC database is written; a
  running app keeps what it read), and `launchApp` without `permissions:` grants everything
  again, as in Maestro.
- **A tap on Android took 16 minutes once** (the benchmark app's inputs flow, the tap on a
  field after `scrollUntilVisible`), then the flow passed; three reruns took 24–34 s. No ANR or
  crash in logcat. The agent's touch injection goes through UiAutomation, which waits on
  SurfaceFlinger around DOWN and UP: an emulator stall there blocks the whole command. A time
  limit on agent operations would turn such a hang into a failure (Maestro has none either).
- **The iOS simulator's hardware keyboard setting** decides whether the software keyboard
  shows; this one has it on, yet the keyboard showed in some fields: flows should not depend
  on it either way.

## Measuring

```
cd bench/app
./bench.sh compare ios             # the suite with speedrun, then Maestro: results/ios.md
./bench.sh compare android
cd ../.. && ./compare.sh bench/app/flows/gestures.yaml    # one flow, per command
```

`bench.sh compare` runs the benchmark app's suite (`bench/app/flows`, 19 flows) with each
tool on the same device and writes a table per flow plus the wall clock of each whole run
(each tool's start-up included). On iOS it stops speedrun's kept-alive agent before each
run, so both start cold. `compare.sh` takes one flow file: it starts the flow's app fresh
before each tool, lines the two runs up command by command (warning if their command
sequences or statuses differ) and prints medians per command, then the flow, the time outside
it and the wall clock per tool. Both need `maestro` and `python3` on PATH.

Before a run: shut the iOS simulator down for Android numbers (memory pressure on a 16 GB Mac
stalls the emulator; stop speedrun's iOS agent first with `./speedrun --stop-agent`, or
xcodebuild boots the simulator again and runs `simctl diagnose`), and stop stray emulators
for iOS numbers (a stalled one made Maestro hang in adb before starting).

## Latest results

The benchmark app's suite, 2026-10-27, Apple M1 Pro 16 GB:

| device | speedrun | Maestro | ratio | passed (speedrun / Maestro) |
|---|---|---|---|---|
| Android 17 emulator (API 37), `-gpu host` | 510 s | 2892 s | 5.7x | 19/19 / 17/19 |
| iPhone 17 Pro simulator, iOS 26.2 | 696 s | 2517 s | 3.6x | 19/19 / 10/19 |

Per flow: `bench/app/README.md`. Closest to Maestro: the deep-link flow (1.4–1.5x: three
"Open in …?" checks wait 7 s each when the dialog does not show, in both tools), the popups
and scripting flows on iOS (2.2x).

## Earlier benchmarks (flows removed 2026-10-26)

Before the benchmark app, speedrun was measured on Android's and iOS's Settings app (a
14-step scenario, 3 laps) and on the Ignite React Native demo app; those flows, and the
other tools' ports of the Settings scenario, are in git history up to commit 5fdcb19.
Wall clock on 2026-10-26: Settings on Android, speedrun 11.2 s, tester-army e2e 0.17 32.0 s,
UI Automator 2.3 48.9 s, Appium 3.8 52.7 s, Maestro 2.11 90.7 s; Settings on iOS, speedrun
31 s, e2e 65 s, Maestro 93 s; Ignite, speedrun 31.2 s vs Maestro 188.1 s on Android and
57.4 s vs 169.4 s on iOS. Per command on Android Settings, speedrun's taps took 161–328 ms
against Maestro's 2.1–3.8 s, `scrollUntilVisible` 0.33 s against 2.3 s, `inputText` (14
characters) 255 ms against 2.9 s.

## Closest to Maestro

- **iOS typing into a field that hides its value (React Native): 1.2 s vs 1.5 s.** Nothing
  shows when the first character has landed, so typing falls back to a fixed 0.5 s wait,
  then 30 characters per second, as Maestro paces it. Idea: the keyboard's suggestion bar
  updates after each key and could be the signal instead.
- **iOS `inputText` in Settings' search field: 1.2–1.4 s vs 1.6 s.** Settings works ~65 ms
  per key (search results for every prefix); key-by-key typing is bound by that.
- **Long press: ~1.4 s vs 3.9–4.7 s.** The hold is 1.2 s (2026-10-26; 3 s before), past
  the apps' usual 0.4–0.8 s delay. One that opens an iOS context menu costs ~3 s: the
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
