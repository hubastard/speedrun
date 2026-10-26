# React Native test app: Ignite's demo

[Ignite](https://github.com/infinitered/ignite) generates a React Native app (React Native
0.83, New Architecture, Expo 55, React Navigation, Reanimated) with demo screens: a login,
a component showroom, and a podcast list fetched from an API, with favorites. It also ships
its own Maestro flows (`apps/ignite/.maestro/flows`). The app lives in `apps/ignite`
(git-ignored); these steps recreate it.

```
npx ignite-cli@latest new IgniteDemo --yes --git=false --packager=npm \
  --target-path=apps/ignite --remove-demo=false --bundle=com.speedrun.ignitedemo \
  --install-deps=true --workflow=cng
(cd apps/ignite && git apply ../../flows/ignite/itunes-api.patch)
```

The patch: the demo's API (rss2json) now answers non-browser clients with a Cloudflare
challenge (HTTP 403), so the list stays empty. It reads the same podcast's episodes from
Apple's public iTunes lookup API instead, into the same model.

iOS (Release, the JavaScript bundled in; `expo run:ios` looks for Simulator.app, which
Xcode 27 replaced, so build with xcodebuild):

```
cd apps/ignite && npx expo prebuild -p ios && cd ios
xcodebuild -workspace IgniteDemo.xcworkspace -scheme IgniteDemo -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build
xcrun simctl install <udid> build/Build/Products/Release-iphonesimulator/IgniteDemo.app
```

Android (Release, arm64 for an Apple-silicon emulator; the first build installs the NDK it
needs, ~7 min):

```
cd apps/ignite && npx expo prebuild -p android && cd android
./gradlew assembleRelease -PreactNativeArchitectures=arm64-v8a
adb install -r app/build/outputs/apk/release/app-release.apk
```

Flows:

- `bench_rn.yaml` — a scenario for both tools: login, the API list, favorites (switch, long
  presses), scrolling down and up, text input in the showroom, tabs.
  `./compare.sh flows/ignite/bench_rn.yaml -e TIMES=3` (with `DEVICE=<udid>` on iOS).
- `device.yaml` (iOS) — the device commands: launch arguments, permissions, dark mode,
  cropped screenshots and `assertScreenshot`, recording, media, location, random input,
  `hideKeyboard`. Every command passes in both tools (flow 40.0 s vs Maestro's 49.4 s).
- Ignite's own, both pass: `./speedrun test -e MAESTRO_APP_ID=com.speedrun.ignitedemo
  apps/ignite/.maestro/flows` (`FavoritePodcast.yaml` copies a title with `copyTextFrom`,
  then long-presses and asserts `${maestro.copiedText}`: flow 27.3 s vs Maestro's 37.9 s).

Learned on it: Maestro's iOS swipe glides over its whole duration and lifts still moving,
so this list flings on (~530 points and ~2 s for scrollUntilVisible's), which is why
speedrun's scrollUntilVisible drags without a fling on iOS (`agent/ios/README.md`); a field's
typed value is not exposed to accessibility (React Native groups it with its label), in
Maestro either; an element counted visible can sit under the tab bar, which then takes the
tap (`centerElement: true` avoids it). Since a field's value can't be read, typing can't
watch for the first character and uses Maestro's pacing; looking for the focused field must
not use a query snapshot, which retries for ~2.5 s when nothing matches.

Last runs (2026-10-25, `bench_rn.yaml -e TIMES=3`, every command faster in both):

| | speedrun | Maestro | |
|---|---|---|---|
| iOS simulator (iPhone 17 Pro, iOS 26.2): flow | 75.1 s | 169.9 s | 2.3x |
| iOS: wall clock | 80.3 s | 179.9 s | 2.2x |
| Android emulator (API 37, `-gpu host`): flow | 58.2 s | 195.9 s | 3.4x |
| Android: wall clock | 58.9 s | 205.0 s | 3.5x |

speedrun on iOS trails its Android self mostly on typing (Maestro's pacing for a field that
hides its value: 1.2 s vs 0.2 s), scrolling (3.7 s vs 2.6 s a scroll) and taps (~0.5 s vs
~0.15 s for a tab).

`simctl addmedia` is done by the simulator's service, which needs macOS's permission to read
a file under Downloads, Documents or Desktop: until the "would like to access files" prompt
is answered, the command waits, and every simctl call after it (launch, terminate,
screenshots) queues behind it, even across a simulator reboot. speedrun copies media to the
temp folder first, so its `addMedia` never asks; Maestro passes the flow's own path.
