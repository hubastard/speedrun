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
- **Web flows** run headless with `--headless`, on macOS or Linux runners; Speedrun downloads
  Chrome's headless shell on the first run (about 100 MB; cache `~/.cache/speedrun/chrome`
  on Linux to skip it). With `--shard-split <n>`, each shard runs its own Chrome. See
  [Web](web.md).
- **Android emulators:** a freshly booted emulator's launcher often stalls, and its "isn't
  responding" dialog can take a flow's keys. Speedrun answers the dialog; to keep it from
  coming up, see [Troubleshooting](troubleshooting.md).

## Android: boot the emulator with `speedrun fast-boot`

A new emulator's first minutes go to its preinstalled apps setting themselves up: the Google
app, Gmail, YouTube, Photos, Drive, Digital Wellbeing, Android System Intelligence and more.
`speedrun fast-boot` boots the AVD, turns those apps off and waits for the boot; `--headless`
boots it without a window:

```sh
speedrun fast-boot --device "$AVD" --headless   # an AVD's name (emulator -list-avds)
adb install MyApp.apk
speedrun test -p android flows/ --format junit --output report.xml
```

Where something else boots the emulator (the
[Android Emulator Runner](https://github.com/ReactiveCircus/android-emulator-runner) action),
run `speedrun fast-boot` first in its script: it turns the apps off on the emulator running,
which saves as much as turning them off during the boot.

A new AVD (Android 16, API 36.1, with Google APIs; 4 cores, 2.5 GB of RAM) on a 10-core Mac:

| | `emulator` | `speedrun fast-boot` |
|---|---:|---:|
| Boot | 33 to 35 s | 35 to 36 s |
| The apps' CPU in the first minute after it | 204 to 212 s | 104 to 117 s |
| In the second minute | 45 to 57 s | 5 to 14 s |
| The emulator's memory on the Mac | 5.3 GB | 5.1 GB |

What an app reaches stays on: Chrome (links, custom tabs, sign-in pages), the Play Store
(billing, in-app reviews and updates, Play Integrity), Play services (push, maps, sign-in,
location), the keyboard, and the apps an app's links open (Messages, phone, contacts,
calendar, clock, camera, Maps, files), and text to speech. The list is
[host/fast_boot/android-apps.txt](../host/fast_boot/android-apps.txt).

- **The apps stay off**, through reboots, until `speedrun fast-boot --off`. A running
  emulator is not restarted, unless `--headless` takes its window away.
- **It helps a first boot.** An emulator that has booted before is quiet either way:
  Speedrun's 21 benchmark flows took 407 s on one with the apps on, and 407 s with them off.
- **Emulators only.** It refuses a phone or a tablet.

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
33 s instead of 61 s, and the [benchmark journey](https://github.com/hubastard/speedrun-bench/tree/main/journey) ran in 51 s instead of
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
