// Maestro flow files (Maestro 2.11.0 syntax): the config document, then the commands.
// Same command names, argument shorthands and defaults as Maestro's own parser
// (maestro-orchestra/.../yaml). Strict: an unknown command or field is an error, and so is a
// valid Maestro command or field this runner does not implement, so a flow that loads is
// run as written.
package speedrun

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Selector :: struct {
	text, id, index:                     Maybe(string), // regexes, index as text (may use ${})
	enabled, selected, checked, focused: Maybe(bool),
	width, height, tolerance:            Maybe(int),
	below, above, left_of, right_of:     ^Selector,
	contains_child, child_of:            ^Selector,
	contains_descendants:                [dynamic]^Selector,
	// Fields Maestro reads from the same map for tap commands.
	point:                               string,
	retry_tap_if_no_change:              bool,
	repeat, delay:                       Maybe(int),
	wait_to_settle_timeout_ms:           Maybe(int),
}

Condition :: struct {
	platform:             Maybe(string),
	visible, not_visible: ^Selector,
	script:               Maybe(string), // `true:`, after ${} substitution
}

Swipe_Dir :: enum u8 {
	Up,
	Down,
	Left,
	Right,
}

Env_Pair :: struct {
	key, value: string,
}

Launch_App :: struct {
	app_id:         string,
	clear_state:    bool,
	clear_keychain: bool, // iOS only
	stop_app:       bool,
}
App_Op :: enum u8 {
	Stop,
	Kill,
	Clear_State,
}
App_Cmd :: struct {
	op:     App_Op,
	app_id: string,
}
Tap :: struct {
	sel:        ^Selector, // nil: tap on `point` (screen coordinates or percentages)
	point:      string, // with sel: point inside the element
	long_press: bool,
	repeat:     int, // taps
	delay_ms:   int, // between taps
	retry:      bool, // retryTapIfNoChange
	settle_ms:  Maybe(int),
}
Assert :: struct {
	cond:    Condition,
	timeout: Maybe(string),
}
Input_Text :: struct {
	text: string,
}
Erase_Text :: struct {
	count:    int,
	explicit: bool, // the count was given (Maestro describes the default as "Erase text")
}
Key_Press :: struct {
	name:    string,
	keycode: i32,
}
Navigate :: enum u8 {
	Back,
	Hide_Keyboard,
	Scroll,
	Clear_Keychain,
}
Scroll_Until :: struct {
	sel:        ^Selector,
	direction:  Swipe_Dir, // scroll direction (DOWN = content moves up)
	timeout:    string,
	speed:      string,
	visibility: int,
	center:     bool,
	settle_ms:  Maybe(int),
}
Swipe :: struct {
	direction:  Maybe(Swipe_Dir),
	start, end: string, // "x, y" or "x%, y%"
	from:       ^Selector,
	duration:   int,
	settle_ms:  Maybe(int),
}
Wait_Animation :: struct {
	timeout: Maybe(string),
}
Open_Link :: struct {
	link: string,
}
Sub_Flow :: struct {
	commands:    [dynamic]Cmd,
	env:         [dynamic]Env_Pair,
	on_start:    [dynamic]Cmd, // a file's onFlowStart/onFlowComplete
	on_complete: [dynamic]Cmd,
	source:      string, // file name, if any
}
Run_Flow :: struct {
	using sub: Sub_Flow,
	cond:      Maybe(Condition),
}
Repeat :: struct {
	times:    Maybe(string),
	cond:     Maybe(Condition),
	commands: [dynamic]Cmd,
}
Retry :: struct {
	using sub:   Sub_Flow,
	max_retries: string,
}
Screenshot :: struct {
	path: string,
}

Cmd_Data :: union {
	Launch_App,
	App_Cmd,
	Tap,
	Assert,
	Input_Text,
	Erase_Text,
	Key_Press,
	Navigate,
	Scroll_Until,
	Swipe,
	Wait_Animation,
	Open_Link,
	Run_Flow,
	Repeat,
	Retry,
	Screenshot,
}

Cmd :: struct {
	name:     string, // Maestro's command name, e.g. "tapOn"
	data:     Cmd_Data,
	label:    string,
	optional: bool,
	file:     string,
	line:     int,
}

