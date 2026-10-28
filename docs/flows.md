# Writing flows

A flow is a YAML file that describes what a user does in your app: open it, tap, type, scroll,
and check what is on screen. Speedrun runs it on an Android emulator or device, or an iOS
simulator. The format is [Maestro](https://maestro.dev)'s, so flows written for Maestro run
as they are; this page assumes you have never used either.

## A first flow

```yaml
appId: com.example.app        # the app's package name (Android) or bundle id (iOS)
name: Sign in                 # optional: the name shown in reports
---
- launchApp:
    clearState: true          # start as if just installed
- tapOn: "Email"
- inputText: "user@example.com"
- tapOn: "Password"
- inputText: ${PASSWORD}
- tapOn: "Sign in"
- assertVisible: "Welcome"
```

```sh
speedrun test sign-in.yaml -e PASSWORD=secret
```

Above the `---` is the flow's configuration; below it, the steps, run one after the other.
Each step waits for the app before it acts: a tap waits for its element to show (up to 17 s),
and the next step starts once the app has finished reacting. A step that fails stops the
flow, and Speedrun shows what was on screen and where it saved a screenshot and logs.

To find out what to write, open the app in a [session](sessions.md) and list the screen:

```sh
speedrun session start --app com.example.app
speedrun look            # @5 Field #email "Email", @7 Button "Sign in" ...
```

`#email` is the element's id, `"Sign in"` its text.

## Finding elements

Most steps act on an element, picked by a *selector*. The short form is the element's text:

```yaml
- tapOn: "Sign in"
```

The text is matched against what the element shows: its text, its accessibility label (the
content description on Android), or a field's placeholder. It is a regular expression that
must match the whole text, ignoring case: `"Sign in"` matches `SIGN IN` but not
`Sign in now`. Use `"Sign in.*"` to match the start only, and escape the characters regular
expressions use: `"Cart \\(3\\)"`.

The long form takes more fields. An **id** is the most stable choice: the view's resource id
on Android, the accessibility identifier on iOS (`testID` in React Native):

```yaml
- tapOn:
    id: "submit"
```

When several elements match, narrow it down:

```yaml
- tapOn:
    text: "Delete"
    below: "Shopping cart"    # also above, leftOf, rightOf (each takes a selector)
- tapOn:
    id: "product-card"
    index: 2                  # the third match, counted from the top
- tapOn:
    text: "Edit"
    childOf:                  # inside the element that...
      id: "profile-header"    # (also containsChild, containsDescendants)
```

And by state: `enabled`, `checked`, `selected`, `focused` (`true` or `false`):

```yaml
- assertVisible:
    id: "terms"
    checked: true
```

## The commands you will use most

### Starting the app

```yaml
- launchApp                   # the flow's appId; stops it first if it was running
- launchApp:
    clearState: true          # its data erased first (iOS: reinstalled)
    clearKeychain: true       # iOS: the keychain too (saved logins)
    permissions:
      notifications: allow    # also location, camera, contacts, photos, microphone,
      location: deny          # medialibrary, calendar, or `all`; allow, deny or unset
    arguments:
      onboarding: false       # launch arguments the app can read
- stopApp                     # also killApp, clearState, setPermissions
```

### Tapping

```yaml
- tapOn: "Sign in"
- doubleTapOn:
    id: "post-photo"
- longPressOn: "Message"
- tapOn:
    point: "50%,90%"          # a point on the screen, in % or pixels ("200,400")
```

### Typing

`inputText` types into the field that has the keyboard, so tap the field first. `eraseText`
deletes from that field too:

```yaml
- tapOn:
    id: "search"
- inputText: "sneakers"
- eraseText: 1                # deletes 1 character (`eraseText` alone: 50, enough to empty most fields)
- pressKey: Enter             # also Backspace, Back, Home, Tab, Escape...
- tapOn:
    id: "email"
- inputRandomEmail            # also inputRandomText, inputRandomNumber, inputRandomPersonName...
- hideKeyboard
```

### Checking the screen

```yaml
- assertVisible: "Order placed"
- assertNotVisible: "Something went wrong"
- extendedWaitUntil:          # the same, with your own time limit
    visible: "Payment accepted"
    timeout: 30000            # milliseconds
- assertTrue: ${output.total > 0}
```

`assertVisible` waits up to 17 s for the element to show, `assertNotVisible` for it to go.

### Scrolling and swiping

```yaml
- scrollUntilVisible:
    element: "Row 60"         # scrolls until it is fully on screen
    direction: DOWN           # the default; also UP, LEFT, RIGHT
    timeout: 60000            # default 20000 ms
- scroll                      # once, down
- swipe:
    direction: LEFT           # across the screen
- swipe:
    from:
      id: "card"              # starting on an element
    direction: UP
- swipe:
    start: "90%,50%"
    end: "10%,50%"
```

### Going around the app

```yaml
- back                        # Android's back button (does nothing on iOS)
- openLink: "myapp://product/42"   # a deep link or a web address
```

### Device and other commands

`setLocation` (`latitude`, `longitude`), `travel` (a route of points at a `speed`),
`setOrientation` (`PORTRAIT`, `LANDSCAPE_LEFT`, `LANDSCAPE_RIGHT`, `UPSIDE_DOWN`),
`setDarkMode`, `toggleDarkMode`, `setAirplaneMode`, `takeScreenshot`, `assertScreenshot`,
`startRecording` and `stopRecording`, `addMedia` (photos and videos into the gallery),
`copyTextFrom`, `setClipboard` and `pasteText`. All of them are in the
[reference](#all-commands) below.

## You do not need sleeps

There is no `sleep` command, and you should not need one. Before each step, Speedrun waits
for the app to settle, for the element to show, for a disabled button to turn on, for a
loading overlay to go and for a popup to finish sliding in. It does not wait for things that
never stop (spinners, tickers, looping animations).

When a step really depends on something slow, such as a network call, wait for its *result*:

```yaml
- tapOn: "Pay"
- extendedWaitUntil:
    visible: "Payment accepted"
    timeout: 30000
```

## Organizing your tests

### Variables

```yaml
appId: com.example.app
env:
  USER: ${USER || 'alex@example.com'}   # `-e USER=...` on the command line, else this
  PLAN: premium                         # always premium: the flow's own value wins over -e
---
- inputText: ${USER}
```

A value passed with `-e` is a variable for every flow (`${PASSWORD}` in the first example).
The flow's `env` is set after it, so a plain value there replaces it; `${USER || '...'}` keeps
the one from the command line when there is one. `${...}` holds any JavaScript expression:
`${USER.toUpperCase()}`.

### Reusing steps

Put shared steps in their own file and call it:

```yaml
- runFlow: flows/sign-in.yaml
- runFlow:
    file: flows/add-to-cart.yaml
    env:
      PRODUCT: "City Sneaker"
```

### Steps that only run sometimes

```yaml
- runFlow:
    when:
      visible: "Rate this app"    # also notVisible, platform: Android or iOS, true: ${...}
    commands:
      - tapOn: "Not now"
```

A condition waits up to 7 s for its element. Any step can also be `optional: true`: it is
tried, and the flow goes on if it fails.

### Repeating and retrying

```yaml
- repeat:
    times: 3
    commands:
      - tapOn: "+"
- repeat:
    while:
      notVisible: "End of list"
    commands:
      - scroll
- retry:
    maxRetries: 2               # runs the steps again if one fails
    commands:
      - tapOn: "Refresh"
      - assertVisible: "Up to date"
```

### JavaScript

```yaml
- evalScript: ${output.code = '1234'}
- inputText: ${output.code}
- runScript: scripts/create-user.js    # can call an API with http.post(...)
```

Scripts share an `output` object, and can read `maestro.platform` and
`maestro.copiedText` (the text `copyTextFrom` copied).

### Folders and tags

`speedrun test flows/` runs every flow in a folder. Tags pick some of them:

```yaml
appId: com.example.app
tags: [smoke, checkout]
---
```

```sh
speedrun test flows/ --include-tags smoke
```

A `config.yaml` in the folder can set which flows run and in what order. Every option is in
[Command line](cli.md).

### Labels

Any step takes a `label`, shown in the output and the reports instead of the step:

```yaml
- tapOn:
    id: "btn-7f3a"
    label: "Open the cart"
```

## All commands

| Command | What it does |
|---|---|
| `launchApp` | Starts the app (`clearState`, `clearKeychain`, `stopApp`, `permissions`, `arguments`). |
| `stopApp`, `killApp` | Stops the app. |
| `clearState` | Erases the app's data. |
| `clearKeychain` | iOS: erases the keychain. |
| `setPermissions` | Grants or denies permissions without launching. |
| `tapOn`, `doubleTapOn`, `longPressOn` | Taps an element or a `point`. |
| `inputText` | Types into the focused field. |
| `inputRandomText`, `inputRandomNumber`, `inputRandomEmail`, `inputRandomPersonName`, `inputRandomCityName`, `inputRandomCountryName`, `inputRandomColorName` | Types random text of that kind. |
| `eraseText` | Deletes characters (50 by default). |
| `hideKeyboard` | Puts the keyboard away. |
| `pressKey` | Presses a key: `Enter`, `Backspace`, `Back`, `Home`, `Tab`, `Escape`, `Volume Up`... |
| `back` | Android's back button. |
| `assertVisible`, `assertNotVisible` | Checks that an element shows (or not), waiting up to 17 s. |
| `extendedWaitUntil` | The same, with a `timeout`. |
| `assertTrue` | Checks a JavaScript expression. |
| `scrollUntilVisible` | Scrolls until an element is fully on screen. |
| `scroll` | Scrolls once. |
| `swipe` | Swipes by `direction`, from an element, or from `start` to `end`. |
| `waitForAnimationToEnd` | Waits for the screen to stop moving (rarely needed). |
| `openLink` | Opens a deep link or a web address. |
| `takeScreenshot`, `assertScreenshot` | Saves a screenshot, or compares the screen with one. |
| `startRecording`, `stopRecording` | Records a video of the screen. |
| `addMedia` | Adds photos or videos to the gallery. |
| `setLocation`, `travel` | Sets the GPS position, or moves it along a route. |
| `setOrientation` | Rotates the device. |
| `setDarkMode`, `toggleDarkMode`, `assertDarkMode`, `assertLightMode` | Dark mode. |
| `setAirplaneMode`, `toggleAirplaneMode` | Airplane mode. |
| `copyTextFrom`, `setClipboard`, `pasteText` | Copies an element's text or a value, and pastes it. |
| `runFlow` | Runs another flow file, or inline `commands`, optionally `when` a condition holds. |
| `repeat` | Runs steps a number of `times`, or `while` a condition holds. |
| `retry` | Runs steps again if one fails. |
| `evalScript`, `runScript` | Runs JavaScript. |

Differences from Maestro, and what is not supported: [Maestro compatibility](maestro-compatibility.md).
