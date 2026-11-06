# Journey, Android, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions ubuntu-24.04 runner (4 vCPUs), API 35 emulator (pixel_7, 4 cores, 4 GB)). ▲/▼: at least 15% slower/faster than the push before.

| Step | 69c1d08<br>11-06 01:46 | 5b64fc4<br>11-05 14:49 |
|---|---:|---:|
| 1. Launch app "dev.speedrun.bench" | 0.6 s | 1.3 s |
| 2. Tap on id: onboarding-skip | 5.2 s | 4.4 s |
| 3. Tap on id: phone-input | 1.5 s ▲ +231% | 0.5 s |
| 4. Input text 5550101234 | 2.7 s | 2.6 s |
| 5. Tap on id: next | 1.1 s | 0.9 s |
| 6. Tap on id: code-input | 2.5 s | 2.9 s |
| 7. Input text 123456 | 1.6 s ▲ +206% | 0.5 s |
| 8. Tap on id: notify-later | 4.3 s | 4.4 s |
| 9. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s |
| 10. Tap on id: tab-shop | 0.9 s | 0.5 s |
| 11. Tap on id: search-input | 0.1 s | 0.3 s |
| 12. Input text sneaker | 2.7 s | 1.8 s |
| 13. Press Enter key | 1.0 s | 1.0 s |
| 14. Assert that "6 products" is visible | 0.1 s | 0.0 s |
| 15. Tap on "City Sneaker" | 0.2 s ▼ −89% | 1.3 s |
| 16. Tap on id: size-M | 1.3 s | 1.0 s |
| 17. Tap on id: color-Blue | 1.1 s | 0.6 s |
| 18. Tap on id: qty-plus | 0.9 s | 0.1 s |
| 19. Assert that "Qty 2" is visible | 0.0 s | 0.0 s |
| 20. Tap on id: qty-plus | 0.4 s | 0.3 s |
| 21. Assert that "Qty 3" is visible | 0.0 s | 0.0 s |
| 22. Tap on id: add-to-cart | 0.4 s | 0.4 s |
| 23. Assert that "Cart \(3\)" is visible | 0.0 s | 0.0 s |
| 24. Tap on id: go-to-cart | 1.2 s | 1.3 s |
| 25. Assert that "Size M · Blue" is visible | 0.0 s | 0.0 s |
| 26. Tap on id: header-back | 1.1 s | 1.2 s |
| 27. Tap on id: header-back | 1.3 s | 1.1 s |
| 28. Tap on id: tab-profile | 0.4 s | 0.5 s |
| 29. Tap on id: security | 1.2 s | 0.9 s |
| 30. Tap on id: key-1 | 1.4 s | 1.5 s |
| 31. Tap on id: key-2 | 0.4 s | 0.2 s |
| 32. Tap on id: key-3 | 0.4 s | 0.2 s |
| 33. Tap on id: key-4 | 0.2 s | 0.3 s |
| 34. Assert that "Confirm your PIN" is visible | 0.4 s | 0.3 s |
| 35. Tap on id: key-1 | 0.2 s | 0.1 s |
| 36. Tap on id: key-2 | 0.3 s | 0.1 s |
| 37. Tap on id: key-3 | 0.1 s | 0.1 s |
| 38. Tap on id: key-4 | 0.3 s | 0.1 s |
| 39. Assert that "PIN set" is visible | 1.3 s | 1.0 s |
| 40. Tap on id: tab-lab | 1.0 s | 0.3 s |
| 41. Tap on id: lab-drag | 1.3 s | 0.8 s |
| 42. Tap on id: open-long-list | 3.0 s | 2.2 s |
| 43. Scrolling DOWN until "Row 60" is visible with speed 40, visibility percentage 100%, timeout 60000 ms, with centering disabled | 9.4 s ▲ +68% | 5.6 s |
| 44. Tap on "Row 60" | 0.7 s | 0.3 s |
| 45. Assert that "Picked row 60" is visible | 0.0 s | 0.0 s |
| **Total** | 54.1 s ▲ +26% | 42.9 s |
