# Speedrun against agent tools

The steps an AI agent takes to try out a feature of [Speedrun Bench](../app), driven through
three tools that let an agent use a mobile app, each from its command line and with the loop
its documentation recommends:

1. Launch the app, freshly installed (its data reset before each run, not timed).
2. Skip the onboarding, continue as a guest.
3. Open the shop, search "sneaker", check that "6 products" shows.
4. Open "City Sneaker", check that its sizes show.

There is no model in the loop: [`bench.py`](bench.py) makes the calls an agent would make, the
same ones every run, so the tools are compared on what they cost an agent, not on what a model
decided. Per run it measures the wall time, the number of calls, and everything the tools
printed, which is what the agent reads (in characters, and in tokens estimated as characters
/ 4).

| Tool | Version | How the agent uses it |
|---|---|---|
| Speedrun | this repo | `speedrun session start`, then `speedrun look` once and a `speedrun do '<command>'` per step; each answer says how the step went and what changed on screen. |
| [agent-device](https://github.com/callstackincubator/agent-device) | 0.21.33 | `open --foreground` (the first screen's elements), then `click`/`fill <selector> --settle` (acts, waits for the screen to settle, prints what changed) and `wait` for the checks. |
| [Argent](https://github.com/software-mansion/argent) | 0.31.0 | `argent run <tool>`: `describe` to read the screen, `gesture-tap` at the centre of the element it lists, `await-screen-idle` after launching and after each tap (its guide: a tap does not wait for the app), `keyboard` to type, `await-ui-element` for the checks. |

## Results

2026-10-28, Apple M1 Pro (16 GB), an Android 17 emulator and an iPhone 17 Pro simulator
(iOS 26.2). The median of 3 runs after a warm-up (each run's time in seconds); every run
passed. Speedrun's iOS row is with the settle fix that came out of this benchmark (an endless
animation's pause, see DEVELOPMENT.md): 12.0 s before it (12.29, 12.01, 11.31).

| Tool | Android emulator | iOS simulator |
|---|---|---|
| **Speedrun** | **4.2 s** (4.27, 4.15, 4.23), 11 calls, 6,247 characters (~1,560 tokens) | **9.4 s** (9.32, 9.39, 10.62), 11 calls, 4,900 characters (~1,230 tokens) |
| agent-device | 9.1 s (9.52, 9.12, 9.13), 10 calls, 8,953 characters (~2,240 tokens) | 14.0 s (14.39, 14.01, 13.94), 11 calls, 6,471 characters (~1,620 tokens) |
| Argent | 11.7 s (11.71, 11.56, 11.65), 21 calls, 14,538 characters (~3,630 tokens) | 12.2 s (12.46, 11.24, 12.15), 21 calls, 10,586 characters (~2,650 tokens) |

The largest single answer an agent read: Speedrun 1,283 characters, agent-device 2,643,
Argent 4,595 (a `describe` of the shop's results).

What the numbers leave out:

- **Argent's MCP server** attaches a screenshot and the screen's element tree after each
  action, which an agent then reads too; from its command line, used here, it does not.
- **Calls by MCP** skip each command line's start-up (Node for agent-device and Argent, under
  0.15 s a call here).
- Speedrun taps the search field and types in two calls; agent-device's `fill` does both in
  one. `speedrun do` also takes several commands at once.
- On iOS, agent-device's `open` returned before the app had drawn its first screen, so the
  script waits for the onboarding's Skip button (as an agent seeing an empty screen would);
  and Argent's iOS `describe` gives no id for some elements (Skip), so its taps fall back to
  the element's label.

## Running it

```sh
../app/bench.sh install android     # or ios: Speedrun Bench, prebuilt, installed
npm install                         # agent-device and Argent, the versions above
python3 bench.py android            # or ios; tools: speedrun agent-device argent
```

It takes the first adb device or the booted simulator (`DEVICE=<id>` picks one), resets the
app before each run, and stops each tool's background service before the next tool (one UI
automation client at a time). Argent's usage statistics are off (`DO_NOT_TRACK=1`). Each
run's calls, with their time and output size, are in `results/`. Shut the iOS simulator down
for Android numbers. On Android, agent-device installs a helper keyboard app
(`com.callstack.agentdevice.imehelper`), and it leaves a background daemon running.
