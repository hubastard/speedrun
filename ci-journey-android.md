# Journey, Android, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each step's time, the last 8 pushes, newest first (GitHub Actions ubuntu-24.04 runner (4 vCPUs), API 35 emulator (pixel_7, 4 cores, 4 GB)). ▲/▼: at least 15% slower/faster than the push before.

| Step | 91c0d78<br>11-11 14:24 | d432e3a<br>11-11 13:41 | 751d47b<br>11-11 13:36 | 8dac6e3<br>11-11 13:15 | 7eb34e0<br>11-09 23:31 | 04f6bf7<br>11-09 23:13 | 716c01d<br>11-07 11:15 | cf09c14<br>11-07 11:14 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1. Launch app "dev.speedrun.bench" | 0.6 s | 0.8 s | 1.0 s | 0.5 s | 0.5 s | 0.7 s | 0.6 s | 0.7 s |
| 2. Tap on id: onboarding-skip | 4.0 s ▼ −42% | 6.9 s ▲ +67% | 4.1 s ▼ −37% | 6.5 s | 6.2 s ▲ +20% | 5.2 s ▼ −19% | 6.4 s | 5.5 s |
| 3. Tap on id: phone-input | 1.1 s | 0.5 s ▼ −81% | 2.5 s | 1.9 s ▲ +118% | 0.9 s | 0.8 s | 0.7 s | 0.4 s |
| 4. Input text 5550101234 | 2.3 s ▼ −33% | 3.4 s ▲ +160% | 1.3 s ▼ −54% | 2.8 s | 3.1 s | 2.8 s | 3.3 s | 2.9 s |
| 5. Tap on id: next | 0.9 s ▼ −71% | 3.3 s ▲ +221% | 1.0 s | 1.3 s | 2.1 s ▲ +111% | 1.0 s | 0.6 s | 0.7 s |
| 6. Tap on id: code-input | 1.4 s | 0.9 s ▼ −67% | 2.6 s ▼ −34% | 4.0 s ▲ +253% | 1.1 s ▼ −56% | 2.5 s | 2.7 s | 2.7 s |
| 7. Input text 123456 | 1.2 s | 1.3 s | 0.9 s | 1.1 s | 1.4 s | 1.3 s | 1.2 s | 1.3 s |
| 8. Tap on id: notify-later | 2.5 s ▼ −42% | 4.3 s ▲ +49% | 2.9 s ▼ −48% | 5.5 s ▲ +58% | 3.5 s | 3.1 s | 3.6 s | 3.4 s |
| 9. Assert that "Hi, Alex" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 10. Tap on id: tab-shop | 0.4 s | 0.8 s | 0.4 s | 1.1 s | 1.1 s | 0.8 s | 1.1 s | 0.8 s |
| 11. Tap on id: search-input | 0.2 s | 0.2 s | 0.1 s ▼ −92% | 1.8 s ▲ +1290% | 0.1 s ▼ −94% | 2.1 s ▲ +561% | 0.3 s ▼ −81% | 1.7 s |
| 12. Input text sneaker | 2.0 s | 2.3 s | 2.8 s ▲ +58% | 1.8 s | 2.3 s | 1.6 s | 2.5 s | 1.6 s |
| 13. Press Enter key | 0.9 s | 1.0 s | 0.4 s | 1.2 s | 1.0 s | 1.2 s ▲ +769% | 0.1 s | 1.0 s |
| 14. Assert that "6 products" is visible | 0.0 s | 0.0 s | 0.6 s | 0.0 s | 0.0 s | 0.0 s | 0.8 s | 0.0 s |
| 15. Tap on "City Sneaker" | 1.2 s ▲ +818% | 0.1 s ▼ −90% | 1.3 s | 1.6 s | 1.7 s ▲ +1170% | 0.1 s ▼ −90% | 1.3 s | 1.3 s |
| 16. Tap on id: size-M | 0.4 s ▼ −76% | 1.7 s | 1.1 s | 0.8 s | 0.7 s | 1.3 s ▲ +633% | 0.2 s | 0.4 s |
| 17. Tap on id: color-Blue | 0.8 s | 0.6 s | 0.2 s | 0.1 s ▼ −89% | 1.2 s | 0.9 s | 1.1 s | 0.7 s |
| 18. Tap on id: qty-plus | 0.9 s | 0.6 s | 0.6 s | 0.4 s | 0.7 s | 0.9 s | 0.5 s | 0.6 s |
| 19. Assert that "Qty 2" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 20. Tap on id: qty-plus | 0.3 s | 0.1 s | 0.4 s | 0.3 s | 0.3 s | 0.2 s | 0.2 s | 0.3 s |
| 21. Assert that "Qty 3" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 22. Tap on id: add-to-cart | 0.7 s | 0.3 s | 0.6 s | 0.4 s ▼ −72% | 1.4 s | 0.7 s | 1.2 s | 0.3 s |
| 23. Assert that "Cart \(3\)" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 24. Tap on id: go-to-cart | 0.8 s | 0.9 s | 0.9 s | 1.2 s | 1.3 s | 1.2 s | 1.3 s | 1.0 s |
| 25. Assert that "Size M · Blue" is visible | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| 26. Tap on id: header-back | 1.0 s | 1.3 s | 1.1 s | 1.2 s | 1.5 s | 1.3 s | 1.3 s | 1.2 s |
| 27. Tap on id: header-back | 1.1 s | 1.0 s | 0.9 s | 1.0 s | 1.8 s | 1.3 s | 1.1 s | 1.0 s |
| 28. Tap on id: tab-profile | 0.4 s ▼ −85% | 2.4 s ▲ +538% | 0.4 s | 0.4 s | 0.8 s | 1.1 s | 0.6 s | 0.4 s |
| 29. Tap on id: security | 1.2 s | 1.3 s | 1.1 s | 1.2 s | 1.2 s | 1.2 s | 1.5 s | 1.1 s |
| 30. Tap on id: key-1 | 1.2 s | 1.6 s | 1.6 s | 1.4 s | 1.7 s | 1.6 s | 1.4 s | 1.6 s |
| 31. Tap on id: key-2 | 0.2 s | 0.4 s | 0.4 s | 0.1 s | 0.3 s | 0.4 s | 0.2 s | 0.3 s |
| 32. Tap on id: key-3 | 0.2 s | 0.4 s | 0.3 s | 0.3 s | 0.3 s | 0.3 s | 0.4 s | 0.2 s |
| 33. Tap on id: key-4 | 0.2 s | 0.1 s | 0.1 s | 0.2 s | 0.3 s | 0.2 s | 0.2 s | 0.3 s |
| 34. Assert that "Confirm your PIN" is visible | 0.3 s | 0.6 s | 0.4 s | 0.2 s | 0.3 s | 0.6 s | 0.7 s | 0.3 s |
| 35. Tap on id: key-1 | 0.2 s | 0.3 s | 0.3 s | 0.3 s | 0.2 s | 0.2 s | 0.2 s | 0.2 s |
| 36. Tap on id: key-2 | 0.2 s | 0.5 s | 0.1 s | 0.1 s | 0.3 s | 0.1 s | 0.2 s | 0.1 s |
| 37. Tap on id: key-3 | 0.2 s | 0.2 s | 0.1 s | 0.2 s | 0.5 s | 0.2 s | 0.2 s | 0.3 s |
| 38. Tap on id: key-4 | 0.2 s ▼ −84% | 1.4 s ▲ +1191% | 0.1 s | 0.2 s | 0.3 s | 0.3 s | 0.1 s | 0.3 s |
| 39. Assert that "PIN set" is visible | 1.0 s | 0.0 s ▼ −100% | 1.1 s | 1.5 s | 1.0 s | 0.9 s | 1.3 s | 0.9 s |
| 40. Tap on id: tab-lab | 0.3 s | 0.7 s | 0.6 s | 0.4 s | 0.6 s | 0.9 s | 0.5 s | 0.5 s |
| 41. Tap on id: lab-drag | 1.0 s ▼ −82% | 5.7 s ▲ +360% | 1.2 s | 1.1 s | 1.2 s | 1.1 s | 1.2 s | 1.2 s |
| 42. Tap on id: open-long-list | 2.5 s ▼ −85% | 17.0 s ✗ | 2.4 s | 2.8 s | 3.7 s | 3.1 s | 2.9 s | 2.5 s |
| 43. Scrolling DOWN until "Row 60" is visible with speed 40, visibility percentage 100%, timeout 60000 ms, with centering disabled | 4.2 s | – | 5.1 s ▼ −46% | 9.4 s ▲ +21% | 7.8 s | 8.7 s | 8.9 s ▲ +59% | 5.6 s |
| 44. Tap on "Row 60" | 0.2 s | – | 0.2 s | 0.7 s | 0.4 s | 0.2 s | 0.5 s | 0.4 s |
| 45. Assert that "Picked row 60" is visible | 0.0 s | – | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s | 0.0 s |
| **Total** | 38.6 s ▼ −40% | 64.6 s ✗ | 43.4 s ▼ −24% | 57.0 s | 55.3 s | 52.5 s | 53.1 s ▲ +16% | 45.8 s |
