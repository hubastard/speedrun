# Journey, Android, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions ubuntu-24.04 runner (4 vCPUs), API 35 emulator (pixel_7, 4 cores, 4 GB)). ▲/▼: at least 15% slower/faster than the push before.

| Step | d761c69<br>11-28 03:36 | 84bf362<br>11-27 19:10 | 38da57c<br>11-27 16:37 | 19bcdb7<br>11-12 22:38 | 00c3b3e<br>11-12 22:15 | a171959<br>11-11 14:40 | 91c0d78<br>11-11 14:24 | d432e3a<br>11-11 13:41 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" | 1.1 s | 0.6 s | 0.5 s | 0.9 s | 0.8 s | 0.7 s | 0.6 s | 0.8 s |
| 2. Tap on id: onboarding-skip | 4.6 s ▼ −23% | 6.0 s ▲ +41% | 4.3 s ▼ −35% | 6.6 s | 5.9 s ▲ +30% | 4.6 s | 4.0 s ▼ −42% | 6.9 s |
| 3. Tap on id: phone-input | 1.0 s | 0.7 s | 0.9 s | 1.4 s | 1.0 s | 0.4 s | 1.1 s | 0.5 s |
| 4. Input text 5550101234 | 2.3 s | 2.7 s | 3.0 s | 2.7 s | 3.1 s | 2.9 s | 2.3 s ▼ −33% | 3.4 s |
| 5. Tap on id: next | 2.5 s ▲ +219% | 0.8 s | 0.7 s ▼ −74% | 2.6 s ▲ +180% | 0.9 s | 1.2 s | 0.9 s ▼ −71% | 3.3 s |
| 6. Tap on id: code-input | 0.9 s ▼ −64% | 2.5 s | 2.7 s ▲ +142% | 1.1 s ▼ −59% | 2.7 s | 2.7 s ▲ +88% | 1.4 s | 0.9 s |
| 7. Input text 123456 | 1.6 s | 1.1 s | 1.3 s | 1.6 s | 1.3 s | 1.1 s | 1.2 s | 1.3 s |
| 8. Tap on id: notify-later | 3.3 s | 3.1 s | 4.0 s | 3.3 s ▼ −24% | 4.4 s ▲ +48% | 3.0 s | 2.5 s ▼ −42% | 4.3 s |
| 9. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 10. Tap on id: tab-shop | 0.8 s | 1.3 s | 0.9 s | 0.7 s | 0.8 s | 1.3 s | 0.4 s | 0.8 s |
| 11. Tap on id: search-input | 0.4 s | 0.3 s | 0.2 s | 0.2 s | 0.3 s | 0.1 s | 0.2 s | 0.2 s |
| 12. Input text sneaker | 2.2 s | 2.2 s | 2.8 s | 2.4 s ▼ −36% | 3.7 s ▲ +70% | 2.2 s | 2.0 s | 2.3 s |
| 13. Press Enter key | 1.0 s | 1.5 s | 1.0 s | 1.3 s | 1.0 s | 0.5 s | 0.9 s | 1.0 s |
| 14. Assert that "6 products" is visible | 0.0 s | 0.0 s | 0.0 s | 0.1 s | 0.0 s | 0.5 s | 0.0 s | 0.0 s |
| 15. Tap on "City Sneaker" | 0.2 s | 0.2 s ▼ −87% | 1.4 s | 1.4 s ▲ +1032% | 0.1 s | 0.1 s ▼ −89% | 1.2 s ▲ +818% | 0.1 s |
| 16. Tap on id: size-M | 1.4 s ▼ −56% | 3.3 s ▲ +299% | 0.8 s | 0.9 s ▼ −60% | 2.4 s | 2.3 s ▲ +460% | 0.4 s ▼ −76% | 1.7 s |
| 17. Tap on id: color-Blue | 0.7 s | 1.0 s | 0.2 s | 0.5 s | 0.6 s | 0.2 s | 0.8 s | 0.6 s |
| 18. Tap on id: qty-plus | 0.7 s | 0.1 s | 0.5 s | 0.4 s | 0.4 s | 0.4 s | 0.9 s | 0.6 s |
| 19. Assert that "Qty 2" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 20. Tap on id: qty-plus | 0.1 s ▼ −90% | 1.2 s | 0.3 s | 0.1 s | 0.5 s | 0.4 s | 0.3 s | 0.1 s |
| 21. Assert that "Qty 3" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 22. Tap on id: add-to-cart | 0.5 s | 0.8 s | 0.3 s | 0.4 s | 0.8 s | 0.5 s | 0.7 s | 0.3 s |
| 23. Assert that "Cart \(3\)" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 24. Tap on id: go-to-cart | 1.0 s | 1.2 s | 1.0 s | 1.3 s | 1.2 s | 1.3 s | 0.8 s | 0.9 s |
| 25. Assert that "Size M · Blue" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 26. Tap on id: header-back | 1.1 s | 1.4 s | 1.3 s | 1.1 s | 1.3 s ▼ −45% | 2.4 s ▲ +144% | 1.0 s | 1.3 s |
| 27. Tap on id: header-back | 0.8 s | 1.2 s | 1.1 s | 1.1 s | 1.3 s | 1.1 s | 1.1 s | 1.0 s |
| 28. Tap on id: tab-profile | 0.3 s | 0.6 s | 0.4 s | 0.4 s | 0.8 s | 0.3 s | 0.4 s ▼ −85% | 2.4 s |
| 29. Tap on id: security | 1.1 s | 1.2 s | 1.1 s | 1.0 s | 1.5 s | 1.1 s | 1.2 s | 1.3 s |
| 30. Tap on id: key-1 | 1.3 s | 1.3 s | 1.7 s | 1.6 s | 1.2 s | 1.7 s | 1.2 s | 1.6 s |
| 31. Tap on id: key-2 | 0.1 s | 0.4 s | 0.3 s | 0.2 s | 0.3 s | 0.1 s | 0.2 s | 0.4 s |
| 32. Tap on id: key-3 | 0.1 s | 0.4 s | 0.3 s | 0.9 s | 0.1 s | 0.3 s | 0.2 s | 0.4 s |
| 33. Tap on id: key-4 | 0.2 s | 0.1 s | 0.4 s | 0.3 s | 0.5 s | 0.3 s | 0.2 s | 0.1 s |
| 34. Assert that "Confirm your PIN" is visible | 0.4 s | 0.6 s | 0.3 s | 0.3 s | 0.0 s | 0.3 s | 0.3 s | 0.6 s |
| 35. Tap on id: key-1 | 0.1 s | 0.2 s | 0.3 s | 0.2 s | 0.2 s | 0.2 s | 0.2 s | 0.3 s |
| 36. Tap on id: key-2 | 0.1 s | 0.3 s | 0.3 s | 0.2 s | 0.5 s | 0.3 s | 0.2 s | 0.5 s |
| 37. Tap on id: key-3 | 0.2 s | 0.3 s | 0.2 s | 0.4 s | 0.6 s | 0.1 s | 0.2 s | 0.2 s |
| 38. Tap on id: key-4 | 0.2 s ▼ −88% | 1.4 s ▲ +721% | 0.2 s | 0.2 s ▼ −88% | 1.9 s ▲ +553% | 0.3 s | 0.2 s ▼ −84% | 1.4 s |
| 39. Assert that "PIN set" is visible | 1.1 s | 0.0 s ▼ −100% | 1.2 s | 1.2 s | 0.0 s ▼ −100% | 1.0 s | 1.0 s | 0.0 s |
| 40. Tap on id: tab-lab | 0.4 s | 0.6 s | 0.5 s | 0.9 s | 1.1 s | 0.3 s | 0.3 s | 0.7 s |
| 41. Tap on id: lab-drag | 1.1 s | 1.2 s | 1.1 s | 1.2 s | 1.3 s | 1.0 s | 1.0 s ▼ −82% | 5.7 s |
| 42. Tap on id: open-long-list | 2.7 s | 3.0 s | 3.4 s | 3.4 s | 3.3 s | 2.7 s | 2.5 s ▼ −85% | 17.0 s ✗ |
| 43. Scrolling DOWN until "Row 60" is visible with speed 40, visibility percentage 100%, timeout 60000 ms, with centering disabled | 9.4 s ▲ +26% | 7.4 s | 8.6 s | 9.1 s | 8.9 s ▲ +183% | 3.1 s ▼ −26% | 4.2 s | – |
| 44. Tap on "Row 60" | 0.2 s | 0.2 s | 0.2 s | 0.6 s | 0.4 s | 0.2 s | 0.2 s | – |
| 45. Assert that "Picked row 60" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | – |
| **Total** | 47.2 s | 52.6 s | 49.5 s | 54.2 s | 57.2 s ▲ +32% | 43.3 s | 38.6 s ▼ −40% | 64.6 s ✗ |
