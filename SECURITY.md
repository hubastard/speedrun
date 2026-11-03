# Security

## Reporting a vulnerability

Please report it privately, through **[Report a vulnerability](https://github.com/hubastard/speedrun/security/advisories/new)**
on this repository's Security tab, not in a public issue. Include what you found, the version
(`speedrun --version`), the platform, and the steps or a flow that shows it.

You will get an answer within 3 working days. Once it is confirmed, the fix goes out in a
release, and the advisory is published with it, crediting you unless you prefer not.

## Supported versions

Fixes go into the latest release only. `speedrun update` (or `brew upgrade speedrun`)
installs it.

## Scope

In scope: the `speedrun` binary, `install.sh` and the releases' packages, the Android and iOS
agents it installs, and how it drives browsers. For example:

- the agents' local port (127.0.0.1, a per-run token) and what a client can do through it;
- the shell commands it runs on a device or on this machine;
- flow scripts' access beyond what a flow file gives them;
- the browsers it downloads, and Firefox's system access during a run.

Out of scope: the benchmark and test apps (`bench/`, `dev/`), and the apps and websites a
flow tests.
