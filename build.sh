#!/usr/bin/env bash
# Builds ./speedrun: the agent APK first, then the Odin binary, which embeds it. Run it once,
# and again after changing agent/android/ or host/. Running flows never rebuilds anything.
set -euo pipefail
cd "$(dirname "$0")"

command -v odin >/dev/null || { echo "odin not found on PATH"; exit 1; }

echo "== Building the agent (Gradle)"
(cd agent/android && ./gradlew -q assembleDebug)

echo "== Building speedrun (Odin)"
odin build host -o:speed -out:speedrun

echo "Done: ./speedrun --flow <file.yaml>"
