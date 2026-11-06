# Journey, Android, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions ubuntu-24.04 runner (4 vCPUs), API 35 emulator (pixel_7, 4 cores, 4 GB)). ▲/▼: at least 15% slower/faster than the push before.

| Step | 1ac66b9<br>11-06 19:37 | 04de370<br>11-06 19:37 | 9c77858<br>11-06 17:56 | 91bae0e<br>11-06 17:29 | e60b138<br>11-06 17:19 | 180901f<br>11-06 17:11 | cd3c7d0<br>11-06 16:10 | 69c1d08<br>11-06 01:46 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" | 0.8 s | 0.6 s | 0.7 s | 1.1 s | 0.5 s | 0.6 s | 0.8 s | 0.6 s |
| 2. Tap on id: onboarding-skip | 6.3 s ▲ +55% | 4.0 s ▼ −26% | 5.4 s | 4.7 s ▼ −32% | 6.9 s | 6.4 s ▲ +68% | 3.8 s ▼ −27% | 5.2 s |
| 3. Tap on id: phone-input | 1.9 s ▲ +379% | 0.4 s | 1.0 s | 1.0 s | 1.4 s | 0.4 s | 0.3 s ▼ −78% | 1.5 s |
| 4. Input text 5550101234 | 2.6 s | 2.5 s ▼ −33% | 3.7 s ▲ +46% | 2.5 s | 2.9 s | 3.4 s | 2.7 s | 2.7 s |
| 5. Tap on id: next | 1.7 s | 0.7 s ▼ −77% | 3.3 s ▲ +316% | 0.8 s | 0.7 s | 0.6 s | 0.7 s | 1.1 s |
| 6. Tap on id: code-input | 3.0 s | 3.6 s ▲ +713% | 0.4 s ▼ −84% | 2.8 s | 2.6 s | 2.7 s | 2.5 s | 2.5 s |
| 7. Input text 123456 | 1.4 s | 0.7 s ▼ −86% | 5.0 s ▲ +288% | 1.3 s | 1.3 s | 1.4 s | 0.7 s | 1.6 s |
| 8. Tap on id: notify-later | 3.8 s | 2.8 s ▲ +148% | 1.1 s ▼ −72% | 4.0 s | 4.4 s | 3.4 s ▼ −27% | 4.7 s | 4.3 s |
| 9. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 10. Tap on id: tab-shop | 0.6 s | 0.5 s | 0.6 s | 0.5 s | 1.1 s | 1.3 s | 1.0 s | 0.9 s |
| 11. Tap on id: search-input | 2.0 s ▲ +1542% | 0.1 s | 1.0 s | 1.0 s | 0.2 s | 0.1 s | 0.1 s | 0.1 s |
| 12. Input text sneaker | 2.4 s | 1.8 s | 1.8 s | 1.6 s | 1.9 s | 2.8 s | 1.9 s | 2.7 s |
| 13. Press Enter key | 1.3 s | 0.4 s | 0.9 s | 1.1 s | 0.9 s | 1.3 s | 0.5 s | 1.0 s |
| 14. Assert that "6 products" is visible | 0.0 s | 0.5 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s ▼ −100% | 17.0 s ✗ | 0.1 s |
| 15. Tap on "City Sneaker" | 0.1 s | 0.1 s | 0.1 s ▼ −89% | 1.3 s | 1.2 s | 0.2 s | – | 0.2 s |
| 16. Tap on id: size-M | 1.7 s | 1.1 s ▼ −54% | 2.3 s ▲ +554% | 0.4 s | 0.2 s ▼ −90% | 1.6 s | – | 1.3 s |
| 17. Tap on id: color-Blue | 1.6 s ▲ +766% | 0.2 s | 0.6 s | 0.8 s | 0.3 s | 0.8 s | – | 1.1 s |
| 18. Tap on id: qty-plus | 0.7 s | 0.1 s | 0.3 s | 0.1 s | 0.7 s | 1.0 s | – | 0.9 s |
| 19. Assert that "Qty 2" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | – | 0.0 s |
| 20. Tap on id: qty-plus | 0.3 s | 0.1 s | 0.2 s | 0.4 s | 0.6 s | 0.6 s | – | 0.4 s |
| 21. Assert that "Qty 3" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | – | 0.0 s |
| 22. Tap on id: add-to-cart | 1.4 s | 0.7 s | 0.4 s | 0.3 s | 0.6 s ▼ −63% | 1.7 s | – | 0.4 s |
| 23. Assert that "Cart \(3\)" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | – | 0.0 s |
| 24. Tap on id: go-to-cart | 1.3 s | 1.1 s | 1.1 s | 1.0 s | 1.1 s | 1.3 s | – | 1.2 s |
| 25. Assert that "Size M · Blue" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | – | 0.0 s |
| 26. Tap on id: header-back | 1.3 s | 1.0 s | 1.3 s | 1.3 s | 1.2 s | 1.6 s | – | 1.1 s |
| 27. Tap on id: header-back | 1.3 s | 1.4 s | 1.0 s | 0.9 s | 1.5 s | 1.7 s | – | 1.3 s |
| 28. Tap on id: tab-profile | 0.4 s | 0.4 s | 0.5 s | 0.4 s | 0.6 s | 0.8 s | – | 0.4 s |
| 29. Tap on id: security | 1.3 s | 1.3 s | 1.2 s | 1.2 s | 1.5 s | 1.2 s | – | 1.2 s |
| 30. Tap on id: key-1 | 1.1 s | 1.0 s | 1.5 s | 1.2 s | 1.2 s | 1.9 s | – | 1.4 s |
| 31. Tap on id: key-2 | 0.3 s | 0.1 s | 0.3 s | 0.2 s | 0.4 s | 0.4 s | – | 0.4 s |
| 32. Tap on id: key-3 | 0.3 s | 0.2 s | 0.3 s | 0.3 s | 0.3 s | 0.4 s | – | 0.4 s |
| 33. Tap on id: key-4 | 0.2 s | 0.2 s | 0.2 s | 0.3 s | 0.6 s | 0.8 s | – | 0.2 s |
| 34. Assert that "Confirm your PIN" is visible | 0.6 s | 0.4 s | 0.6 s | 0.5 s | 0.0 s | 0.0 s | – | 0.4 s |
| 35. Tap on id: key-1 | 0.3 s | 0.1 s | 0.2 s | 0.2 s | 0.8 s | 0.2 s | – | 0.2 s |
| 36. Tap on id: key-2 | 0.2 s | 0.1 s | 0.3 s | 0.3 s | 0.4 s | 0.7 s | – | 0.3 s |
| 37. Tap on id: key-3 | 0.3 s | 0.2 s | 0.2 s | 0.2 s | 0.3 s | 0.6 s | – | 0.1 s |
| 38. Tap on id: key-4 | 1.3 s ▲ +467% | 0.2 s | 0.3 s | 0.3 s | 0.2 s | 0.2 s | – | 0.3 s |
| 39. Assert that "PIN set" is visible | 0.0 s ▼ −100% | 1.1 s | 1.1 s | 1.1 s | 1.1 s | 1.2 s | – | 1.3 s |
| 40. Tap on id: tab-lab | 0.4 s | 0.4 s | 0.6 s | 0.6 s | 0.5 s | 0.7 s | – | 1.0 s |
| 41. Tap on id: lab-drag | 2.5 s ▲ +129% | 1.1 s | 1.1 s | 1.1 s | 1.4 s | 1.2 s | – | 1.3 s |
| 42. Tap on id: open-long-list | 4.4 s ▲ +30% | 3.3 s | 3.5 s | 2.7 s | 3.4 s | 4.2 s | – | 3.0 s |
| 43. Scrolling DOWN until "Row 60" is visible with speed 40, visibility percentage 100%, timeout 60000 ms, with centering disabled | 9.3 s ▲ +47% | 6.3 s ▼ −43% | 11.0 s ▲ +71% | 6.4 s ▼ −35% | 9.9 s ▲ +19% | 8.3 s | – | 9.4 s |
| 44. Tap on "Row 60" | 0.5 s | 0.2 s | 0.8 s | 0.4 s | 0.7 s | 0.3 s | – | 0.7 s |
| 45. Assert that "Picked row 60" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | – | 0.0 s |
| **Total** | 60.6 s ▲ +47% | 41.2 s ▼ −27% | 56.2 s ▲ +21% | 46.4 s ▼ −17% | 55.7 s | 58.1 s ▲ +58% | 36.9 s ✗ | 54.1 s |
