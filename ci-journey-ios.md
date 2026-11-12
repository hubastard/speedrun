# Journey, iOS, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions macos-26 runner (3 vCPUs), iPhone 17 Pro simulator (iOS 26.5)). ▲/▼: at least 15% slower/faster than the push before.

| Step | 19bcdb7<br>11-12 22:39 | 00c3b3e<br>11-12 22:17 | a171959<br>11-11 14:42 | 91c0d78<br>11-11 14:26 | d432e3a<br>11-11 13:45 | 751d47b<br>11-11 13:40 | 8dac6e3<br>11-11 13:17 | 7eb34e0<br>11-09 23:32 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" with clear state and clear keychain | 4.5 s ▼ −50% | 9.1 s ▲ +51% | 6.0 s | 6.2 s ▼ −18% | 7.6 s ▲ +24% | 6.1 s | 5.2 s ▼ −28% | 7.2 s |
| 2. Tap on id: onboarding-skip | 4.5 s ▲ +53% | 3.0 s ▼ −29% | 4.2 s | 3.6 s ▼ −24% | 4.7 s | 4.9 s ▲ +26% | 3.9 s | 3.7 s |
| 3. Assert that id: next, disabled is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 4. Tap on id: phone-input | 0.9 s | 1.0 s | 0.9 s | 0.9 s | 1.0 s | 1.0 s | 1.2 s | 1.0 s |
| 5. Input text 5550101234 | 0.9 s | 0.8 s | 0.7 s | 0.8 s | 0.9 s | 1.1 s | 0.6 s | 0.7 s |
| 6. Assert that "\(555\) 010-1234" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 7. Assert that id: next, enabled is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 8. Erase 4 characters | 0.4 s | 0.4 s | 0.4 s | 0.3 s | 0.4 s | 0.5 s | 0.4 s | 0.4 s |
| 9. Assert that "\(555\) 010" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 10. Input text 1234 | 0.6 s | 0.6 s | 0.6 s | 0.5 s | 0.6 s | 0.7 s | 0.6 s | 0.5 s |
| 11. Tap on id: next | 0.4 s | 0.4 s | 0.4 s | 0.4 s | 0.4 s | 0.5 s | 0.4 s | 0.4 s |
| 12. Assert that "Sent to \(555\) 010-1234" is visible | 1.0 s | 0.9 s | 1.3 s | 0.9 s | 1.1 s | 1.3 s | 1.0 s | 0.9 s |
| 13. Tap on id: code-input | 0.7 s | 0.4 s | 0.5 s | 0.4 s | 0.7 s | 0.5 s | 0.6 s | 0.8 s |
| 14. Input text 111111 | 0.8 s | 0.9 s | 0.9 s | 0.7 s | 1.2 s | 1.1 s | 0.9 s | 0.6 s |
| 15. Assert that "Wrong code, try again" is visible | 0.8 s | 0.6 s | 0.9 s | 0.8 s | 0.7 s | 0.7 s | 0.6 s | 0.8 s |
| 16. Tap on id: code-input | 0.6 s | 0.5 s | 0.6 s | 0.4 s | 0.6 s | 0.6 s | 0.6 s | 0.4 s |
| 17. Input text 123456 | 0.8 s | 0.8 s | 0.9 s | 0.6 s | 0.9 s | 1.0 s | 0.8 s | 0.6 s |
| 18. Assert that id: tab-home|notify-title is visible | 1.7 s | 1.4 s | 1.7 s | 1.6 s | 1.8 s | 1.5 s | 1.5 s | 1.6 s |
| 19. Run flow when id: notify-title is visible | 8.3 s | 8.2 s | 8.2 s | 8.1 s | 8.5 s | 8.5 s | 8.2 s | 8.1 s |
| 20. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| **Total** | 43.8 s | 41.4 s | 44.0 s | 42.9 s ▼ −15% | 50.6 s | 52.3 s | 47.9 s | 46.8 s |