Flow :: struct {
	path, name, app_id:    string,
	env:                   [dynamic]Env_Pair,
	tags:                  [dynamic]string, // for --include-tags / --exclude-tags
	files:                 [dynamic]string, // this file and every runFlow file it loads
	properties:            [dynamic]Env_Pair, // reported in JUnit
	on_start, on_complete: [dynamic]Cmd,
	commands:              [dynamic]Cmd,
}

// Every command Maestro 2.11.0 accepts. Names here but not handled below are rejected as
// "not supported yet" rather than "unknown".
MAESTRO_COMMANDS :: []string {
	"tapOn", "doubleTapOn", "longPressOn", "assertVisible", "assertNotVisible", "assertTrue",
	"assertNoDefectsWithAI", "assertScreenshot", "assertWithAI", "extractTextWithAI", "back",
	"clearKeychain", "hideKeyboard", "hide keyboard", "pasteText", "scroll", "inputText",
	"inputRandomText", "inputRandomNumber", "inputRandomEmail", "inputRandomPersonName",
	"inputRandomCityName", "inputRandomCountryName", "inputRandomColorName", "launchApp",
	"setPermissions", "swipe", "openLink", "pressKey", "eraseText", "action", "takeScreenshot",
	"extendedWaitUntil", "stopApp", "killApp", "clearState", "runFlow", "setLocation",
	"setOrientation", "repeat", "copyTextFrom", "setClipboard", "runScript",
	"waitForAnimationToEnd", "evalScript", "scrollUntilVisible", "travel", "startRecording",
	"stopRecording", "addMedia", "setAirplaneMode", "toggleAirplaneMode", "setDarkMode",
	"toggleDarkMode", "assertDarkMode", "assertLightMode", "retry",
}

// Commands that may be written as a bare string (`- back`).
STRING_COMMANDS :: []string {
	"launchApp", "stopApp", "killApp", "clearState", "clearKeychain", "eraseText",
	"inputRandomText", "inputRandomNumber", "inputRandomEmail", "inputRandomPersonName",
	"inputRandomCityName", "inputRandomCountryName", "inputRandomColorName", "back",
	"hideKeyboard", "hide keyboard", "pasteText", "scroll", "waitForAnimationToEnd",
	"stopRecording", "toggleAirplaneMode", "toggleDarkMode", "assertDarkMode",
	"assertLightMode", "assertNoDefectsWithAI",
}

// Maestro's key names (KeyCode.description, matched ignoring case) and Android key codes.
KEYS :: []struct {
	name: string,
	code: i32,
}{
	{"Enter", 66}, {"Backspace", 67}, {"Back", 4}, {"Home", 3}, {"Lock", 276},
	{"Volume Up", 24}, {"Volume Down", 25}, {"Remote Dpad Up", 19}, {"Remote Dpad Down", 20},
	{"Remote Dpad Left", 21}, {"Remote Dpad Right", 22}, {"Remote Dpad Center", 23},
	{"Remote Media Play Pause", 85}, {"Remote Media Stop", 86}, {"Remote Media Next", 87},
	{"Remote Media Previous", 88}, {"Remote Media Rewind", 89},
	{"Remote Media Fast Forward", 90}, {"Escape", 111}, {"Power", 26}, {"Tab", 62},
	{"Remote System Navigation Up", 280}, {"Remote System Navigation Down", 281},
	{"Remote Button A", 96}, {"Remote Button B", 97}, {"Remote Menu", 82}, {"TV Input", 178},
	{"TV Input HDMI 1", 243}, {"TV Input HDMI 2", 244}, {"TV Input HDMI 3", 245},
}

Loader :: struct {
	alloc:    mem.Allocator,
	file:     string, // flow being parsed
	app_id:   string,
	err:      string,
	err_line: int,
	depth:    int, // runFlow nesting, against cycles
	files:    [dynamic]string, // every flow file loaded (watched by continuous mode)
}

