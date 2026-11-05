# Speedrun's CI, push by push

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

The journey and the web flows as Speedrun's CI ran them after each push to `main` (the `Journey` workflow), on GitHub's runners: their times vary more from run to run than a local machine's. ▲/▼: at least 15% slower/faster than the median of the 5 runs before. Each benchmark's page has its flows' or steps' times.

| Commit | Date | Journey, Android | Journey, iOS | Speedrun's web flows, Chrome | Speedrun's web flows, Firefox | Real World App, Chrome | Real World App, Firefox |
|---|---|---|---|---|---|---|---|
| [`5b64fc4`](https://github.com/hubastard/speedrun/commit/5b64fc463c52bd884722cf8bf471e2e80486a642) openLink settles on the link's screen; Android: an element's | 2026-11-05 14:49 | 42.9 s | 44.0 s | 3.17 s | 3.86 s | 5.92 s | 8.73 s |

- [Journey, Android](ci-journey-android.md)
- [Journey, iOS](ci-journey-ios.md)
- [Speedrun's web flows, Chrome](ci-web-site-chrome.md)
- [Speedrun's web flows, Firefox](ci-web-site-firefox.md)
- [Real World App, Chrome](ci-web-rwa-chrome.md)
- [Real World App, Firefox](ci-web-rwa-firefox.md)
