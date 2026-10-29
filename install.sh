#!/usr/bin/env bash
# Installs speedrun's latest release into ~/.speedrun and puts it on your PATH:
#   curl -fsSL https://raw.githubusercontent.com/hubastard/speedrun/main/install.sh | bash
# Environment:
#   SPEEDRUN_VERSION=v0.1.7       a given release instead of the latest
#   SPEEDRUN_DIR=<dir>            where to install (default ~/.speedrun)
#   SPEEDRUN_NO_MODIFY_PATH=1     leave your shell profile alone
# On GitHub Actions the folder is added to $GITHUB_PATH, for the job's next steps.
set -euo pipefail

REPO="${SPEEDRUN_REPO:-hubastard/speedrun}"
DIR="${SPEEDRUN_DIR:-$HOME/.speedrun}"
DOWNLOADS="${SPEEDRUN_DOWNLOAD_URL:-https://github.com/$REPO/releases/download}"

fail() {
  printf 'speedrun install: %s\n' "$*" >&2
  exit 1
}

command -v curl > /dev/null || fail "curl is needed"
command -v tar > /dev/null || fail "tar is needed"

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) fail "speedrun runs on macOS and Linux, not $(uname -s)" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) arch=$(uname -m) ;;
esac
case "$os-$arch" in
  macos-arm64 | linux-x86_64) ;;
  *) fail "there is no speedrun package for $os $arch yet (macOS on Apple silicon and Linux x86_64 have one): build it from source, https://github.com/$REPO#building-from-source" ;;
esac

version="${SPEEDRUN_VERSION:-}"
if [ -z "$version" ]; then
  version=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1) || true
  [ -n "$version" ] || fail "could not find speedrun's latest release (https://github.com/$REPO/releases)"
fi

name="speedrun-$version-$os-$arch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading speedrun $version for $os $arch..."
curl -fSL --progress-bar "$DOWNLOADS/$version/$name.tar.gz" -o "$tmp/$name.tar.gz" \
  || fail "could not download $DOWNLOADS/$version/$name.tar.gz"
# The package's SHA-256, published next to it from v0.1.15 on: a download that does not match
# (cut short, or changed on the way) is not installed.
if curl -fsSL "$DOWNLOADS/$version/$name.tar.gz.sha256" -o "$tmp/$name.tar.gz.sha256" 2> /dev/null; then
  expected=$(cut -d ' ' -f 1 < "$tmp/$name.tar.gz.sha256")
  if command -v sha256sum > /dev/null; then
    actual=$(sha256sum "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
  else
    actual=$(shasum -a 256 "$tmp/$name.tar.gz" | cut -d ' ' -f 1)
  fi
  [ -n "$expected" ] && [ "$actual" = "$expected" ] \
    || fail "the download does not match its checksum (SHA-256 $actual, published: $expected): not installed"
else
  case "$version" in
    v0.1.[0-9] | v0.1.1[0-4]) echo "($version has no published checksum: releases before v0.1.15 have none)" ;;
    *) fail "could not download the package's checksum ($DOWNLOADS/$version/$name.tar.gz.sha256): not installed" ;;
  esac
fi
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
[ -x "$tmp/$name/speedrun" ] || fail "the package has no speedrun binary"

# Replaces a previous install: the binary, its iOS agent and its README, nothing else.
mkdir -p "$DIR"
rm -rf "$DIR/speedrun" "$DIR/agent" "$DIR/README.txt"
cp -R "$tmp/$name/." "$DIR/"
installed=$("$DIR/speedrun" --version) || fail "the installed binary does not run ($DIR/speedrun)"
echo "Installed $installed in $DIR"

if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$DIR" >> "$GITHUB_PATH"
elif [ "${SPEEDRUN_NO_MODIFY_PATH:-}" != 1 ]; then
  case "${SHELL:-}" in
    */zsh) profile="$HOME/.zshrc" ;;
    */bash) profile="$HOME/.bashrc"; [ "$os" = macos ] && profile="$HOME/.bash_profile" ;;
    *) profile= ;;
  esac
  if [ -n "$profile" ]; then
    if ! grep -qsF "$DIR" "$profile"; then
      printf '\n# speedrun\nexport PATH="%s:$PATH"\n' "$DIR" >> "$profile"
      echo "Added $DIR to your PATH in $profile: open a new terminal, or run"
      echo "  export PATH=\"$DIR:\$PATH\""
    fi
  else
    echo "Add $DIR to your PATH:"
    echo "  export PATH=\"$DIR:\$PATH\""
  fi
fi

echo
echo "Next: start an Android emulator (adb on your PATH) or boot an iOS simulator (Xcode), then"
echo "  speedrun test <flow file or folder>"
