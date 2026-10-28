# Maestro compatibility

Speedrun reads Maestro 2.11 flow syntax and follows its behavior: how selectors match, which
element wins, timeouts, conditions, variables and scripts. Like Maestro, it is strict. An
unknown command or field is an error, and so is a Maestro feature speedrun does not support
yet. So a flow that loads runs as written; nothing is skipped silently.

In short: every Maestro command, selector, condition and script for Android and iOS is
supported, except the AI commands. The lists below are complete.

## Supported

### Commands

`launchApp` (`clearState`, `clearKeychain`, `stopApp`, `permissions`,
`arguments`), `stopApp`, `killApp`, `clearState`, `setPermissions`, `tapOn`, `doubleTapOn`,
`longPressOn`, `assertVisible`, `assertNotVisible`, `assertTrue`, `extendedWaitUntil`,
`inputText`, `inputRandomText`/`Number`/`Email`/`PersonName`/`CityName`/`CountryName`/`ColorName`,
`eraseText`, `hideKeyboard`, `back`, `pressKey`, `scroll`, `scrollUntilVisible`, `swipe`,
`waitForAnimationToEnd`, `openLink`, `takeScreenshot`, `assertScreenshot`,
`startRecording`, `stopRecording`, `addMedia`, `setLocation`, `travel`, `setOrientation`,
`setDarkMode`, `toggleDarkMode`, `assertDarkMode`, `assertLightMode`, `setAirplaneMode`,
`toggleAirplaneMode`, `clearKeychain`, `copyTextFrom`, `setClipboard`, `pasteText`,
`runFlow`, `repeat`, `retry`, `evalScript`, `runScript`. Every command takes `label` and
`optional`.

### Selectors

`text`, `id`, `index`, `enabled`, `selected`, `checked`, `focused`,
`width`/`height`/`tolerance`, `below`, `above`, `leftOf`, `rightOf`, `containsChild`,
`containsDescendants`, `childOf`, `traits`, and on taps `point`, `repeat`, `delay`,
`retryTapIfNoChange`, `waitToSettleTimeoutMs`, `waitUntilVisible`.

### Flow config and conditions

Flow config: `appId`, `name`, `env`, `tags`, `properties`, `onFlowStart`, `onFlowComplete`.
Conditions (`runFlow`'s and `repeat`'s `when`/`while`): `visible`, `notVisible`, `platform`,
`true`.

### Workspaces

`config.yaml` with `flows` globs, `includeTags`/`excludeTags`,
`executionOrder` and `testOutputDir`.

### JavaScript

`${...}` expressions, `evalScript` and `runScript`, with `output`, `maestro`
(`platform`, `copiedText`), `json()`, `relativePoint()`, `console.log`, `http`
(get, post, put, delete, request) and `faker` (Datafaker's common providers).

## Not supported

- AI commands (`assertWithAI`, `assertNoDefectsWithAI`, `extractTextWithAI`) and `--analyze`.
- Web flows (`url:`, the `css` selector).
- Real iOS devices (iOS simulators are supported; real Android devices are too).
- `--headless`, `--screen-size`, `--api-url`, `--api-key` and `--reinstall-driver` are
  accepted and ignored.

## Differences you may notice

- **Steps run back to back.** Speedrun reads the screen in milliseconds, so lookups retry
  far more often within the same timeouts, and a step starts as soon as the app has settled.
- **Android animations are turned off** by every run, as is usual for UI tests, and stay
  off. To turn them back on: `adb shell settings put global window_animation_scale 1` (and
  the same for `transition_animation_scale` and `animator_duration_scale`).
- **iOS apps started by `launchApp` animate 10x faster.** This speeds up screen transitions
  without changing what the flow sees. A flow can pass the launch argument
  `UIAnimationDragCoefficient: 1` to keep normal speed.
- **`scrollUntilVisible` scrolls without momentum**, so the list stops where the finger
  lifts. It takes more, shorter swipes, and its `speed` has no effect. `swipe` and `scroll`
  fling as in Maestro.
- **`scrollUntilVisible` scrolls the element clear of what is drawn over it** (a sticky
  footer, a floating search bar), so a tap that follows lands on it. Maestro stops once the
  element is on screen, under the footer or not.
- **A tap on an element something fixed covers** (a sticky footer or header, the keyboard)
  **scrolls it clear first**, as a user would, when it is in a list; otherwise it lands on
  the part of the element that shows. Maestro taps the element's center, which hits what is
  on top: on a small screen, a footer's button instead of the element under it.
- **`longPressOn` holds for 1.2 s**, where Maestro holds 3 s: past the 0.4–0.8 s after which
  apps take a touch as a long press (on Android, at least the device's touch & hold delay
  plus 0.7 s). For an app that waits longer, set `SPEEDRUN_LONG_PRESS_MS`.
- **iOS `doubleTapOn` lands as a double tap in React Native apps**: its two taps are one
  gesture, 200 ms apart (Maestro's arrive too far apart for a 300 ms double-tap window).
- **Several devices connected and no `--device`:** Maestro asks which one to use. Speedrun
  takes the first Android device, else the booted simulator.
- **Regular expressions:** Java-only syntax (lookarounds, inline flags, `\p{...}`) is
  rejected. A pattern that is invalid in both tools matches as plain text, as in Maestro.
- **iOS: what a list has scrolled out of view is not visible**, as on Android: an element's
  bounds are cut to the scrolling area around it, and taps aim at the part that shows.
  Maestro counts an element as visible when its frame is on screen, even if the list hides it.
- **Not in the screen hierarchy:** Android toasts, and iOS Safari web views.
- **A tap waits while a loading overlay covers its target**: a layer drawn over the screen
  with a spinner, often see-through, that takes the touches while the app loads. Speedrun
  does not wait for spinners elsewhere (they may never stop), but it does not tap through
  one.
- **iOS screens with an endless animation settle anyway.** An element that moves on every
  read (a looping animation, a marquee) while the rest of the screen holds still is left
  out of the wait.
- **Android's "… isn't responding" and "… keeps stopping" dialogs are answered** (Wait,
  else Close app), whichever app they are about: a freshly booted emulator's launcher often
  shows one, and it would hide the app under test.
- **A lost connection to Speedrun's agent is made again** (the agent started again if it
  crashed), and the step that saw it runs again, up to twice per flow.

## Conditions take up to 7 s

A `when: visible` whose element is not there waits up to 7 s for it to show, as in
Maestro, counted from the end of the last command that touched the app. Several checks in a
row share that wait: the first one waits it out, the next ones read the screen once.

Flows that dismiss popups "if they show" (notification prompts, ratings, surveys) after
every action spend most of their time there. If your popups show up early or not at all,
shorten the wait, then rerun the suite a few times to check that no popup is missed:

```sh
SPEEDRUN_CONDITION_TIMEOUT_MS=2000 speedrun test flows/
```

A condition can set its own wait with `timeout` (milliseconds, `${...}` allowed), for the one
popup that takes longer than the rest:

```yaml
- runFlow:
    when:
      visible: "Rate your experience"
      timeout: 10000
    commands:
      - tapOn: "Not now"
```

`timeout` is Speedrun's own field: Maestro does not know it and rejects a flow that uses it.
It works wherever a condition does (`runFlow` and `runScript`'s `when`, `repeat`'s `while`)
and is counted the same way as the default wait.

`assertVisible`, `extendedWaitUntil` and the lookups of `tapOn` and the like keep their own
timeouts.
