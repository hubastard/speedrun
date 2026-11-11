# Journey, iOS, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions macos-26 runner (3 vCPUs), iPhone 17 Pro simulator (iOS 26.5)). ▲/▼: at least 15% slower/faster than the push before.

| Step | 751d47b<br>11-11 13:40 | 8dac6e3<br>11-11 13:17 | 7eb34e0<br>11-09 23:32 | 04f6bf7<br>11-09 23:13 | 716c01d<br>11-07 11:17 | cf09c14<br>11-07 11:15 | 1ac66b9<br>11-06 19:39 | 04de370<br>11-06 19:38 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" with clear state and clear keychain | 6.1 s | 5.2 s ▼ −28% | 7.2 s ▲ +28% | 5.6 s | 5.7 s ▲ +25% | 4.6 s ▼ −29% | 6.4 s ▲ +93% | 3.3 s |
| 2. Tap on id: onboarding-skip | 4.9 s ▲ +26% | 3.9 s | 3.7 s ▲ +39% | 2.6 s | 3.3 s | 2.5 s ▼ −38% | 4.0 s ▲ +56% | 2.6 s |
| 3. Assert that id: next, disabled is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 4. Tap on id: phone-input | 1.0 s | 1.2 s | 1.0 s | 0.6 s | 0.7 s | 0.5 s | 0.8 s | 0.5 s |
| 5. Input text 5550101234 | 1.1 s | 0.6 s | 0.7 s | 0.6 s | 0.6 s | 0.7 s | 0.8 s | 0.7 s |
| 6. Assert that "\(555\) 010-1234" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 7. Assert that id: next, enabled is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 8. Erase 4 characters | 0.5 s | 0.4 s | 0.4 s | 0.3 s | 0.4 s | 0.3 s | 0.5 s | 0.3 s |
| 9. Assert that "\(555\) 010" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 10. Input text 1234 | 0.7 s | 0.6 s | 0.5 s | 0.5 s | 0.6 s | 0.5 s | 0.6 s | 0.5 s |
| 11. Tap on id: next | 0.5 s | 0.4 s | 0.4 s | 0.3 s | 0.4 s | 0.3 s | 0.4 s | 0.3 s |
| 12. Assert that "Sent to \(555\) 010-1234" is visible | 1.3 s | 1.0 s | 0.9 s | 0.9 s | 1.0 s | 0.8 s | 1.0 s | 0.8 s |
| 13. Tap on id: code-input | 0.5 s | 0.6 s | 0.8 s | 0.3 s | 0.6 s | 0.3 s | 0.7 s | 0.3 s |
| 14. Input text 111111 | 1.1 s | 0.9 s | 0.6 s | 0.5 s | 0.7 s | 0.6 s | 1.4 s | 0.7 s |
| 15. Assert that "Wrong code, try again" is visible | 0.7 s | 0.6 s | 0.8 s | 0.8 s | 0.7 s | 0.8 s | 0.3 s | 0.7 s |
| 16. Tap on id: code-input | 0.6 s | 0.6 s | 0.4 s | 0.4 s | 0.6 s | 0.3 s | 0.6 s | 0.3 s |
| 17. Input text 123456 | 1.0 s | 0.8 s | 0.6 s | 0.6 s | 0.7 s | 0.5 s | 1.1 s | 0.7 s |
| 18. Assert that id: tab-home|notify-title is visible | 1.5 s | 1.5 s | 1.6 s | 1.5 s | 1.7 s | 1.7 s | 1.5 s | 1.5 s |
| 19. Run flow when id: notify-title is visible | 8.5 s | 8.2 s | 8.1 s | 7.8 s | 8.7 s | 8.4 s | 8.5 s | 8.1 s |
| 20. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| **Total** | 52.3 s | 47.9 s | 46.8 s ▲ +22% | 38.3 s | 41.5 s ▲ +18% | 35.2 s ▼ −28% | 48.6 s | 43.3 s |
