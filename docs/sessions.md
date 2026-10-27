# Sessions: drive an app a command at a time

A session keeps Speedrun connected to a device between commands, so an AI coding agent (or
you, in a terminal) can explore an app step by step: look at the screen, tap, type, check what
changed, and save the steps that worked as a flow file for CI. No flow file to edit and rerun
from the start after each change.

```sh
speedrun session start --app com.example.app     # connects to the device once
speedrun look                                    # what is on screen
speedrun do 'tapOn: @5'                          # flow commands, as in a flow file
speedrun session save flows/sign-in.yaml         # the commands that passed, as a flow
speedrun session stop
```

Each command takes as long as it does in a flow: the device stays connected, and Speedrun
waits for the app to settle after every step, as in a test run.

## Reading the screen

`speedrun look` prints one line per element a user can see or act on, in reading order:

```
ios 402x874, 8 elements
@1 Text "Sign in"
@2 Text "Let's start with your phone number"
@4 Text "Phone number"
@5 Field #phone-input hint="(555) 010-1234"
@6 View "checkbox, unchecked" #remember-me
@7 Button "Next" #next disabled
@8 Button "Continue as guest" #guest
Keyboard
```

Each line has a ref (`@5`), the kind of element, its text, its id (`#phone-input`, shown
when it is the only one on screen) and its state (`disabled`, `checked`, `focused`,
`selected`). Layout containers, the status bar and the keyboard's keys are left out. A screen
takes a few hundred tokens, where a raw accessibility tree takes tens of thousands.

`speedrun look --shot` also saves a screenshot, scaled to 500 pixels wide, and prints its path.
`speedrun look --all` also prints every node of the accessibility tree, for when the listing
leaves out something you need (long: use it to investigate, not at every step).

## Running commands

`speedrun do` takes flow commands, written as in a flow file, one per argument:

```sh
speedrun do 'tapOn: "Sign in"'
speedrun do 'tapOn: @5' 'inputText: "5550101234"' 'tapOn: @7'
speedrun do 'scrollUntilVisible:
    element: "Row 60"'
speedrun do - < steps.yaml          # a list of commands from stdin
```

A ref stands for a selector that finds that element: `tapOn: @5` runs as
`tapOn: {id: "phone-input"}`. Speedrun picks the id when the element has one, else its text,
with an `index` when several elements match. In an assertion, an element with both an id and a
text is checked on both: `assertVisible: @9` runs as
`assertVisible: {id: "greeting", text: "Hi, Alex"}`. A ref keeps its number while the element
stays on screen, as its state or a field's value changes.

The answer has a line per command, then what changed on screen:

```
ok Tap on id: phone-input  642 ms
ok Input text 5550101234  244 ms
ok Tap on id: next  150 ms
+ @11 Text "Sending code"
~ @5 Field "(555) 010-1234" #phone-input focused
+ Keyboard
```

`+` is a new element, `~` one that changed, `-` one that went away. When most of the screen
is new, the whole new screen is printed instead. A command that fails says why, and names the
elements like the one it looked for:

```
FAILED Tap on "Sign In now"  17.0 s
  Element not found: Text matching regex: Sign In now
  similar: @1 Text "Sign in";
```

The exit status is 0 when every command passed, 1 when one failed, and 2 for a command that
is not valid YAML or a ref that is not on the screen.

## Saving the flow

Speedrun records each command that passed, with its refs replaced by their selectors.
`speedrun session log` lists them; `speedrun session save <file>` writes them as a flow:

```yaml
appId: com.example.app
---
- launchApp:
    clearState: true
- tapOn: {id: "onboarding-skip"}
- tapOn: {id: "phone-input"}
- inputText: "5550101234"
- tapOn: {id: "next"}
- assertVisible: {id: "code-input"}
- inputText: "123456"
- assertVisible: {id: "greeting", text: "Hi, Alex"}
```

Commands that failed are left out. When the app changed by itself between two commands (a
screen that loaded while you looked at it), and the next command does not wait for an element
(typing, a key press), Speedrun records a wait first (`assertVisible: {id: "code-input"}`
above): run as a flow, the command comes right after the one before, and would otherwise run
before the new screen is there. `speedrun session clear` starts the recording over.

## Notes

- `--app` names the app the commands are for: `launchApp` and `stopApp` without an id use it.
  `--platform`, `--device` and `-e KEY=VALUE` work as in `speedrun test`.
- A session holds the device: `speedrun test` refuses to run on it until the session stops.
- The session ends after an hour without commands (`SPEEDRUN_SESSION_IDLE_S`), and its log is
  in `~/.speedrun/session/session.log`.
- The time between your commands does not count: each command waits for its element for the
  full 17 s, as at the start of a flow.

## For AI agents

### As an MCP server

`speedrun mcp` serves the session as [Model Context Protocol](https://modelcontextprotocol.io)
tools, over stdin and stdout. With Claude Code:

```sh
claude mcp add speedrun -- ~/.speedrun/speedrun mcp
```

Other MCP clients take the command (the binary's full path: a client may not start servers
with your shell's PATH) and the argument `mcp`; see the [README](../README.md#as-an-mcp-server).
The tools:

| Tool | |
|---|---|
| `session_start` | `app`, and optionally `platform` and `device`: connects to the device. |
| `look` | The screen's listing; `screenshot: true` adds a small screenshot (an image), `all: true` every node of the tree. |
| `run` | `commands`: flow commands, one or a list, with refs. |
| `save_flow` | `path`: writes the commands that passed as a flow file. |
| `session_log`, `session_clear`, `session_stop` | As the commands of the same name. |

A failed command, or no session, comes back as an error result with the same text as on the
command line.

### From a shell

An agent that runs shell commands can use the command line directly. Add something like this
to its instructions (`CLAUDE.md`, `AGENTS.md`):

```markdown
To test the mobile app, use Speedrun's session (docs/sessions.md):
- `speedrun session start --app <appId>`, then `speedrun look` to read the screen.
- `speedrun do '<flow command>'` runs commands; use the @refs from the latest output.
- `speedrun look --shot` only when the text listing is not enough.
- When a scenario works, `speedrun session save flows/<name>.yaml`, then check it with
  `speedrun session stop && speedrun test flows/<name>.yaml`.
```
