# Journey, Android, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions ubuntu-24.04 runner (4 vCPUs), API 35 emulator (pixel_7, 4 cores, 4 GB)). ▲/▼: at least 15% slower/faster than the push before.

| Step | cd3c7d0<br>11-06 16:10 | 69c1d08<br>11-06 01:46 | 5b64fc4<br>11-05 14:49 |
|---|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" | 0.8 s | 0.6 s | 1.3 s |
| 2. Tap on id: onboarding-skip | 3.8 s ▼ −27% | 5.2 s | 4.4 s |
| 3. Tap on id: phone-input | 0.3 s ▼ −78% | 1.5 s ▲ +231% | 0.5 s |
| 4. Input text 5550101234 | 2.7 s | 2.7 s | 2.6 s |
| 5. Tap on id: next | 0.7 s | 1.1 s | 0.9 s |
| 6. Tap on id: code-input | 2.5 s | 2.5 s | 2.9 s |
| 7. Input text 123456 | 0.7 s | 1.6 s ▲ +206% | 0.5 s |
| 8. Tap on id: notify-later | 4.7 s | 4.3 s | 4.4 s |
| 9. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s |
| 10. Tap on id: tab-shop | 1.0 s | 0.9 s | 0.5 s |
| 11. Tap on id: search-input | 0.1 s | 0.1 s | 0.3 s |
| 12. Input text sneaker | 1.9 s | 2.7 s | 1.8 s |
| 13. Press Enter key | 0.5 s | 1.0 s | 1.0 s |
| 14. Assert that "6 products" is visible | 17.0 s ✗ | 0.1 s | 0.0 s |
| **Total** | 36.9 s ✗ | 54.1 s ▲ +26% | 42.9 s |
