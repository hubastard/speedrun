# Command line

```
speedrun test [options] <flow file or folder>...
```

## Options

Speedrun takes `maestro test`'s options. `-p` and `--device` may also come before `test`.

| Option | |
|---|---|
| `-e`, `--env KEY=VALUE` | Set a variable for the flows (repeatable). |
| `--config <file>` | Workspace config (default: `config.yaml` in the folder). |
| `--include-tags a,b` / `--exclude-tags a,b` | Run only the flows with, or without, these tags. |
| `--format junit\|html\|html-detailed\|noop` | Write a report. |
| `--output <file>` | Report path (default `report.xml` / `report.html`). |
| `--test-suite-name <name>` | Suite name in the report. |
| `--debug-output <dir>` | Where each run's logs, screenshots and recordings go (default `~/.speedrun/tests/<date>/`). |
| `--flatten-debug-output` | Write them straight into that folder, without a dated subfolder. |
| `--test-output-dir <dir>` | The same, taking precedence over `--debug-output` (or `testOutputDir` in the config). |
| `-p`, `--platform android\|ios` | Platform (default: a connected Android device, else the booted simulator). |
| `--device`, `--udid <id>[,<id>...]` | Device serial (`adb devices`) or simulator UDID (`xcrun simctl list devices booted`). |
| `--shard-split <n>` | Split the flows across n devices. |
| `--shard-all <n>` | Run every flow on each of n devices. |
| `-c`, `--continuous` | Rerun the flow when its files change, or when you press Enter. |

## Speedrun's own options


| Option | |
|---|---|
| `--plain`, `--no-ansi` | Plain line-by-line output instead of the live view (the default when the output is not a terminal). |
| `--timings <file.json>` | Write each command's timing to a JSON file. |
| `--port <n>` | The agent's port (default 7777 on Android, 7778 on iOS). |
| `--instrument` | Android: run the agent as an instrumentation (a fallback; ~60 ms slower per action). |

## Other commands


```
speedrun --stop-agent      # stop the iOS agent kept running between runs
speedrun --version
speedrun --help
```

## Environment variables


| Variable | |
|---|---|
| `SPEEDRUN_IDLE_S` | iOS: seconds of inactivity before the agent stops (default 600). |
| `SPEEDRUN_DEBUG=1` | Print every screen read and shell command with its time. |
| `SPEEDRUN_LONG_PRESS_MS` | How long `longPressOn` holds, for an app whose own long-press delay is longer than usual. |
| `SPEEDRUN_CONDITION_TIMEOUT_MS` | How long a `when: visible` (or `notVisible`) waits for its element (default 7000, as Maestro); a condition's own `timeout` takes precedence. See [Conditions take up to 7 s](maestro-compatibility.md#conditions-take-up-to-7-s). |
| `MAESTRO_*` | Passed to flows as variables, as in Maestro. |

## Exit status

Speedrun exits with status 1 when a flow fails. A suite prints one line per flow, then
`N/M Flows Passed` or `N/M Flows Failed`.
