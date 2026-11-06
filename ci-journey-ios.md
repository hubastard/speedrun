# Journey, iOS, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions macos-26 runner (3 vCPUs), iPhone 17 Pro simulator (iOS 26.5)). ▲/▼: at least 15% slower/faster than the push before.

| Step | e60b138<br>11-06 17:20 | 180901f<br>11-06 17:13 | cd3c7d0<br>11-06 16:10 | 69c1d08<br>11-06 01:48 | 5b64fc4<br>11-05 14:52 |
|---|---:|---:|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" with clear state and clear keychain | 4.0 s ▼ −50% | 8.0 s ▲ +114% | 3.7 s ▼ −39% | 6.2 s ▲ +36% | 4.5 s |
| 2. Tap on id: onboarding-skip | 4.5 s ▲ +34% | 3.4 s | 2.9 s | 3.3 s | 3.9 s |
| 3. Assert that id: next, disabled is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 4. Tap on id: phone-input | 0.7 s | 0.8 s | 0.5 s | 0.9 s | 0.7 s |
| 5. Input text 5550101234 | 0.6 s | 0.7 s | 0.6 s | 0.6 s | 0.7 s |
| 6. Assert that "\(555\) 010-1234" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 7. Assert that id: next, enabled is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 8. Erase 4 characters | 0.3 s | 0.4 s | 0.3 s | 0.5 s | 0.4 s |
| 9. Assert that "\(555\) 010" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 10. Input text 1234 | 0.5 s | 0.6 s | 0.5 s | 0.6 s | 0.5 s |
| 11. Tap on id: next | 0.4 s | 0.4 s | 0.3 s | 0.4 s | 0.4 s |
| 12. Assert that "Sent to \(555\) 010-1234" is visible | 0.9 s | 0.9 s | 0.8 s | 0.9 s | 1.0 s |
| 13. Tap on id: code-input | 0.4 s | 0.7 s | 0.3 s | 0.5 s | 0.6 s |
| 14. Input text 111111 | 0.8 s | 0.8 s | 0.6 s | 0.7 s | 0.8 s |
| 15. Assert that "Wrong code, try again" is visible | 0.7 s | 0.7 s | 0.8 s | 0.8 s | 0.7 s |
| 16. Tap on id: code-input | 0.4 s | 0.7 s | 0.4 s | 0.4 s | 0.7 s |
| 17. Input text 123456 | 2.5 s ▲ +202% | 0.8 s | 0.7 s | 0.8 s | 0.8 s |
| 18. Assert that id: tab-home|notify-title is visible | 1.5 s | 1.6 s | 1.4 s | 1.6 s | 1.5 s |
| 19. Run flow when id: notify-title is visible | 8.1 s | 8.3 s | 7.9 s | 8.4 s | 8.1 s |
| 20. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| **Total** | 44.5 s | 51.8 s ▲ +50% | 34.5 s ▼ −25% | 45.7 s | 44.0 s |
