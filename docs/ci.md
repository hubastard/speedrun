# Running on CI

```sh
speedrun test flows/ --format junit --output report.xml --debug-output debug --flatten-debug-output
```

- **Reports:** `--format junit` for your CI's test results, `html` or `html-detailed` for a
  page to read. Speedrun exits with status 1 when a flow fails.
- **Failures:** each failed flow's folder in the debug output has its screenshots and logs,
  with `logs/debug.log` tracing the end of the run. Keep the folder as a build artifact: it is
  what to look at, or zip, when a flow fails only on CI ([Troubleshooting](troubleshooting.md)).
- **Several devices:** `--shard-split <n>` splits the flows across n devices
  (`--device a,b`), `--shard-all <n>` runs every flow on each. Tags pick flows:
  `--include-tags`, `--exclude-tags`. All options: [Command line](cli.md).
- **Android emulators:** a freshly booted emulator's launcher often stalls, and its "isn't
  responding" dialog can take a flow's keys. Speedrun answers the dialog; to keep it from
  coming up, see [Troubleshooting](troubleshooting.md).

## iOS: boot the simulator with `speedrun fast-boot`

A CI runner boots its simulator for the first time, and for minutes after that the
simulator's background services take the CPU your tests need: Siri and Apple Intelligence,
Spotlight's indexing, widgets and wallpapers, iCloud and App Store syncing, the services of
the Health, Fitness, News, Weather and Maps apps, diagnostics. `speedrun fast-boot` turns off
about 140 of them, then boots the simulator. Use it in place of `xcrun simctl boot`:

```sh
UDID=$(xcrun simctl create ci "iPhone 17 Pro")   # or a simulator the runner already has
speedrun fast-boot --device "$UDID"              # turns the services off, boots it, waits for the boot
xcrun simctl install "$UDID" MyApp.app
speedrun test -p ios --device "$UDID" flows/ --format junit --output report.xml
```

On Speedrun's own CI (GitHub Actions, `macos-26` runner), the iOS job went from about 10
minutes to about 6 (9.6–11.1 minutes in its last 6 runs before, 4.7–6.7 in its first 5 with
it), with one more flow than before. In the first run with it, Speedrun's agent started in
33 s instead of 61 s, and the [benchmark journey](../bench/journey) ran in 51 s instead of
76 s.
On a 10-core Mac, with a never-booted iPhone 17 Pro (iOS 26.2):

| | `simctl boot` | `speedrun fast-boot` |
|---|---:|---:|
| Boot | 29 s | 25 s |
| The services' CPU in the first minute after it | 205 s | 50 s |
| Boot, install the app, 4 flows | 137 to 150 s | 116 s |

### Boot it while your app builds

The boot takes a minute or more on a runner. Start it in the background, and wait for it
before the tests:

```sh
speedrun fast-boot --device "$UDID" > boot.log 2>&1 &
BOOT=$!
./build-my-app.sh
wait $BOOT || { cat boot.log; exit 1; }
```

In GitHub Actions each step is its own shell: Speedrun's
[workflow](../.github/workflows/journey.yml) starts the boot in one step and waits for it in a
later one.

### What keeps working

What an app calls keeps working: push notifications, universal links, the photo library,
contacts, calendars and reminders, HealthKit, HomeKit, StoreKit's products, Apple Pay,
CloudKit, Sign in with Apple, the keychain. In-app purchases do not. The list is
[host/fast_boot/services.txt](../host/fast_boot/services.txt), taken from
[SimSlim](https://github.com/MobAI-App/simslim).

### Notes

- **iOS 18.5 or later.** Earlier ones forget the setting when they boot: there it boots the
  simulator as it is, with a warning, so the same script runs on any simulator. It fails only
  when the simulator does not boot, as `xcrun simctl boot` would.
- **The services stay off**, through `simctl erase` too, until `speedrun fast-boot --off`. A
  booted simulator is shut down and booted again.
- **It helps a fresh boot.** A simulator that has been up for a while is quiet either way, and
  turning the services off does not make its flows faster: on your Mac it changes little after
  the first minutes.
