# Speedrun's CI, push by push

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

The journey and the web flows as Speedrun's CI ran them after each push to `main` (the `Journey` workflow), on GitHub's runners: their times vary more from run to run than a local machine's. ▲/▼: at least 15% slower/faster than the median of the 5 runs before. Each benchmark's page has its flows' or steps' times.

| Commit | Date | Journey, Android | Journey, iOS | Speedrun's web flows, Chrome | Speedrun's web flows, Firefox | Real World App, Chrome | Real World App, Firefox |
|---|---|---|---|---|---|---|---|
| [`d432e3a`](https://github.com/hubastard/speedrun/commit/d432e3ac3c779c76ed55566d1d88f196f87c9c1e) Bench: the READMEs take v0.4.12's numbers | 2026-11-11 13:41 | 64.6 s ✗ 0/1 | 50.6 s | 3.22 s | 3.94 s | 6.29 s | 9.75 s |
| [`751d47b`](https://github.com/hubastard/speedrun/commit/751d47b5af6227fb93e56c3e962a815f9a9f1109) Docs: the typing notes describe what Gboard did without quot | 2026-11-11 13:36 | 43.4 s ▼ −18% | 52.3 s ▲ +26% | 3.09 s | 3.62 s | 4.73 s ▼ −27% | 6.74 s ▼ −31% |
| [`8dac6e3`](https://github.com/hubastard/speedrun/commit/8dac6e353b9f72ac00641e2b7c002acbe7b6dc46) Android: reads keep their cache past a Compose status bar; w | 2026-11-11 13:15 | 57.0 s | 47.9 s ▲ +16% | 3.11 s | 3.78 s | 5.48 s ▼ −18% | 7.27 s ▼ −26% |
| [`7eb34e0`](https://github.com/hubastard/speedrun/commit/7eb34e0e50ae6cc7716c8e68a016b5c7573e3257) Bench: Compose Bench's README takes v0.4.11's numbers | 2026-11-09 23:31 | 55.3 s | 46.8 s | 3.08 s | 3.86 s | 5.85 s | 9.83 s |
| [`04f6bf7`](https://github.com/hubastard/speedrun/commit/04f6bf7b35bf63afddd3793f9d613b53a267cbe4) Android: typing is checked and what the field missed typed a | 2026-11-09 23:13 | 52.5 s | 38.3 s | 3.14 s | 3.94 s | 6.65 s | 10.21 s |
| [`716c01d`](https://github.com/hubastard/speedrun/commit/716c01d335071c10213faafa8b903bcff5e7b0c8) Bench: Compose Bench's README takes v0.4.10's numbers | 2026-11-07 11:15 | 53.1 s | 41.5 s | 3.08 s | 3.88 s | 6.44 s | 9.41 s |
| [`cf09c14`](https://github.com/hubastard/speedrun/commit/cf09c145044dd6013f6a2a8da5ca9e1c388d585a) Android: no loading overlay in a list, a second tap on a win | 2026-11-07 11:14 | 45.8 s ▼ −18% | 35.2 s ▼ −21% | 3.14 s | 4.24 s | 7.25 s ▲ +33% | 10.11 s ▲ +25% |
| [`1ac66b9`](https://github.com/hubastard/speedrun/commit/1ac66b98b36de4d2bc9f095be451a4646a7022ff) Android: typing into a field that restarts input on each key | 2026-11-06 19:37 | 60.6 s | 48.6 s | 3.11 s | 3.89 s | 7.24 s ▲ +32% | 9.14 s |
| [`04de370`](https://github.com/hubastard/speedrun/commit/04de3701abaeea69afdd491e78acdbd2031cdc0d) Bench: Compose Bench's README takes v0.4.9's numbers | 2026-11-06 19:37 | 41.2 s ▼ −26% | 43.3 s | 3.06 s | 3.53 s | 5.08 s | 6.74 s ▼ −15% |
| [`9c77858`](https://github.com/hubastard/speedrun/commit/9c7785874c0fe4601d5c6dad560c1f1cc5802be8) Bench: three flows fit a shorter screen (keyboard over a lin | 2026-11-06 17:56 | 56.2 s | 45.5 s | 3.07 s | 3.95 s | 6.07 s | 9.21 s ▲ +16% |
| [`91bae0e`](https://github.com/hubastard/speedrun/commit/91bae0ed2fd630e5b18e0e32c227544d462b0fa1) Bench: Compose Bench's README takes its first numbers, for v | 2026-11-06 17:29 | 46.4 s ▼ −16% | 40.5 s | 3.15 s | 3.74 s | 5.45 s | 8.06 s |
| [`e60b138`](https://github.com/hubastard/speedrun/commit/e60b138c285948eb3cfcb683487ff2819e231881) Android: Compose content in a bottom sheet's or a dialog's w | 2026-11-06 17:19 | 55.7 s | 44.5 s | 3.14 s | 3.80 s | 5.47 s | 7.97 s |
| [`180901f`](https://github.com/hubastard/speedrun/commit/180901ffc0ff39490b0262d4bba292242988aa58) Android: typed keys wait until the keyboard app has started  | 2026-11-06 17:11 | 58.1 s ▲ +20% | 51.8 s ▲ +18% | 3.08 s | 3.72 s | 5.60 s | 7.91 s |
| [`cd3c7d0`](https://github.com/hubastard/speedrun/commit/cd3c7d0b9dda8a00ec92d992df07560bc1afb096) Bench: Compose Bench, a plain Jetpack Compose app and its 4  | 2026-11-06 16:10 | 36.9 s ✗ 0/1 | 34.5 s ▼ −23% | 3.08 s | 3.80 s | 4.92 s | 7.35 s ▼ −16% |
| [`69c1d08`](https://github.com/hubastard/speedrun/commit/69c1d08e1046eb742177c216747ad9a357d0cd2f) Android: Backspace and eraseText go through the focused fiel | 2026-11-06 01:46 | 54.1 s ▲ +26% | 45.7 s | 3.10 s | 3.90 s | 5.53 s | 8.80 s |
| [`5b64fc4`](https://github.com/hubastard/speedrun/commit/5b64fc463c52bd884722cf8bf471e2e80486a642) openLink settles on the link's screen; Android: an element's | 2026-11-05 14:49 | 42.9 s | 44.0 s | 3.17 s | 3.86 s | 5.92 s | 8.73 s |

- [Journey, Android](ci-journey-android.md)
- [Journey, iOS](ci-journey-ios.md)
- [Speedrun's web flows, Chrome](ci-web-site-chrome.md)
- [Speedrun's web flows, Firefox](ci-web-site-firefox.md)
- [Real World App, Chrome](ci-web-rwa-chrome.md)
- [Real World App, Firefox](ci-web-rwa-firefox.md)
