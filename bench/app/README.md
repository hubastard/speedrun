# Speedrun Bench

An app made to be tested: a React Native (Expo) app whose screens cover what flows do in real
apps, and the flows that drive it. It is both speedrun's regression suite (every command and
selector speedrun supports, on Android and iOS, with the same flow files) and a benchmark
against Maestro on hard, real-world screens.

## What's in it

| Area | Screens | What the flows exercise |
|---|---|---|
| Sign in | Onboarding pager, phone number (formatted as typed), one-time code (one box per digit), "Welcome back" (keychain) | `swipe`, `inputText`, `eraseText`, `runFlow` conditions, a popup that hides the screen behind it, `clearState` vs `clearKeychain` |
| Home | A ticker that never stops, spinning story rings, a skeleton loader, a banner that pushes the feed down, likes, pull to refresh, more posts at the end | Endless animations, `doubleTapOn`, `scrollUntilVisible` with loading, `swipe` to refresh |
| Shop | Debounced search, category chips, product page (photo carousel, color, size, quantity, gift wrap), cart (swipe to remove, a promo code that fails once), checkout (keyboard over a sticky footer), confirmation with confetti | `pressKey`, `selected`/`checked`/`enabled`, `repeat`, `retry`, `hideKeyboard`, `copyTextFrom`, `inputRandom*`, popups after an order |
| Chats | A bot that "types" (bouncing dots) before answering, a long-press menu, double tap to react | `longPressOn`, `doubleTapOn`, `setClipboard`, `pasteText`, `tapOn` at a point |
| Profile | Edit form (validation on blur), settings (switches, a native alert, a long list), PIN on a custom keypad | Native alerts, keypads, a layout that moves under the keypad |
| Lab | One screen per kind of animation, gestures, selectors, inputs and keys, device APIs | See below |

The lab:

- **Animations**: a still screen, then a Reanimated loop, `Animated` loops (native driver and
  JavaScript), Lottie, a spinner, a ticker (100 ms), a number changing every frame, a marquee,
  skeletons, an auto-advancing carousel, a progress bar, confetti, a button that turns on late,
  a layout shift, a busy JavaScript thread. Each has a Tap button and its count.
- **Gestures**: swipe in four directions, tap at a point of an element, single / double / long
  press. **Drag and scroll**: a slider, drag and drop, a horizontal list, a 500-row list with
  sticky headers.
- **Selectors**: `index`, `below`, `above`, `leftOf`, `childOf`, `containsChild`,
  `containsDescendants`, `enabled`, `selected`, `checked`, `focused`, `optional`.
- **Inputs and keys**: Enter, Backspace, Android's back button, erasing, copy and paste, random
  text, a draft that survives `stopApp` / `killApp` (not `clearState`).
- **Device**: launch arguments, location (`setLocation`, `travel`), permissions
  (`setPermissions`), photos (`addMedia`), orientation, dark mode, airplane mode (Android),
  app lifecycle (`pressKey: Home`, `stopApp`, `killApp`), screenshots and recordings.

## Running it

```sh
./bench.sh build ios          # or android: expo prebuild, a Release build, installed
./bench.sh test ios           # the suite with speedrun
./bench.sh compare ios        # speedrun, then Maestro: results/ios.md
./bench.sh test ios flows/chat.yaml        # one flow
```

`bench.sh` uses the booted simulator or the first adb device (`DEVICE=<id>` picks one). For
Android numbers, shut the iOS simulator down first (`../../speedrun --stop-agent`, then
`xcrun simctl shutdown all`): an emulator next to a simulator runs short of memory.

## Things the app shows about real apps

- **iOS hides what a popup covers.** While a full-screen overlay is up, iOS leaves the screen
  behind it out of the accessibility tree: a check for the home screen waits until the popup
  is closed. The sign-in flow waits for "home or the prompt", then dismisses the prompt.
- **On iOS, a React Native view with a `testID` is not the parent of its content** in the
  accessibility tree: its children sit beside it. `childOf` / `containsChild` need a native
  container (a `ScrollView` here), on Maestro as on speedrun.
- **Simulators may ask "Open in …?"** when a link opens the app from outside: the deep-link
  flow answers it when it shows.
- **Relative selectors keep the text filter's order**: `{text: Choose, rightOf: {text: Pro}}`
  is the first "Choose" right of "Pro" in the tree, not the nearest (Maestro's semantics).
