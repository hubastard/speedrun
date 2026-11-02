# Install

Speedrun is one file, with its Android and iOS agents built in, for macOS on Apple silicon and
Linux x86_64.

## Homebrew

```sh
brew install hubastard/tap/speedrun
brew upgrade speedrun      # later, to update
```

## Install script

```sh
curl -fsSL https://raw.githubusercontent.com/hubastard/speedrun/main/install.sh | bash
speedrun update            # later, to update
```

The script picks the package for your machine, installs into `~/.speedrun` and adds it to your
PATH. For another folder or a specific release, put `SPEEDRUN_DIR=/usr/local/bin` or
`SPEEDRUN_VERSION=v0.2.0` in front of `bash`.

You can also download Speedrun from the
[releases](https://github.com/hubastard/speedrun/releases) and put it anywhere on your PATH.

## Updates

Speedrun tells you when a new release is out: update with `brew upgrade speedrun`, or
`speedrun update` if you used the script ([Command line](cli.md#other-commands)).

## Building from source

You need JDK 17, the [Odin](https://odin-lang.org) compiler and a C compiler (`cc`), plus
Xcode for iOS support.

```sh
git clone https://github.com/hubastard/speedrun.git
cd speedrun
./build.sh      # builds ./speedrun (Android support only without Xcode)
./package.sh    # optional: a release archive in dist/
```

For iOS only, without a JDK: `SPEEDRUN_NO_ANDROID=1 ./build.sh`. A release's iOS agent is
built with one Xcode (its release notes name it); with a much different Xcode, build from
source.

How Speedrun works inside: [dev/DEVELOPMENT.md](../dev/DEVELOPMENT.md). What is still slow:
[dev/TO_IMPROVE.md](../dev/TO_IMPROVE.md).