@(private = "file")
fail :: proc(l: ^Loader, y: ^Yaml, msg: string, args: ..any) {
	if l.err != "" do return
	l.err = fmt.aprintf(msg, ..args, allocator = l.alloc)
	l.err_line = y.line if y != nil else 0
}

// Reads a flow file. On error, `err` names the problem and the line.
load_flow :: proc(path: string, alloc: mem.Allocator) -> (flow: Flow, err: string) {
	l := Loader {
		alloc = alloc,
	}
	flow, _ = load_flow_file(&l, path, true)
	flow.files = l.files
	if l.err != "" {
		return flow, fmt.aprintf("%s:%d: %s", l.file, l.err_line, l.err, allocator = alloc)
	}
	return flow, ""
}

@(private = "file")
load_flow_file :: proc(l: ^Loader, path: string, top: bool) -> (flow: Flow, ok: bool) {
	context.allocator = l.alloc
	saved_file := l.file
	defer if l.err == "" do l.file = saved_file
	l.file = path
	if l.depth > 20 {
		fail(l, nil, "runFlow nested more than 20 levels deep (a cycle?)")
		return
	}
	append(&l.files, path)
	data, rerr := os.read_entire_file(path, l.alloc)
	if rerr != nil {
		fail(l, nil, "cannot read flow file: %v", rerr)
		return
	}
	docs, yerr, yline := yaml_parse(string(data), l.alloc)
	if yerr != "" {
		l.err, l.err_line = yerr, yline
		return
	}
	if len(docs) == 0 || docs[0].kind != .Map {
		fail(l, docs[0] if len(docs) > 0 else nil, "flow files must start with a config section, e.g. `appId: com.example.app`, then `---`")
		return
	}
	if len(docs) < 2 || docs[1].kind != .Seq {
		fail(l, docs[0], "flow files must have a list of commands after the config section (`---`)")
		return
	}
	if len(docs) > 2 {
		fail(l, docs[2], "only two documents expected: config, then commands")
		return
	}
	flow.path = path
	cfg := docs[0]
	// This file's appId is the default of its launchApp, stopApp...: read it before the
	// other keys (onFlowStart may come first), and only for this file (Maestro resolves a
	// runFlow file's commands against that file's own appId).
	if v := yaml_get(cfg, "appId"); v != nil do flow.app_id = str(l, v) or_return
	saved_app_id := l.app_id
	defer l.app_id = saved_app_id
	l.app_id = flow.app_id
	for key, i in cfg.keys {
		v := cfg.vals[i]
		switch key {
		case "appId":
		// read above
		case "name":
			flow.name = str(l, v) or_return
		case "env":
			flow.env = env_map(l, v) or_return
		case "onFlowStart", "onFlowComplete":
			// A list of commands (Maestro's main form), or a map with `commands:`.
			cmds := v if v.kind == .Seq else (yaml_get(v, "commands") if v.kind == .Map else nil)
			if cmds == nil {
				fail(l, v, "`%s` takes a list of commands", key)
				return
			}
			list := commands(l, cmds) or_return
			if key == "onFlowStart" {
				flow.on_start = list
			} else {
				flow.on_complete = list
			}
		case "url":
			fail(l, v, "web flows (`url`) are not supported")
			return
		case "tags":
			if v.kind == .Seq {
				for t in v.items do append(&flow.tags, str(l, t) or_return)
			} else if v.kind != .Null {
				append(&flow.tags, str(l, v) or_return)
			}
		case "properties":
			if v.kind != .Null do flow.properties = env_map(l, v) or_return
		case:
		// Anything else Maestro keeps as metadata: not needed to run.
		}
	}
	if flow.app_id == "" {
		fail(l, cfg, "the config section needs `appId`")
		return
	}
	flow.commands = commands(l, docs[1]) or_return
	return flow, true
}

@(private = "file")
commands :: proc(l: ^Loader, seq: ^Yaml) -> (list: [dynamic]Cmd, ok: bool) {
	if seq.kind != .Seq {
		fail(l, seq, "expected a list of commands")
		return
	}
	for item in seq.items {
		c := command(l, item) or_return
		append(&list, c)
	}
	return list, true
}

