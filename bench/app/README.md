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
./bench.sh maestro ios        # Maestro alone, merged with speedrun's last results
./bench.sh test ios flows/chat.yaml        # one flow
```

`bench.sh` uses the booted simulator or the first adb device (`DEVICE=<id>` picks one). For
Android numbers, shut the iOS simulator down first (`../../speedrun --stop-agent`, then
`xcrun simctl shutdown all`): an emulator next to a simulator runs short of memory.

## Results

`./bench.sh compare android` and `./bench.sh compare ios`, 2026-10-27, Apple M1 Pro 16 GB, an
Android 17 emulator and an iPhone 17 Pro simulator (iOS 26.2), Maestro 2.11. A failed flow's
time stops at its failure.

| Flow (android) | speedrun | Maestro | Speedup |
|---|---:|---:|---:|
| A remembered account survives clearState on iOS, but not clearKeychain | 9 s | 34 s | 3.7x |
| Buy twice, with search, options, a promo code that fails once and the popups after | 60 s | 232 s | 3.9x |
| Cart lines, steppers and swipe to remove | 14 s | 75 s | 5.3x |
| Chat with the bot, long press and double tap a message, paste, quick replies | 23 s | 76 s | 3.3x |
| Confetti, a button that turns on late, a layout shift, a busy JavaScript thread | 18 s | 66 s | 3.6x |
| Dark mode, screenshots and a recording | 7 s | 48 s | 7.0x |
| Deep links to a product, a lab screen and the cart | 26 s | 36 s | 1.4x |
| Drag a slider and a card, scroll sideways, a long list with sticky headers | 40 s | 143 s ✗ |  |
| Edit the profile, change settings, set a PIN, sign out | 21 s | 150 s | 7.0x |
| Elements told apart by place (index, relative, parent, child) and by state | 17 s | 62 s | 3.7x |
| Feed with a ticker, stories, likes, a double tap, more posts and pull to refresh | 29 s | 82 s ✗ |  |
| Launch arguments, location, permissions, photos, orientation, app lifecycle, airplane mode | 22 s | 73 s | 3.4x |
| Onboarding pages, and no onboarding on the next launch | 4 s | 11 s | 2.9x |
| Popups that come one after another (native modals, a sheet) | 21 s | 56 s | 2.6x |
| Scripts, env, conditions, repeat and retry | 12 s | 37 s | 3.2x |
| Sign in with a phone number and a code, a wrong one first | 8 s | 40 s | 4.7x |
| Swipes in four directions, taps at a point, single, double and long press | 15 s | 44 s | 2.9x |
| Taps on screens that never stop moving | 130 s | 1450 s | 11.2x |
| Typing, keys, erasing, copy and paste, random text, a draft kept across restarts | 29 s | 159 s | 5.5x |
| **All flows** | **506 s** | **2874 s** | **5.7x** |
| **Wall clock** | **510 s** | **2892 s** | **5.7x** |

Passed: speedrun 19/19, Maestro 17/19. ✗: failed.

| Flow (ios) | speedrun | Maestro | Speedup |
|---|---:|---:|---:|
| A remembered account survives clearState on iOS, but not clearKeychain | 24 s | 78 s | 3.3x |
| Buy twice, with search, options, a promo code that fails once and the popups after | 81 s | 73 s ✗ |  |
| Cart lines, steppers and swipe to remove | 28 s | 51 s ✗ |  |
| Chat with the bot, long press and double tap a message, paste, quick replies | 26 s | 59 s ✗ |  |
| Confetti, a button that turns on late, a layout shift, a busy JavaScript thread | 21 s | 70 s ✗ |  |
| Dark mode, screenshots and a recording | 14 s | 45 s | 3.2x |
| Deep links to a product, a lab screen and the cart | 29 s | 43 s | 1.5x |
| Drag a slider and a card, scroll sideways, a long list with sticky headers | 74 s | 171 s | 2.3x |
| Edit the profile, change settings, set a PIN, sign out | 37 s | 86 s ✗ |  |
| Elements told apart by place (index, relative, parent, child) and by state | 29 s | 62 s ✗ |  |
| Feed with a ticker, stories, likes, a double tap, more posts and pull to refresh | 71 s | 96 s ✗ |  |
| Launch arguments, location, permissions, photos, orientation, app lifecycle, airplane mode | 28 s | 96 s | 3.4x |
| Onboarding pages, and no onboarding on the next launch | 10 s | 38 s | 4.0x |
| Popups that come one after another (native modals, a sheet) | 27 s | 60 s | 2.2x |
| Scripts, env, conditions, repeat and retry | 20 s | 44 s | 2.2x |
| Sign in with a phone number and a code, a wrong one first | 23 s | 48 s | 2.1x |
| Swipes in four directions, taps at a point, single, double and long press | 13 s | 48 s | 3.6x |
| Taps on screens that never stop moving | 82 s | 1231 s ✗ |  |
| Typing, keys, erasing, copy and paste, random text, a draft kept across restarts | 55 s | 107 s ✗ |  |
| **All flows** | **692 s** | **2504 s** | **3.6x** |
| **Wall clock** | **696 s** | **2517 s** | **3.6x** |

Passed: speedrun 19/19, Maestro 10/19. ✗: failed.

Why Maestro failed:

- **Screens that never stop moving** (both): each step waits for a still screen until its
  timeout: 20–24 minutes for the flow against 1.4–2.2 minutes. On iOS a tap on the
  auto-advancing carousel was not counted, then the flow ended with "Unknown error".
- **Long lists** (Android): `scrollUntilVisible` ran out of time on the 500-row list with
  sticky headers and on the feed that loads more posts as it scrolls.
- **React Native checkboxes and radio buttons** (iOS): iOS reads their state as part of their
  value ("checkbox, checked"); Maestro does not take that as `checked` (selectors, shop,
  profile).
- **Double tap** (iOS): its two taps arrive too far apart for a 300 ms double-tap window, so
  a post or a message is never liked (feed, chat).
- **A row half under a list's edge** (iOS): Maestro taps the center of the row's whole frame,
  which lies outside the list: the tap focused the search field above it (cart). speedrun
  cuts frames to the list that shows them and taps the visible part.
- **A layout shift** (iOS): a banner arriving a moment after the screen pushed the button
  down between the lookup and the tap (timing).
- **`hideKeyboard`** (iOS): it could not put the keyboard away on one screen (inputs).

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
- **A "dismiss it if it shows" check costs up to 7 s when nothing shows.** The flows start
  each run with `clearState` and `clearKeychain` instead of checking for a remembered
  account, and answer the notification prompt with "Not now"; `remember_me.yaml` and
  `sign_in.yaml` test those screens on their own.
- **Android:**
  - Asking for a precise location makes Google's "turn on Location Accuracy" dialog show
    where that setting is off; the app passes `mayShowUserSettingsDialog: false`.
  - The app is edge to edge (React Native's default on recent Android): the window does not
    shrink for the keyboard, so a field low on the screen ends up under it, and the keyboard
    covers the chat's Send button unless the screen avoids it.
  - Pull to refresh only refreshes when the pull starts at the top of the list (iOS scrolls
    up and refreshes in one drag): the feed flow pulls until it refreshes.
  - A revoked permission reads as "undetermined" until the app asks for it.
  - A Reanimated entering animation did not show the toast when it came in the same update
    as a menu closing or a screen going back; the toast fades in from a shared value.
