# iOS agent (simulators)

An XCUITest runner whose single test serves the Android agent's protocol (same ops, same
responses) over TCP on `127.0.0.1:7778`: a simulator shares the Mac's loopback, so there is no
forwarding. `./build.sh` builds it into `agent/ios/build`; `./speedrun --platform ios` starts it
with `xcodebuild test-without-building` (3–6 s: ~2 s of xcodebuild itself, then installing and
launching the runner and XCTest's session handshake). It then stays up for the next run, in
its own session: a run that finds it serving this build on the chosen simulator (op INFO)
starts in ~0.2 s. It stops on QUIT (`./speedrun --stop-agent`) or after SPEEDRUN_IDLE_S
seconds without a client (600). Only an XCTest runner may drive other apps on iOS.

- `SpeedrunAgentUITests/` — `Agent.swift` (server, protocol), `Screen.swift` (the hierarchy,
  with the iOS attribute mapping flows match against), `Input.swift` (taps, swipes, typing, keys),
  `Settle.swift`, `Private.swift` (private XCTest API, reached through the Objective-C runtime
  and checked before each use: a missing method is an error naming it, not a crash) and
  `Spike.swift` (measurement-only ops).
- `spike/` — the Python client and the measurement scripts (`measure.py`, `measure_followup.py`
  for the building blocks, `typing.py` for typing rates, `swipe.py` for swipe shapes).

How it does each part:

- **Hierarchy**: the foreground app (found through XCTest's accessibility client and
  testmanagerd, the last one checked first), then SpringBoard's status bars, re-read every 5 s
  (they cost as much as the app and change with the clock). A read right after SETTLE is
  served from settle's last snapshot (no action since, under 1 s old). ~70–90 ms otherwise.
- **Input**: events synthesized through testmanagerd (a 20 ms tap, see Input.tapHoldMs; for `swipe` and `scroll`
  a swipe that glides over its whole duration, see below; for `scrollUntilVisible` a drag that
  does not fling, `Input.drag`). Text: the first character alone, then, once the focused field
  shows it (at most 0.5 s), the rest at 100 characters per second. Deleting from an empty
  field does not wait.
- **Settle**: XCTest's quiescence (event loop, then animations, idle), then the screen's
  signature: it must differ from what the flow last read (quiescence once reported idle
  before a push had begun), and two signatures in a row must agree. "No change" after
  `no_change_ms`, as on Android. After a swipe, quiescence leaves out animations (the content
  stops at lift-up; the scroll indicator's fade does not matter). Typing and drags return
  before testmanagerd confirms their events: a settle concludes only once it has. The
  signature leaves out the keyboard's assistant bar (`SystemInputAssistantView`, the typing
  predictions), which updates on its own a few hundred ms after each key.

To time the building blocks by hand:

```
TEST_RUNNER_SPEEDRUN_PORT=7778 xcodebuild test-without-building \
  -xctestrun agent/ios/build/Build/Products/*.xctestrun -destination 'id=<udid>' &
python3 agent/ios/spike/measure.py        # Settings open on its home screen
```

## Spike results (2026-10-23, iPhone 17 Pro simulator, iOS 26.2, Xcode 27.0, a loaded Mac)

Building blocks through the spike runner:

| block | time |
|---|---|
| runner start (`xcodebuild test-without-building` to first answered PING) | 3.7 s |
| round trip | 0.1 ms |
| full snapshot of Settings (168 nodes) | 70–90 ms (`dictionaryRepresentation` 70, walking `children` 90) |
| first element by label (`firstMatch`) | 53 ms found, 81 ms absent |
| screenshot (PNG) | 105 ms |
| tap (synthesized event, 100 ms hold) until delivered | 334 ms (249 ms with a 20 ms hold) |
| screen starts changing | ~300 ms after the tap begins |
| XCTest quiescence (event loop + animations idle) after a push / pop | 1.2 s / 0.74 s after the tap |
| push content actually done (PNG diffs) | ~1.0 s after the tap |
| typing 14 characters at 30 chars/s | 648 ms |
| erasing 25 characters at 30 chars/s | 1.0 s |

What it means:

- A tap + quiescence takes ~1.0–1.3 s, mostly the push animation itself (~1 s), which
  nothing on iOS turns off (but see `UIAnimationDragCoefficient` below).
- XCTest's quiescence is a usable settle signal (it fires ~0.2 s after the content stops
  moving, ignoring the scroll indicator's fade), but in one push of five it fired ~0.44 s
  after the tap, before the transition began: settle needs a guard, as on Android.
- Lookups: `firstMatch` (53 ms) vs a full snapshot (70–90 ms) is a smaller gap than FIND vs
  TREE on Android; a trimmed snapshot (`XCAXClient_iOS requestSnapshotForElement:attributes:
  parameters:`, present in Xcode 27) is still to be measured.
- Typing faster than 30 chars/s lost characters in some runs (60: 1 of 3 correct, 100: 2 of
  3, 150–300: 3 of 3); unexplained so far, so 30 chars/s stays until it is understood.
- Writing `ReduceMotionEnabled` to the simulator's defaults did not change push timing.
- Later (2026-10-24): UIKit's `UIAnimationDragCoefficient()` returns its internal preference
  `UIAnimationDragCoefficient` (when set and above 0), else 10 while the simulator's Slow
  Animations is on (Darwin notification state `com.apple.UIKit.SimulatorSlowMotionAnimationState`),
  else 1. Internal preferences are read only on internal builds or with the feature flag
  `UIKit/UIPreferences` on, which `FEATUREFLAGS_ENABLED=UIKit/UIPreferences` in the app's
  environment does (flags separated by colons). Launched with that and
  `-UIAnimationDragCoefficient 0.1`, Settings' General push went from ~1.5 to ~0.7 s per tap
  command and back from ~1.0 to ~0.55 s; 0.01 was no faster. Speedrun's `launchApp` does this
  (host/system.odin). The global defaults domain and `com.apple.UIKit` are not read without
  the flag.
- Later (2026-10-25), swipes, traced with `spike/swipe.py` (a row's position polled during
  and after a drag sent without waiting):
  - testmanagerd plays a move (`moveToPoint:atOffset:`) from its offset until the next event.
    The flow format's swipe (down, move at 100 ms, up at 100 ms + duration) is therefore a
    glide over the whole duration that lifts still moving, never a hold. scrollUntilVisible's 601 ms
    over 350 points moved a UIKit list ~540 points and a React Native one ~530, both still
    only ~2.6 s after the touch began. (The earlier "holding 100 ms scrolled UIKit Settings
    as far" was Settings' list ending.)
  - A touch at rest sends no events, so UIKit takes the velocity of the last moves: a fast
    move, a 100 ms rest and a lift flings as hard as no rest. Extra moves to the same point
    during the rest made it fling to the list's end; one at 16 ms intervals also shortened
    the whole gesture. XCTest's `press(forDuration:thenDragTo:withVelocity:
    thenHoldForDuration:)` builds the same `moveToPoint` path (the hold becomes glide), and
    waits for the app to go idle before and after.
  - Explicit move events (`XCPointerEvent moveEventWithStartPoint:destination:offset:
    duration:`, added with `_addPointerEvent:`) do take their duration. Constant speed: no
    fling at 250 and 350 points/s (UIKit), at 250 (React Native); 500 flings both. Fast,
    then a slow tail: no fling with a 200 ms tail at 200 points/s on both, flings with a
    125 ms tail (React Native) or at 250 points/s (UIKit, once in three). At full speed
    from the start the list follows ~100 points late; 12 points in 40 ms first fixes most
    of it (still 160-340 of 350 points between runs).
  - `liftUpAtOffset:` lifts where the last `moveToPoint` went, so after explicit moves it
    lifted at the start point: the lift comes from a path made at the end point.
  - testmanagerd confirms a synthesized event ~250 ms after its last event, while a drag's
    content is still ~50 ms after it: the drag returns 100 ms after the lift, and the next
    event or settle waits for the confirmation. scrollUntilVisible in Settings: 2.7 -> 2.4 s
    down, 2.2 -> 1.4 s up; in the React Native demo 6.1 -> 3.9, 6.2 -> 3.8, 7.0 -> 5.4 s.
- Later (2026-10-25), typing: TYPE spent ~125 ms finding the focused field, ~215 ms on the
  first character (most of it testmanagerd's confirmation, ~200 ms after the key), ~330 ms
  until the field showed it (Settings busy with its search) and ~330 ms on the 13 others
  (130 ms of keys, then the confirmation). Keys are now sent without waiting and the settle
  checks the screen meanwhile, concluding once they are confirmed. Settings' search did not
  gain (1.41 -> 1.36 s for TYPE + SETTLE: it works ~65 ms per key); React Native's field went
  from 1.8 to 1.2 s and eraseText from ~0.86 to ~0.65 s in Settings. The keyboard's
  suggestions then held up whichever settle came next (they change ~200-500 ms after the
  last key): left out of the signature. A single key (pressKey) still waits: sent without
  waiting, the settle's polling during the keyboard's dismissal made Enter ~100 ms slower.
- Start-up: 3.7 s, before keeping the runner alive between runs.

The typing losses above came from `_XCT_sendString`; typing through synthesized key events
(what the agent does) lost no character at up to 300 characters per second, without waiting
after the first one (`spike/typing.py`, 5 tries each).
