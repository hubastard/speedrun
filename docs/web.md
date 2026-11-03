# Web

Speedrun tests websites in Chrome or Firefox with the same flow format as apps. A flow with
`url:` in its config is a web flow: `launchApp` opens that page.

```yaml
url: https://example.com/login
---
- launchApp
- tapOn: Email
- inputText: user@example.com
- tapOn: Sign in
- assertVisible: Welcome
```

```sh
speedrun test --headless login.yaml        # a web flow runs in the browser on its own
speedrun test --headless flows/            # a folder of web flows
speedrun test -p web flows/                # web, explicitly (a visible window without --headless)
speedrun test --headless --device firefox flows/                     # in Firefox
speedrun test --headless --device chromium,firefox --shard-all 2 flows/   # every flow in both
```

When every flow of a run is a web flow, Speedrun runs them in the browser, as Maestro does.

## Options

| Option | |
|---|---|
| `--headless` | No window (as on CI). Without it, Chrome opens a window you can watch. |
| `--screen-size <W>x<H>` | The window's size (default 1024x768 headless, as Maestro). |
| `-p`, `--platform web` | Run in the browser (the device name `chromium` does the same). |
| `--device firefox` | Run in Firefox instead of Chrome (`--device chromium`, the default). |
| `--shard-split <n>`, `--shard-all <n>` | Split the flows across n browsers, each its own Chrome. With `--device chromium,firefox`, the shards take the browsers in turn: `--shard-all 2` runs every flow in both. |
| `--animations fast` | The page's animations (CSS transitions and animations, Web Animations) run 10x faster; `off` also tells the page `prefers-reduced-motion` and runs them 100x faster. The default, `normal`, leaves the page as it is. Its timers keep their time. |

## Chrome

Speedrun drives Chrome directly, through the DevTools protocol over a pipe: no WebDriver,
no Selenium, no Node. Which Chrome:

- `SPEEDRUN_CHROME`, when set: a Chrome or Chromium executable.
- `--headless`: Chrome's headless shell, the build made for headless runs (as Playwright
  uses), else
- the Chrome installed on the machine (`/Applications/Google Chrome.app`, or `google-chrome`
  or `chromium` on Linux), else
- [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/), downloaded
  on first use into Speedrun's cache (`~/Library/Caches/speedrun/chrome`, on Linux
  `~/.cache/speedrun/chrome`), with `curl` and `unzip`.

Each run starts with a fresh profile: no cookies, storage or cache from an earlier run.

Chrome runs with its sandbox. Where it cannot run, Chrome exits at once (Ubuntu 23.10 and
later keep it from the user namespaces it needs: GitHub's `ubuntu-24.04` runners among them),
and Speedrun starts it again without, as Playwright does by default, and says so. To keep the
sandbox there: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.

## Firefox

`--device firefox` runs the flows in Firefox, driven over
[WebDriver BiDi](https://w3c.github.io/webdriver-bidi/), the W3C protocol Firefox speaks
since it dropped Chrome's: still no WebDriver binary, no Selenium, no Node. Which Firefox:

- `SPEEDRUN_FIREFOX`, when set: a Firefox executable.
- On macOS, the Firefox installed in `/Applications`, else
- the newest Firefox release from Mozilla, downloaded on first use into Speedrun's cache
  (`~/Library/Caches/speedrun/firefox`, on Linux `~/.cache/speedrun/firefox`), with `curl`
  (and `hdiutil` on macOS, `tar` on Linux). On Linux Speedrun always uses its own copy: a
  distribution's Firefox is often a snap, which cannot use a profile in the temporary folder.

Everything on this page works in Firefox as in Chrome, with the same flows. Firefox starts
more slowly (about a second more per run), and typing takes a little longer per key.
Speedrun starts it with system access to the browser's own settings, which it uses for
`setDarkMode` and `clearState` (WebDriver BiDi has no command for either); Firefox accepts
one client at a time, and Speedrun's connects as soon as Firefox opens its port.

## How it waits

A step starts when the page has finished reacting to the one before, which Speedrun learns
from the page itself: changes to the page, input, scrolls, requests still in flight, short
timers that have not run yet, elements that shifted, and animations that push other
elements around (a panel growing open). It does not compare screenshots or poll: a lookup
waiting for an element reads the page again the moment it changes. Things that never stop (a
ticking counter, a spinner, an autoplaying carousel) don't hold a step up.

An animation that moves only its own element (a menu growing in, a drawer sliding in, a
field's label floating up, a button's ripple) holds up only a tap aimed at that element or
something in it: the tap waits for it to come to rest, then lands where it is. A tap that
something else would take (a dialog still fading out over the page) waits for it to go.

## What each command does in the browser

- `launchApp` opens the flow's `url`. With `clearState: true` it first clears what the
  browser keeps for that site (cookies, storage, caches, service workers). Its `arguments`
  become globals of the page (`window.greeting` for `greeting: World`), set before the page's
  own scripts run.
- `tapOn`, `doubleTapOn`, `longPressOn` click with the mouse (a double click fires
  `dblclick`; a long press holds 0.8 s). A point outside the window is scrolled into view
  first.
- `inputText` types into the focused element: each character a key press, as a keyboard
  sends them. `eraseText` presses Backspace. `pressKey` takes Enter, Backspace, Delete, Tab,
  Escape, Space, the arrows, Home, End, Page Up and Page Down; Back goes back in the history.
- `scrollUntilVisible` brings an element the page already has (off screen, or in the hidden
  part of a list) into view at once; for rows a list makes only as it scrolls, it scrolls the
  list under the middle of the window, step by step. `swipe` and `scroll` scroll what is under
  the swipe with the mouse wheel.
- `openLink` opens a page in the same tab (`https://` is added when the link has no scheme).
  `back` goes back in the history.
- A `<select>`: tap it, then tap one of its options.
- `setDarkMode`, `toggleDarkMode`, `assertDarkMode`, `assertLightMode`: the page's
  `prefers-color-scheme`.
- `setLocation` and `travel`: the page's geolocation, allowed without asking.
- `takeScreenshot` and `assertScreenshot`: the page, in the window's size.
- `when: platform: Web` is true in the browser, and `maestro.platform` is `web` in scripts.
- Browser dialogs (`alert`, `confirm`, `prompt`) are accepted. A link or script that opens
  a new window or tab moves the flow to it.
- `stopApp`, `killApp`, `clearKeychain`, `hideKeyboard`, `setPermissions`, `addMedia`,
  `setOrientation` and airplane mode do nothing in the browser, as in Maestro.

## Finding elements

As in Maestro's web support:

- **`text`** is an element's own text (not its children's), an input's value or else its
  placeholder, a `<select>`'s chosen option.
- **`id`** is the element's `id`, else its `aria-label`, `name`, `title`, `for`, or
  `data-testid`.
- **`css`** takes a CSS selector: `tapOn: { css: "form button[type=submit]" }`.

A few differences from Maestro's:

- Text is compared as the page shows it: white space collapsed and trimmed. A button written
  over three lines in the HTML is `Save`, not `"\n  Save\n"`.
- Elements that a scrolling or clipping box hides are not visible, and taps aim at the part
  that shows.
- `enabled`, `checked`, `selected` and `focused` work (Maestro's web hierarchy has no such
  states).

## Not supported yet

- Safari (Maestro runs only Chrome).
- `startRecording` in the browser.
- Content of frames from another site (a payment form in a cross-origin `<iframe>`);
  same-site frames work.
- Uploading and downloading files.
