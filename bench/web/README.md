# Web: Speedrun against Playwright, Cypress and Maestro

Two apps, their tests written for each tool the way its own docs write them, and timed on the
same machine:

1. **TodoMVC**, Playwright's demo copy ([demo.playwright.dev/todomvc](https://demo.playwright.dev/todomvc)):
   add five todos, complete one, filter by Active and by Completed, clear the completed ones.
   About 20 steps.
2. **Cypress's [Real World App](https://github.com/cypress-io/cypress-realworld-app)**, a
   payments app in React and Material UI with an Express API: seven tests taken from its own
   Cypress suite. Sign in and out; sign up, sign in and add the onboarding's bank account; send
   a payment; request money; like and comment on a transaction; edit the user settings; add a
   bank account. Each test resets the app's data (its seed endpoint) and signs in through the
   form.

| Tool | Version | Written as |
|---|---|---|
| Speedrun | this repo | [`todomvc/flow.yaml`](todomvc/flow.yaml), [`rwa/flows/`](rwa/flows) (Maestro flow format) |
| [Playwright](https://playwright.dev) | 1.64.1 (`npx playwright test`) | [`todomvc/playwright/`](todomvc/playwright), [`rwa/playwright/`](rwa/playwright) |
| [Cypress](https://www.cypress.io) | 16.1.1 (`npx cypress run`) | [`todomvc/cypress/`](todomvc/cypress), [`rwa/cypress/`](rwa/cypress) |
| [Maestro](https://maestro.dev) | 2.11 (`maestro test --headless`) | the same flows as Speedrun |

## Results

Apple M1 Pro (16 GB), 2026-11-03. The median of three runs after a warm-up, then each run's
time in seconds. A run's time is the wall clock of the tool's command, its start-up included,
as a CI job sees it:

| Tool | TodoMVC | Real World App (7 tests) |
|---|---|---|
| **Speedrun** | **0.66 s** (0.68, 0.66, 0.66) | **4.19 s** (4.20, 4.19, 4.19) |
| Playwright | 1.30 s (1.29, 1.30, 1.30) | 5.86 s (5.89, 5.86, 5.83) |
| Cypress | 3.66 s (3.66, 3.66, 3.66) | 11.32 s (11.33, 11.29, 11.32) |
| Maestro | failed in every run, after ~60 s | stopped after 30 min: 6 of 7 tests run, 3 passed |

Speedrun, Playwright and Cypress passed every test in every run. The conditions were the same
for each tool:

- **Headless Chrome.** Speedrun ran Chrome for Testing's headless shell (156) and Playwright its
  own headless shell (Chromium 156). Cypress ran Electron 146, its default browser; with Chrome
  for Testing 156 instead (`--browser`), it took 11.5 s on the Real World App.
- **The same window size:** 1280x720 for TodoMVC (Playwright's default) and 1280x1000 for the
  Real World App (its own Cypress settings).
- **One test at a time.** The Real World App's tests share one database file. Playwright runs
  a spec file's tests in one worker anyway.
- **Each tool's default settings.** Speedrun does not speed up a page's animations.
- **Typing:** Playwright's `fill` puts a field's whole text in at once. Speedrun and Cypress
  type it a key at a time, and Cypress waits 10 ms between keys by default.

Maestro ran the same flow files as Speedrun:

- **TodoMVC:** its check of the item count (`".*items left"`) failed in every run.
- **The Real World App:** one run, stopped after 30 minutes. Its taps by CSS selector took
  minutes each; the sign-up test alone took 15 min 25 s.
  - Two tests failed on the "New" link: Maestro reads its text as `" New"`, with a leading
    space, and doesn't trim it.
  - One failed on the new bank account's name.

## Running it

```sh
./setup.sh               # Playwright, Cypress, TodoMVC and the Real World App, all in this folder
./run.sh todomvc         # or: ./run.sh rwa speedrun playwright
./run.sh rwa maestro     # Maestro runs only when named
```

`setup.sh` installs Playwright and Cypress (`package.json`) and downloads TodoMVC. It also
clones the Real World App at a fixed commit, installs its packages with yarn 1 (`corepack
enable`) and builds it. The app's two servers are patched to listen on 127.0.0.1 only; they
listen on every interface otherwise.

`run.sh` needs `../../speedrun` (`./build.sh`). It starts the app's servers on 127.0.0.1 and
stops them at the end. It runs each tool once to warm up and then `RUNS` times (3 by default).
The results go to `results/<app>.md`, with each run's output next to it.
