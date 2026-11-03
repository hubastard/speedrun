#!/usr/bin/env bash
# What the web benchmark needs besides speedrun, all inside this folder:
# - tools: Playwright and Cypress (package.json), and the Chrome and Firefox builds Playwright
#   runs (Cypress runs the Firefox installed on this machine);
# - todomvc: TodoMVC, Playwright's demo copy (demo.playwright.dev/todomvc), into todomvc/site;
# - rwa: Cypress's Real World App at a fixed commit, into rwa/app: its two servers patched to
#   listen on 127.0.0.1 only (they listen on every interface otherwise), its packages installed
#   with yarn 1 (`corepack enable` gives it), its page built.
#   ./setup.sh                 all three
#   ./setup.sh todomvc rwa     the apps only (Speedrun's own CI: no other tool)
set -euo pipefail
cd "$(dirname "$0")"

RWA_COMMIT=0729f68ac220f7cda4ad09c5693dba11d7c532c6
PARTS=("${@:-tools todomvc rwa}")
read -r -a PARTS <<< "${PARTS[*]}"

for part in "${PARTS[@]}"; do
  case "$part" in
    tools)
      npm install --no-audit --no-fund
      npx playwright install chromium firefox
      ;;
    todomvc)
      mkdir -p todomvc/site/js
      for f in index.html base.css index.css js/director.js js/bundle.js; do
        curl -fsSL "https://demo.playwright.dev/todomvc/$f" -o "todomvc/site/$f"
      done
      ;;
    rwa)
      if [ ! -d rwa/app/.git ]; then
        git init -q rwa/app
        git -C rwa/app fetch -q --depth 1 https://github.com/cypress-io/cypress-realworld-app "$RWA_COMMIT"
        git -C rwa/app checkout -q FETCH_HEAD
      fi
      perl -pi -e 's/app\.listen\(port\);/app.listen(Number(port), "127.0.0.1");/' rwa/app/backend/app.ts
      perl -pi -e 's/app\.listen\(frontendPort\);/app.listen(Number(frontendPort), "127.0.0.1");/' rwa/app/scripts/testServer.ts
      # The app's own Cypress is not used (the one in package.json is): no second download.
      (cd rwa/app && CYPRESS_INSTALL_BINARY=0 yarn install --frozen-lockfile && yarn build)
      ;;
    *) echo "setup.sh: tools, todomvc or rwa, not $part"; exit 1 ;;
  esac
done
