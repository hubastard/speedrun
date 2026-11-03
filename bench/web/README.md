# Web: Speedrun against Playwright, Cypress and Maestro

Two apps, their tests written for each tool the way its own docs write them, and timed on the
same machine, in Chrome and in Firefox:

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
| Speedrun | this repo (Firefox: `--device firefox`) | [`todomvc/flow.yaml`](todomvc/flow.yaml), [`rwa/flows/`](rwa/flows) (Maestro flow format) |
| [Playwright](https://playwright.dev) | 1.64.1 (`npx playwright test`, Firefox: `--project=firefox`) | [`todomvc/playwright/`](todomvc/playwright), [`rwa/playwright/`](rwa/playwright) |
| [Cypress](https://www.cypress.io) | 16.1.1 (`npx cypress run`, Firefox: `--browser firefox`) | [`todomvc/cypress/`](todomvc/cypress), [`rwa/cypress/`](rwa/cypress) |
| [Maestro](https://maestro.dev) | 2.11 (`maestro test --headless`) | the same flows as Speedrun |

## Results

### On a Mac, in Chrome

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

### On Linux, in Chrome and Firefox

A GitHub Actions `ubuntu-24.04` runner (4 vCPUs), 2026-11-03, run by
[`bench-web.yml`](../../.github/workflows/bench-web.yml): the same tests, conditions and
medians as above, each tool with its own builds of the browsers (every run's output:
[`results/linux`](results/linux)). A shared runner is slower than the Mac, and its times vary
more from day to day: compare the tools within a table.

| Tool | TodoMVC | Real World App (7 tests) |
|---|---|---|
| **Speedrun**, Chrome | **0.62 s** (0.62, 0.69, 0.62) | **6.87 s** (7.10, 6.81, 6.87) |
| Playwright, Chrome | 1.93 s (1.93, 1.92, 1.93) | 9.33 s (9.91, 9.33, 9.29) |
| Cypress, Electron | 6.76 s (6.42, 6.78, 6.76) | 16.78 s (16.78, 17.15, 16.76) |
| **Speedrun**, Firefox | **2.99 s** (2.99, 2.99, 3.05) | **11.51 s** (11.44, 11.69, 11.51) |
| Playwright, Firefox | 3.88 s (3.87, 3.88, 4.21) | 15.16 s (15.08, 15.38, 15.16) |
| Cypress, Firefox | 9.00 s (9.18, 9.00, 8.87) | 21.75 s (21.88, 21.75, 21.74) |

Every tool passed every test in every run. The browsers:
- **Speedrun:** Chrome for Testing's headless shell 156, and Mozilla's Firefox 159.
- **Playwright:** its own Chromium 156, and its own Firefox build, 157.
- **Cypress:** Electron 146, and the runner's Firefox 158.

Firefox starts more slowly than Chrome: about a second of each Firefox time above, for every
tool. (On the Mac above, Playwright's Firefox build did not start at all: "Could not find
profile folder", next to an installed Firefox. Hence the Firefox numbers from Linux.)

## Running it

```sh
./setup.sh               # Playwright, Cypress, TodoMVC and the Real World App, all in this folder
./run.sh todomvc         # or: ./run.sh rwa speedrun playwright
./run.sh rwa speedrun-firefox playwright-firefox cypress-firefox     # in Firefox
./run.sh rwa maestro     # Maestro runs only when named
```

`setup.sh` installs Playwright and Cypress (`package.json`) and downloads TodoMVC. It also
clones the Real World App at a fixed commit, installs its packages with yarn 1 (`corepack
enable`) and builds it. The app's two servers are patched to listen on 127.0.0.1 only; they
listen on every interface otherwise.

`run.sh` needs `../../speedrun` (`./build.sh`). It starts the app's servers on 127.0.0.1 and
stops them at the end. It runs each tool once to warm up and then `RUNS` times (3 by default).
The results go to `results/<app>.md` (`OUT=<name>`: `results/<name>.md`), with each run's
output next to it. On GitHub, `bench-web.yml` (run by hand) does all of it on a Linux runner,
every tool in both browsers.
