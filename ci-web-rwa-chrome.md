# Real World App, Chrome, on Speedrun's CI

<!-- Written by results.py from history.jsonl: edits here are overwritten. -->

Each flow's time, the last 8 pushes, newest first (GitHub Actions ubuntu-24.04 runner (4 vCPUs), headless). ▲/▼: at least 15% slower/faster than the push before.

| Flow | 19bcdb7<br>11-12 22:37 | 00c3b3e<br>11-12 22:14 | a171959<br>11-11 14:39 | 91c0d78<br>11-11 14:24 | d432e3a<br>11-11 13:39 | 751d47b<br>11-11 13:35 | 8dac6e3<br>11-11 13:13 | 7eb34e0<br>11-09 23:29 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Add a bank account | 0.73 s | 0.80 s | 0.65 s | 0.84 s ▲ +43% | 0.59 s | 0.49 s | 0.58 s | 0.56 s |
| Edit user settings | 0.90 s | 0.98 s ▲ +28% | 0.77 s ▼ −23% | 1.00 s | 0.86 s ▲ +41% | 0.61 s | 0.73 s | 0.77 s |
| Like and comment on a transaction | 0.78 s | 0.80 s | 0.72 s | 0.91 s | 0.77 s | 0.60 s | 0.72 s | 0.75 s |
| Request money | 0.88 s | 0.94 s ▲ +32% | 0.71 s ▼ −28% | 0.98 s ▲ +30% | 0.76 s | 0.66 s | 0.76 s | 0.68 s |
| Send a payment | 1.04 s | 1.17 s ▲ +25% | 0.93 s ▼ −23% | 1.21 s | 1.36 s ▲ +72% | 0.79 s ▼ −24% | 1.04 s | 0.99 s |
| Sign in and out | 0.48 s | 0.55 s | 0.49 s | 0.49 s | 0.45 s | 0.32 s | 0.33 s | 0.45 s |
| Sign up, sign in, onboarding | 1.76 s | 1.75 s ▲ +17% | 1.49 s ▼ −19% | 1.85 s ▲ +22% | 1.51 s ▲ +20% | 1.26 s | 1.31 s ▼ −20% | 1.65 s |
| **All flows** | 6.57 s | 6.99 s ▲ +21% | 5.75 s ▼ −21% | 7.29 s ▲ +16% | 6.29 s ▲ +33% | 4.73 s | 5.48 s | 5.85 s |
| **Wall clock** | – | – | – | – | – | – | – | – |