@(private = "file")
command :: proc(l: ^Loader, y: ^Yaml) -> (c: Cmd, ok: bool) {
	c.file, c.line = l.file, y.line
	name: string
	arg: ^Yaml
	switch y.kind {
	case .Scalar:
		name = y.text
		if !contains(STRING_COMMANDS, name) {
			if contains(MAESTRO_COMMANDS, name) {
				fail(l, y, "the command `%s` requires additional options", name)
			} else {
				fail(l, y, "`%s` is not a valid command", name)
			}
			return
		}
	case .Map:
		if len(y.keys) != 1 {
			fail(l, y, "a command is one `<command>: <options>` entry; found %d keys (missing an indent or a dash?)", len(y.keys))
			return
		}
		name, arg = y.keys[0], y.vals[0]
		if !contains(MAESTRO_COMMANDS, name) {
			fail(l, y, "`%s` is not a valid command", name)
			return
		}
		if arg.kind == .Null {
			fail(l, y, "the command `%s` requires additional options", name)
			return
		}
	case .Null, .Seq:
		fail(l, y, "invalid command: expected `<command>: <options>`, e.g. `tapOn: submit`")
		return
	}
	c.name = name
	switch name {
	case "launchApp":
		d := Launch_App {
			app_id   = l.app_id,
			stop_app = true,
		}
		if arg != nil && arg.kind == .Scalar {
			d.app_id = arg.text
		} else if arg != nil {
			fields(l, arg, name, {"appId", "url", "clearState", "clearKeychain", "stopApp", "permissions", "arguments", "label", "optional"}) or_return
			for key, i in arg.keys {
				v := arg.vals[i]
				switch key {
				case "appId", "url":
					d.app_id = str(l, v) or_return
				case "clearState":
					d.clear_state = boolean(l, v) or_return
				case "stopApp":
					d.stop_app = boolean(l, v) or_return
				case "clearKeychain":
					d.clear_keychain = boolean(l, v) or_return // iOS only; a no-op on Android, as in Maestro
				}
			}
			common(l, arg, &c) or_return
		}
		if arg != nil && arg.kind == .Map {
			for key in arg.keys do if key == "permissions" || key == "arguments" {
				fail(l, arg, "`launchApp.%s` is not supported yet", key)
				return
			}
		}
		c.data = d
	case "stopApp", "killApp", "clearState":
		d := App_Cmd {
			op     = .Stop if name == "stopApp" else .Kill if name == "killApp" else .Clear_State,
			app_id = l.app_id,
		}
		if arg != nil && arg.kind == .Scalar {
			d.app_id = arg.text
		} else if arg != nil {
			fields(l, arg, name, {"appId", "label", "optional"}) or_return
			if v := yaml_get(arg, "appId"); v != nil do d.app_id = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "tapOn", "doubleTapOn", "longPressOn":
		sel := selector(l, arg, true) or_return
		d := Tap {
			sel        = sel,
			long_press = name == "longPressOn",
			repeat     = 1,
			delay_ms   = 100, // TapOnElementCommand.DEFAULT_REPEAT_DELAY
			retry      = sel.retry_tap_if_no_change,
			settle_ms  = sel.wait_to_settle_timeout_ms,
		}
		if r, has := sel.repeat.?; has do d.repeat = max(r, 1)
		if dl, has := sel.delay.?; has && dl >= 0 do d.delay_ms = dl
		if name == "doubleTapOn" do d.repeat = 2
		if s, has := d.settle_ms.?; has do d.settle_ms = min(s, 30_000)
		if sel.point != "" {
			d.point = sel.point
			if !has_criteria(sel) do d.sel = nil
		}
		if arg.kind == .Map do common(l, arg, &c) or_return
		c.data = d
	case "assertVisible", "assertNotVisible":
		sel := selector(l, arg, false) or_return
		d: Assert
		if name == "assertVisible" {
			d.cond.visible = sel
		} else {
			d.cond.not_visible = sel
		}
		if arg.kind == .Map do common(l, arg, &c) or_return
		c.data = d
	case "extendedWaitUntil":
		fields(l, arg, name, {"visible", "notVisible", "timeout", "label", "optional"}) or_return
		d: Assert
		if v := yaml_get(arg, "visible"); v != nil do d.cond.visible = selector(l, v, false) or_return
		if v := yaml_get(arg, "notVisible"); v != nil do d.cond.not_visible = selector(l, v, false) or_return
		if d.cond.visible == nil && d.cond.not_visible == nil {
			fail(l, arg, "extendedWaitUntil expects either `visible` or `notVisible`")
			return
		}
		if v := yaml_get(arg, "timeout"); v != nil do d.timeout = str(l, v) or_return
		common(l, arg, &c) or_return
		c.data = d
	case "inputText":
		d: Input_Text
		if arg.kind == .Scalar {
			d.text = arg.text
		} else {
			fields(l, arg, name, {"text", "label", "optional"}) or_return
			if v := yaml_get(arg, "text"); v != nil do d.text = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "eraseText":
		d := Erase_Text {
			count = 50, // Orchestra.MAX_ERASE_CHARACTERS
		}
		if arg != nil && arg.kind == .Scalar {
			d.count = integer(l, arg) or_return
			d.explicit = true
		} else if arg != nil {
			fields(l, arg, name, {"charactersToErase", "label", "optional"}) or_return
			if v := yaml_get(arg, "charactersToErase"); v != nil {
				d.count = integer(l, v) or_return
				d.explicit = true
			}
			common(l, arg, &c) or_return
		}
		c.data = d
	case "pressKey":
		d: Key_Press
		if arg.kind == .Scalar {
			d.name = arg.text
		} else {
			fields(l, arg, name, {"key", "label", "optional"}) or_return
			if v := yaml_get(arg, "key"); v != nil do d.name = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		for k in KEYS do if strings.equal_fold(k.name, d.name) do d.keycode = k.code
		if d.keycode == 0 {
			fail(l, y, "unknown key name: %s", d.name)
			return
		}
		c.data = d
	case "back", "hideKeyboard", "hide keyboard", "scroll", "clearKeychain":
		if arg != nil {
			fields(l, arg, name, {"label", "optional"}) or_return
			common(l, arg, &c) or_return
		}
		switch name {
		case "back":           c.data = Navigate.Back
		case "scroll":         c.data = Navigate.Scroll
		case "clearKeychain":  c.data = Navigate.Clear_Keychain
		case:                  c.data = Navigate.Hide_Keyboard
		}
		if name == "hide keyboard" do c.name = "hideKeyboard"
	case "scrollUntilVisible":
		fields(l, arg, name, {"direction", "element", "timeout", "speed", "visibilityPercentage", "centerElement", "waitToSettleTimeoutMs", "label", "optional"}) or_return
		d := Scroll_Until {
			direction  = .Down,
			timeout    = "20000",
			speed      = "40",
			visibility = 100,
		}
		el := yaml_get(arg, "element")
		if el == nil {
			fail(l, arg, "scrollUntilVisible needs `element`")
			return
		}
		d.sel = selector(l, el, false) or_return
		if v := yaml_get(arg, "direction"); v != nil do d.direction = direction(l, v) or_return
		if v := yaml_get(arg, "timeout"); v != nil do d.timeout = str(l, v) or_return
		if v := yaml_get(arg, "speed"); v != nil do d.speed = str(l, v) or_return
		if v := yaml_get(arg, "visibilityPercentage"); v != nil do d.visibility = clamp(integer(l, v) or_return, 0, 100)
		if v := yaml_get(arg, "centerElement"); v != nil do d.center = boolean(l, v) or_return
		if v := yaml_get(arg, "waitToSettleTimeoutMs"); v != nil do d.settle_ms = integer(l, v) or_return
		common(l, arg, &c) or_return
		c.data = d
	case "swipe":
		fields(l, arg, name, {"direction", "start", "end", "from", "duration", "waitToSettleTimeoutMs", "label", "optional"}) or_return
		d := Swipe {
			duration = 400,
		}
		start, end, dir, from := yaml_get(arg, "start"), yaml_get(arg, "end"), yaml_get(arg, "direction"), yaml_get(arg, "from")
		switch {
		case start != nil || end != nil:
			if dir != nil || from != nil || start == nil || end == nil {
				fail(l, arg, "swipe takes `start` and `end`, or `direction` (optionally with `from`)")
				return
			}
			d.start = str(l, start) or_return
			d.end = str(l, end) or_return
			if strings.contains(d.start, "%") != strings.contains(d.end, "%") {
				fail(l, arg, "swipe `start` and `end` must both be percentages or both pixels")
				return
			}
		case dir != nil:
			d.direction = direction(l, dir) or_return
			if from != nil do d.from = selector(l, from, false) or_return
		case:
			fail(l, arg, "swipe takes `start` and `end`, or `direction`")
			return
		}
		if v := yaml_get(arg, "duration"); v != nil do d.duration = integer(l, v) or_return
		if v := yaml_get(arg, "waitToSettleTimeoutMs"); v != nil do d.settle_ms = integer(l, v) or_return
		common(l, arg, &c) or_return
		c.data = d
	case "waitForAnimationToEnd":
		d: Wait_Animation
		if arg != nil {
			fields(l, arg, name, {"timeout", "label", "optional"}) or_return
			if v := yaml_get(arg, "timeout"); v != nil do d.timeout = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "openLink":
		d: Open_Link
		if arg.kind == .Scalar {
			d.link = arg.text
		} else {
			fields(l, arg, name, {"link", "browser", "autoVerify", "label", "optional"}) or_return
			if v := yaml_get(arg, "link"); v != nil do d.link = str(l, v) or_return
			for key in ([]string{"browser", "autoVerify"}) {
				if v := yaml_get(arg, key); v != nil && (boolean(l, v) or_return) {
					fail(l, v, "`openLink.%s: true` is not supported yet", key)
					return
				}
			}
			common(l, arg, &c) or_return
		}
		c.data = d
	case "takeScreenshot":
		d: Screenshot
		if arg.kind == .Scalar {
			d.path = arg.text
		} else {
			fields(l, arg, name, {"path", "label", "optional"}) or_return
			if yaml_get(arg, "cropOn") != nil {
				fail(l, arg, "`takeScreenshot.cropOn` is not supported yet")
				return
			}
			if v := yaml_get(arg, "path"); v != nil do d.path = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "runFlow":
		d: Run_Flow
		if arg.kind == .Scalar {
			d.sub = sub_flow_file(l, arg, arg.text) or_return
		} else {
			fields(l, arg, name, {"file", "when", "env", "commands", "label", "optional"}) or_return
			d.sub = sub_flow(l, arg, name) or_return
			if v := yaml_get(arg, "when"); v != nil do d.cond = condition(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "repeat":
		fields(l, arg, name, {"times", "while", "commands", "label", "optional"}) or_return
		d: Repeat
		v := yaml_get(arg, "commands")
		if v == nil {
			fail(l, arg, "repeat needs `commands`")
			return
		}
		d.commands = commands(l, v) or_return
		if t := yaml_get(arg, "times"); t != nil do d.times = str(l, t) or_return
		if w := yaml_get(arg, "while"); w != nil do d.cond = condition(l, w) or_return
		common(l, arg, &c) or_return
		c.data = d
	case "retry":
		fields(l, arg, name, {"maxRetries", "file", "commands", "env", "label", "optional"}) or_return
		d := Retry {
			max_retries = "1",
		}
		d.sub = sub_flow(l, arg, name) or_return
		if v := yaml_get(arg, "maxRetries"); v != nil do d.max_retries = str(l, v) or_return
		common(l, arg, &c) or_return
		c.data = d
	case:
		fail(l, y, "`%s` is a Maestro command this runner does not support yet", name)
		return
	}
	return c, l.err == ""
}

// `file:` (relative to the current flow) or inline `commands:`, plus `env:`.
@(private = "file")
sub_flow :: proc(l: ^Loader, arg: ^Yaml, name: string) -> (s: Sub_Flow, ok: bool) {
	file, cmds := yaml_get(arg, "file"), yaml_get(arg, "commands")
	if (file == nil) == (cmds == nil) {
		fail(l, arg, "%s takes either `file` or `commands`", name)
		return
	}
	if file != nil {
		s = sub_flow_file(l, file, str(l, file) or_return) or_return
	} else {
		s.commands = commands(l, cmds) or_return
	}
	if v := yaml_get(arg, "env"); v != nil {
		// Maestro defines the caller's `env:` first, then the sub-flow file's own `env:`,
		// which therefore wins on the same name.
		env := env_map(l, v) or_return
		append(&env, ..s.env[:])
		s.env = env
	}
	return s, true
}

@(private = "file")
sub_flow_file :: proc(l: ^Loader, y: ^Yaml, rel: string) -> (s: Sub_Flow, ok: bool) {
	path, _ := filepath.join({filepath.dir(l.file), rel}, l.alloc)
	if path == l.file {
		fail(l, y, "a flow cannot run itself")
		return
	}
	saved_line := y.line
	l.depth += 1
	f, fok := load_flow_file(l, path, false)
	l.depth -= 1
	if !fok {
		if l.err_line == 0 do l.err_line = saved_line
		return
	}
	s.commands, s.on_start, s.on_complete, s.source = f.commands, f.on_start, f.on_complete, rel
	s.env = f.env
	return s, true
}

@(private = "file")
condition :: proc(l: ^Loader, y: ^Yaml) -> (c: Condition, ok: bool) {
	fields(l, y, "condition", {"platform", "visible", "notVisible", "true", "label", "optional"}) or_return
	if v := yaml_get(y, "platform"); v != nil do c.platform = str(l, v) or_return
	if v := yaml_get(y, "visible"); v != nil do c.visible = selector(l, v, false) or_return
	if v := yaml_get(y, "notVisible"); v != nil do c.not_visible = selector(l, v, false) or_return
	if v := yaml_get(y, "true"); v != nil do c.script = strings.trim_space(str(l, v) or_return)
	return c, true
}

SELECTOR_FIELDS :: []string {
	"text", "id", "width", "height", "tolerance", "optional", "retryTapIfNoChange",
	"waitUntilVisible", "point", "below", "above", "leftOf", "rightOf", "containsChild",
	"containsDescendants", "traits", "index", "enabled", "selected", "checked", "focused",
	"repeat", "delay", "waitToSettleTimeoutMs", "childOf", "label", "css",
}

// A string is a text regex; a map is Maestro's YamlElementSelector.
@(private = "file")
selector :: proc(l: ^Loader, y: ^Yaml, tap: bool) -> (s: ^Selector, ok: bool) {
	_ = tap
	s = new(Selector, l.alloc)
	switch y.kind {
	case .Scalar:
		s.text = y.text
		return s, true
	case .Map:
	case .Null, .Seq:
		fail(l, y, "expected a selector: text, or a map such as `{id: ..., index: ...}`")
		return
	}
	fields(l, y, "selector", SELECTOR_FIELDS) or_return
	for key, i in y.keys {
		v := y.vals[i]
		switch key {
		case "text":                  s.text = str(l, v) or_return
		case "id":                    s.id = str(l, v) or_return
		case "index":                 s.index = str(l, v) or_return
		case "enabled":               s.enabled = boolean(l, v) or_return
		case "selected":              s.selected = boolean(l, v) or_return
		case "checked":               s.checked = boolean(l, v) or_return
		case "focused":               s.focused = boolean(l, v) or_return
		case "width":                 s.width = integer(l, v) or_return
		case "height":                s.height = integer(l, v) or_return
		case "tolerance":             s.tolerance = integer(l, v) or_return
		case "below":                 s.below = selector(l, v, false) or_return
		case "above":                 s.above = selector(l, v, false) or_return
		case "leftOf":                s.left_of = selector(l, v, false) or_return
		case "rightOf":               s.right_of = selector(l, v, false) or_return
		case "containsChild":         s.contains_child = selector(l, v, false) or_return
		case "childOf":               s.child_of = selector(l, v, false) or_return
		case "point":                 s.point = str(l, v) or_return
		case "retryTapIfNoChange":    s.retry_tap_if_no_change = boolean(l, v) or_return
		case "repeat":                s.repeat = integer(l, v) or_return
		case "delay":                 s.delay = integer(l, v) or_return
		case "waitToSettleTimeoutMs": s.wait_to_settle_timeout_ms = integer(l, v) or_return
		case "containsDescendants":
			if v.kind != .Seq {
				fail(l, v, "`containsDescendants` takes a list of selectors")
				return
			}
			for item in v.items do append(&s.contains_descendants, selector(l, item, false) or_return)
		case "optional", "label":
		// read by common()
		case "waitUntilVisible":
			if boolean(l, v) or_return {
				fail(l, v, "`waitUntilVisible: true` is not supported yet")
				return
			}
		case "traits", "css":
			fail(l, v, "the `%s` selector is not supported yet", key)
			return
		}
	}
	// Outside tap commands Maestro accepts and ignores the tap-only fields; so do we.
	return s, true
}

has_criteria :: proc(s: ^Selector) -> bool {
	_, t := s.text.?
	_, i := s.id.?
	_, x := s.index.?
	_, e := s.enabled.?
	_, se := s.selected.?
	_, c := s.checked.?
	_, f := s.focused.?
	_, w := s.width.?
	_, h := s.height.?
	return t || i || x || e || se || c || f || w || h || s.below != nil || s.above != nil ||
		s.left_of != nil || s.right_of != nil || s.contains_child != nil || s.child_of != nil ||
		len(s.contains_descendants) > 0
}

@(private = "file")
common :: proc(l: ^Loader, y: ^Yaml, c: ^Cmd) -> bool {
	if v := yaml_get(y, "label"); v != nil do c.label = str(l, v) or_return
	if v := yaml_get(y, "optional"); v != nil do c.optional = boolean(l, v) or_return
	return true
}

@(private = "file")
fields :: proc(l: ^Loader, y: ^Yaml, what: string, allowed: []string) -> bool {
	if y.kind != .Map {
		fail(l, y, "`%s` expects a map of options", what)
		return false
	}
	for key, i in y.keys {
		if !contains(allowed, key) {
			fail(l, y.vals[i], "unknown field `%s` in %s", key, what)
			return false
		}
	}
	return true
}

@(private = "file")
env_map :: proc(l: ^Loader, y: ^Yaml) -> (env: [dynamic]Env_Pair, ok: bool) {
	if y.kind != .Map {
		fail(l, y, "`env` expects a map")
		return
	}
	for key, i in y.keys {
		v := y.vals[i]
		if v.kind == .Null {
			fail(l, v, "environment variable `%s` has no value (use \"\" for an empty string)", key)
			return
		}
		append(&env, Env_Pair{key, str(l, v) or_return})
	}
	return env, true
}

@(private = "file")
direction :: proc(l: ^Loader, y: ^Yaml) -> (d: Swipe_Dir, ok: bool) {
	s := str(l, y) or_return
	switch strings.to_upper(s, l.alloc) {
	case "UP":    return .Up, true
	case "DOWN":  return .Down, true
	case "LEFT":  return .Left, true
	case "RIGHT": return .Right, true
	}
	fail(l, y, "invalid direction `%s`: UP, DOWN, LEFT or RIGHT", s)
	return
}

@(private = "file")
str :: proc(l: ^Loader, y: ^Yaml) -> (string, bool) {
	if y.kind != .Scalar {
		fail(l, y, "expected a value")
		return "", false
	}
	return y.text, true
}

@(private = "file")
boolean :: proc(l: ^Loader, y: ^Yaml) -> (v: bool, ok: bool) {
	s := str(l, y) or_return
	if strings.equal_fold(s, "true") do return true, true
	if strings.equal_fold(s, "false") do return false, true
	fail(l, y, "expected true or false, found `%s`", s)
	return false, false
}

@(private = "file")
integer :: proc(l: ^Loader, y: ^Yaml) -> (n: int, ok: bool) {
	s := str(l, y) or_return
	v, parsed := strconv.parse_int(s, 10)
	if !parsed {
		fail(l, y, "expected a whole number, found `%s`", s)
		return 0, false
	}
	return v, true
}

@(private = "file")
contains :: proc(list: []string, s: string) -> bool {
	for x in list do if x == s do return true
	return false
}
