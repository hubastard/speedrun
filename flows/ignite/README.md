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

Flows:

- `bench_rn.yaml` — a scenario for both tools: login, the API list, favorites (switch, long
  presses), scrolling down and up, text input in the showroom, tabs.
  `./compare.sh flows/ignite/bench_rn.yaml -e TIMES=3` (with `DEVICE=<udid>` on iOS).
- Ignite's own: `./speedrun test -e MAESTRO_APP_ID=com.speedrun.ignitedemo
  apps/ignite/.maestro/flows/Login.yaml`. `FavoritePodcast.yaml` uses `copyTextFrom` and
  `${maestro.copiedText}`, not supported yet.

Learned on it: on this React Native list a swipe's end hold changes how far it scrolls (510,
700 and 1200 points for 601, 300 and 100 ms), so swipes stay exactly Maestro's; a field's
typed value is not exposed to accessibility (React Native groups it with its label), in
Maestro either; an element counted visible can sit under the tab bar, which then takes the
tap (`centerElement: true` avoids it). Since a field's value can't be read, typing can't
watch for the first character and uses Maestro's pacing; looking for the focused field must
not use a query snapshot, which retries for ~2.5 s when nothing matches.

Last run (iOS simulator, `TIMES=1`): flow 55.0 s vs Maestro's 73.1 s, wall clock 57.9 s vs
82.6 s. Slower per command: `launchApp` (speedrun waits there for the first screen; Maestro's
first tap pays it) and Enter (the keyboard sliding away is waited for).
