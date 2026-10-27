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
	wait_until_visible:                  bool,
	traits:                              [dynamic]Trait,
}

// ElementTrait.
Trait :: enum u8 {
	TEXT, // "Has text"
	SQUARE, // "Is square"
	LONG_TEXT, // "Has long text"
}

Condition :: struct {
	platform:             Maybe(string),
	visible, not_visible: ^Selector,
	script:               Maybe(string), // `true:`, after ${} substitution
	timeout:              Maybe(string), // ms a `visible`/`notVisible` waits (speedrun's own field)
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
	app_id:          string,
	clear_state:     bool,
	clear_keychain:  bool, // iOS only
	stop_app:        bool,
	permissions:     [dynamic]Env_Pair, // none given: Maestro's default, `all: allow`
	has_permissions: bool,
	arguments:       [dynamic]Launch_Arg,
	has_arguments:   bool, // `arguments:` given, even empty (it shows in the description)
}
// A launch argument with the type its YAML value has (Jackson's): an Android intent extra
// of that type, an iOS process argument.
Launch_Arg_Kind :: enum u8 {
	String,
	Bool,
	Int,
	Long,
	Double,
}
Launch_Arg :: struct {
	key, value: string,
	kind:       Launch_Arg_Kind,
}
Set_Permissions :: struct {
	app_id:      string,
	permissions: [dynamic]Env_Pair,
}
// InputRandomType, named as Maestro describes the command ("Input text random TEXT").
Random_Kind :: enum u8 {
	TEXT,
	NUMBER,
	TEXT_EMAIL_ADDRESS,
	TEXT_PERSON_NAME,
	TEXT_CITY_NAME,
	TEXT_COUNTRY_NAME,
	TEXT_COLOR,
}
Input_Random :: struct {
	kind:   Random_Kind,
	length: int, // TEXT and NUMBER; 8 when not given or not positive
}
Set_Orientation :: struct {
	orientation: string, // as written (may use ${}); resolved when run
}
Device_Mode_Op :: enum u8 {
	Airplane_On,
	Airplane_Off,
	Airplane_Toggle,
	Dark_On,
	Dark_Off,
	Dark_Toggle,
	Assert_Dark,
	Assert_Light,
}
Device_Mode :: struct {
	op: Device_Mode_Op,
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
	link:        string,
	auto_verify: bool,
	browser:     bool,
	app_id:      string, // the flow's: autoVerify picks it in Android's "Open with" dialog
}
Sub_Flow :: struct {
	commands:    [dynamic]Cmd,
	call_env:    [dynamic]Env_Pair, // the caller's `env:` (runFlow, retry), defined first
	env:         [dynamic]Env_Pair, // a file's own `env:`
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
	path:    string,
	crop_on: ^Selector,
}
Assert_Screenshot :: struct {
	path:      string, // as written; `.png` added unless it has an image extension
	threshold: string, // percentage of matching pixels needed
	crop_on:   ^Selector,
	dir:       string, // of the flow: the reference image is relative to it
}
Start_Recording :: struct {
	path: string, // `.mp4` added
}
Stop_Recording :: struct {}
Add_Media :: struct {
	files: [dynamic]string, // absolute, checked at load time
}
Set_Location :: struct {
	latitude, longitude: string,
}
Travel :: struct {
	points: [dynamic][2]f64, // latitude, longitude
	speed:  f64, // m/s
}
Eval_Script :: struct {
	script: string, // its ${...} run as JavaScript
}
Run_Script :: struct {
	file:   string, // as written
	dir:    string, // http multipart files resolve from it
	script: string, // the file's JavaScript, read at load time as Maestro does
	env:    [dynamic]Env_Pair,
	cond:   Maybe(Condition),
}
Copy_Text :: struct {
	sel: ^Selector,
}
Set_Clipboard :: struct {
	text: string,
}
Paste_Text :: struct {}

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
	Eval_Script,
	Run_Script,
	Copy_Text,
	Set_Clipboard,
	Paste_Text,
	Set_Permissions,
	Input_Random,
	Set_Orientation,
	Device_Mode,
	Assert_Screenshot,
	Start_Recording,
	Stop_Recording,
	Add_Media,
	Set_Location,
	Travel,
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

// A flow given as text (speedrun do): `path` names it and anchors runFlow's relative paths.
// On error, `err` and `line` (in `text`) name the problem.
load_flow_text :: proc(path, text: string, alloc: mem.Allocator) -> (flow: Flow, err: string, line: int) {
	l := Loader {
		alloc = alloc,
	}
	flow, _ = load_flow_file(&l, path, true, text)
	if l.err != "" do return flow, l.err, l.err_line
	return flow, "", 0
}

@(private = "file")
load_flow_file :: proc(l: ^Loader, path: string, top: bool, text: Maybe(string) = nil) -> (flow: Flow, ok: bool) {
	context.allocator = l.alloc
	saved_file := l.file
	defer if l.err == "" do l.file = saved_file
	l.file = path
	if l.depth > 20 {
		fail(l, nil, "runFlow nested more than 20 levels deep (a cycle?)")
		return
	}
	append(&l.files, path)
	data, given := text.?
	if !given {
		bytes, rerr := os.read_entire_file(path, l.alloc)
		if rerr != nil {
			fail(l, nil, "cannot read flow file: %v", rerr)
			return
		}
		data = string(bytes)
	}
	docs, yerr, yline := yaml_parse(data, l.alloc)
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
				case "permissions":
					d.permissions = permissions(l, v) or_return
					d.has_permissions = true
				case "arguments":
					d.arguments = launch_arguments(l, v) or_return
					d.has_arguments = true
				}
			}
			common(l, arg, &c) or_return
		}
		c.data = d
	case "setPermissions":
		fields(l, arg, name, {"appId", "url", "permissions", "label", "optional"}) or_return
		d := Set_Permissions {
			app_id = l.app_id,
		}
		for key, i in arg.keys do if key == "appId" || key == "url" do d.app_id = str(l, arg.vals[i]) or_return
		v := yaml_get(arg, "permissions")
		if v == nil {
			fail(l, arg, "setPermissions needs `permissions`")
			return
		}
		d.permissions = permissions(l, v) or_return
		common(l, arg, &c) or_return
		c.data = d
	case "inputRandomText", "inputRandomNumber", "inputRandomEmail", "inputRandomPersonName",
	     "inputRandomCityName", "inputRandomCountryName", "inputRandomColorName":
		d := Input_Random {
			length = 8,
		}
		switch name {
		case "inputRandomText":        d.kind = .TEXT
		case "inputRandomNumber":      d.kind = .NUMBER
		case "inputRandomEmail":       d.kind = .TEXT_EMAIL_ADDRESS
		case "inputRandomPersonName":  d.kind = .TEXT_PERSON_NAME
		case "inputRandomCityName":    d.kind = .TEXT_CITY_NAME
		case "inputRandomCountryName": d.kind = .TEXT_COUNTRY_NAME
		case "inputRandomColorName":   d.kind = .TEXT_COLOR
		}
		if arg != nil {
			has_length := d.kind == .TEXT || d.kind == .NUMBER
			fields(l, arg, name, {"length", "label", "optional"} if has_length else {"label", "optional"}) or_return
			if v := yaml_get(arg, "length"); v != nil {
				n := integer(l, v) or_return
				if n > 0 do d.length = n // InputRandomCommand: 8 unless positive
			}
			common(l, arg, &c) or_return
		}
		if d.kind == .NUMBER && d.length > 18 {
			fail(l, arg, "inputRandomNumber: `length` can be at most 18")
			return
		}
		c.data = d
	case "setOrientation":
		d: Set_Orientation
		if arg.kind == .Scalar {
			d.orientation = arg.text
		} else {
			fields(l, arg, name, {"orientation", "label", "optional"}) or_return
			v := yaml_get(arg, "orientation")
			if v == nil {
				fail(l, arg, "Missing required field 'orientation' in SetOrientation action")
				return
			}
			d.orientation = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		// Checked here unless a script computes it (YamlSetOrientationDeserializer).
		if !strings.contains(d.orientation, "${") {
			if _, known := orientation_by_name(d.orientation); !known {
				fail(l, arg, "%s", unknown_orientation(d.orientation, l.alloc))
				return
			}
		}
		c.data = d
	case "setAirplaneMode", "setDarkMode":
		airplane := name == "setAirplaneMode"
		v := arg
		if arg.kind == .Map {
			fields(l, arg, name, {"value", "label", "optional"}) or_return
			v = yaml_get(arg, "value")
			common(l, arg, &c) or_return
		}
		value := v.text if v != nil && v.kind == .Scalar else ""
		if value != "enabled" && value != "disabled" {
			if airplane {
				fail(l, arg, "setAirplaneMode command takes either: enabled, disabled, or `value: enabled|disabled`; found `%s`", value)
			} else {
				fail(l, arg, "setDarkMode command takes either: enabled, disabled, or `value: enabled|disabled`; found `%s`", value)
			}
			return
		}
		on := value == "enabled"
		if airplane {
			c.data = Device_Mode{.Airplane_On if on else .Airplane_Off}
		} else {
			c.data = Device_Mode{.Dark_On if on else .Dark_Off}
		}
	case "toggleAirplaneMode", "toggleDarkMode", "assertDarkMode", "assertLightMode":
		if arg != nil {
			fields(l, arg, name, {"label", "optional"}) or_return
			common(l, arg, &c) or_return
		}
		switch name {
		case "toggleAirplaneMode": c.data = Device_Mode{.Airplane_Toggle}
		case "toggleDarkMode":     c.data = Device_Mode{.Dark_Toggle}
		case "assertDarkMode":     c.data = Device_Mode{.Assert_Dark}
		case "assertLightMode":    c.data = Device_Mode{.Assert_Light}
		}
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
		d := Open_Link{app_id = l.app_id}
		if arg.kind == .Scalar {
			d.link = arg.text
		} else {
			fields(l, arg, name, {"link", "browser", "autoVerify", "label", "optional"}) or_return
			if v := yaml_get(arg, "link"); v != nil do d.link = str(l, v) or_return
			if v := yaml_get(arg, "browser"); v != nil do d.browser = boolean(l, v) or_return
			if v := yaml_get(arg, "autoVerify"); v != nil do d.auto_verify = boolean(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "takeScreenshot":
		d: Screenshot
		if arg.kind == .Scalar {
			d.path = arg.text
		} else {
			fields(l, arg, name, {"path", "cropOn", "label", "optional"}) or_return
			if v := yaml_get(arg, "path"); v != nil do d.path = str(l, v) or_return
			if v := yaml_get(arg, "cropOn"); v != nil do d.crop_on = selector(l, v, false) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "assertScreenshot":
		d := Assert_Screenshot {
			threshold = "95", // YamlAssertScreenshot's default
			dir       = filepath.dir(l.file),
		}
		if arg.kind == .Scalar {
			d.path = arg.text
		} else {
			fields(l, arg, name, {"path", "thresholdPercentage", "cropOn", "label", "optional"}) or_return
			v := yaml_get(arg, "path")
			if v == nil {
				fail(l, arg, "assertScreenshot needs `path`")
				return
			}
			d.path = str(l, v) or_return
			if t := yaml_get(arg, "thresholdPercentage"); t != nil do d.threshold = str(l, t) or_return
			if cv := yaml_get(arg, "cropOn"); cv != nil do d.crop_on = selector(l, cv, false) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "startRecording":
		d: Start_Recording
		if arg.kind == .Scalar {
			d.path = arg.text
		} else {
			fields(l, arg, name, {"path", "label", "optional"}) or_return
			v := yaml_get(arg, "path")
			if v == nil {
				fail(l, arg, "startRecording needs `path`")
				return
			}
			d.path = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "stopRecording":
		if arg != nil {
			fields(l, arg, name, {"label", "optional"}) or_return
			common(l, arg, &c) or_return
		}
		c.data = Stop_Recording{}
	case "addMedia":
		d: Add_Media
		list := arg
		if arg.kind == .Map {
			fields(l, arg, name, {"files", "label", "optional"}) or_return
			list = yaml_get(arg, "files")
			common(l, arg, &c) or_return
		}
		if list == nil || list.kind != .Seq || len(list.items) == 0 {
			fail(l, arg, "Invalid addMedia command: media files cannot be empty")
			return
		}
		for item in list.items {
			rel := str(l, item) or_return
			path := rel
			if !filepath.is_abs(path) do path, _ = filepath.join({filepath.dir(l.file), rel}, l.alloc)
			if !os.exists(path) {
				fail(l, item, "Media file at %s in flow file: %s not found", rel, l.file)
				return
			}
			append(&d.files, path)
		}
		c.data = d
	case "setLocation":
		fields(l, arg, name, {"latitude", "longitude", "label", "optional"}) or_return
		lat, lon := yaml_get(arg, "latitude"), yaml_get(arg, "longitude")
		if lat == nil || lon == nil {
			fail(l, arg, "setLocation needs `latitude` and `longitude`")
			return
		}
		c.data = Set_Location{str(l, lat) or_return, str(l, lon) or_return}
		common(l, arg, &c) or_return
	case "travel":
		fields(l, arg, name, {"points", "speed", "label", "optional"}) or_return
		d := Travel {
			speed = 4, // m/s (Orchestra.travelCommand)
		}
		v := yaml_get(arg, "points")
		if v == nil || v.kind != .Seq {
			fail(l, arg, "travel needs `points`, a list of \"latitude, longitude\"")
			return
		}
		for item in v.items {
			point := str(l, item) or_return
			lat_s, comma, lon_s := strings.partition(point, ",")
			if comma == "" || strings.contains(lon_s, ",") {
				fail(l, item, "Invalid travel point: %s", point)
				return
			}
			lat, lat_ok := strconv.parse_f64(strings.trim_space(lat_s))
			if !lat_ok {
				fail(l, item, "Invalid travel point latitude: %s", point)
				return
			}
			lon, lon_ok := strconv.parse_f64(strings.trim_space(lon_s))
			if !lon_ok {
				fail(l, item, "Invalid travel point longitude: %s", point)
				return
			}
			append(&d.points, [2]f64{lat, lon})
		}
		if sp := yaml_get(arg, "speed"); sp != nil {
			text := str(l, sp) or_return
			speed, ok := strconv.parse_f64(text)
			if !ok {
				fail(l, sp, "travel: `speed` must be a number (m/s), found `%s`", text)
				return
			}
			d.speed = speed
		}
		common(l, arg, &c) or_return
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
	case "evalScript":
		d: Eval_Script
		if arg.kind == .Scalar {
			d.script = arg.text
		} else {
			fields(l, arg, name, {"script", "label", "optional"}) or_return
			if v := yaml_get(arg, "script"); v != nil do d.script = str(l, v) or_return
			// YamlEvalScript's map form reads `script` and `label` only: `optional` is ignored.
			if v := yaml_get(arg, "label"); v != nil do c.label = str(l, v) or_return
		}
		c.data = d
	case "runScript":
		d: Run_Script
		if arg.kind == .Scalar {
			d.file = arg.text
		} else {
			fields(l, arg, name, {"file", "env", "when", "label", "optional"}) or_return
			v := yaml_get(arg, "file")
			if v == nil {
				fail(l, arg, "runScript needs `file`")
				return
			}
			d.file = str(l, v) or_return
			if e := yaml_get(arg, "env"); e != nil do d.env = env_map(l, e) or_return
			if w := yaml_get(arg, "when"); w != nil do d.cond = condition(l, w) or_return
			common(l, arg, &c) or_return
		}
		path := d.file
		if !filepath.is_abs(path) do path, _ = filepath.join({filepath.dir(l.file), d.file}, l.alloc)
		data, rerr := os.read_entire_file(path, l.alloc)
		if rerr != nil {
			fail(l, arg, "Script file does not exist: %s", path)
			return
		}
		append(&l.files, path)
		d.script, d.dir = string(data), filepath.dir(path)
		c.data = d
	case "assertTrue":
		d: Assert
		cond: string
		if arg.kind == .Scalar {
			cond = arg.text
		} else {
			fields(l, arg, name, {"condition", "label", "optional"}) or_return
			if v := yaml_get(arg, "condition"); v != nil do cond = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		d.cond.script = cond
		c.data = d
	case "copyTextFrom":
		d := Copy_Text {
			sel = selector(l, arg, false) or_return,
		}
		if arg.kind == .Map do common(l, arg, &c) or_return
		c.data = d
	case "setClipboard":
		d: Set_Clipboard
		if arg.kind == .Scalar {
			d.text = arg.text
		} else {
			fields(l, arg, name, {"text", "label", "optional"}) or_return
			v := yaml_get(arg, "text")
			if v == nil {
				fail(l, arg, "setClipboard needs `text`")
				return
			}
			d.text = str(l, v) or_return
			common(l, arg, &c) or_return
		}
		c.data = d
	case "action":
		// The legacy spelling of five commands: `action: back` is `- back`.
		word := str(l, arg) or_return
		switch word {
		case "back":          c.data = Navigate.Back
		case "hideKeyboard":  c.data = Navigate.Hide_Keyboard
		case "scroll":        c.data = Navigate.Scroll
		case "clearKeychain": c.data = Navigate.Clear_Keychain
		case "pasteText":     c.data = Paste_Text{}
		case:
			fail(l, arg, "Unknown navigation target: %s", word)
			return
		}
		c.name = word
	case "pasteText":
		if arg != nil {
			fields(l, arg, name, {"label", "optional"}) or_return
			common(l, arg, &c) or_return
		}
		c.data = Paste_Text{}
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
	// Maestro defines the caller's `env:` first, then the sub-flow file's own `env:`,
	// which therefore wins on the same name and sees the caller's values.
	if v := yaml_get(arg, "env"); v != nil do s.call_env = env_map(l, v) or_return
	return s, true
}

@(private = "file")
sub_flow_file :: proc(l: ^Loader, y: ^Yaml, rel: string) -> (s: Sub_Flow, ok: bool) {
	path := rel // an absolute path is taken as is (Path.resolve)
	if !filepath.is_abs(rel) do path, _ = filepath.join({filepath.dir(l.file), rel}, l.alloc)
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
	// `timeout` is speedrun's: Maestro has none (its conditions wait a fixed 7 s).
	fields(l, y, "condition", {"platform", "visible", "notVisible", "true", "timeout", "label", "optional"}) or_return
	if v := yaml_get(y, "platform"); v != nil do c.platform = str(l, v) or_return
	if v := yaml_get(y, "visible"); v != nil do c.visible = selector(l, v, false) or_return
	if v := yaml_get(y, "notVisible"); v != nil do c.not_visible = selector(l, v, false) or_return
	if v := yaml_get(y, "true"); v != nil do c.script = strings.trim_space(str(l, v) or_return)
	if v := yaml_get(y, "timeout"); v != nil do c.timeout = str(l, v) or_return
	return c, true
}

// `permissions:` of launchApp and setPermissions: names (`all`, `camera`, an Android
// permission...) to allow, deny or unset (iOS location: always, inuse, never).
@(private = "file")
permissions :: proc(l: ^Loader, y: ^Yaml) -> (list: [dynamic]Env_Pair, ok: bool) {
	if y.kind != .Map {
		fail(l, y, "`permissions` expects a map, e.g. `{all: deny, camera: allow}`")
		return
	}
	for key, i in y.keys do append(&list, Env_Pair{key, str(l, y.vals[i]) or_return})
	return list, true
}

// launchApp's `arguments:`, each with the type its value reads as (true/false, a whole
// number, a decimal number, else a string; quoted values are strings).
@(private = "file")
launch_arguments :: proc(l: ^Loader, y: ^Yaml) -> (list: [dynamic]Launch_Arg, ok: bool) {
	if y.kind != .Map {
		fail(l, y, "`arguments` expects a map")
		return
	}
	for key, i in y.keys {
		v := y.vals[i]
		if v.kind != .Scalar {
			fail(l, v, "launch argument `%s` needs a value: text, a number or true/false", key)
			return
		}
		a := Launch_Arg {
			key   = key,
			value = v.text,
		}
		if !v.quoted {
			switch {
			case v.text == "true" || v.text == "True" || v.text == "TRUE":
				a.kind, a.value = .Bool, "true"
			case v.text == "false" || v.text == "False" || v.text == "FALSE":
				a.kind, a.value = .Bool, "false"
			case:
				if n, is_int := strconv.parse_i64(v.text, 10); is_int {
					a.kind = .Int if n >= i64(min(i32)) && n <= i64(max(i32)) else .Long
					a.value = fmt.aprintf("%d", n, allocator = l.alloc)
				} else if is_decimal(v.text) {
					f, _ := strconv.parse_f64(v.text)
					a.kind, a.value = .Double, kotlin_double(f, l.alloc)
				}
			}
		}
		append(&list, a)
	}
	return list, true
}

// A YAML float as Jackson reads one: digits with a point or an exponent.
@(private = "file")
is_decimal :: proc(s: string) -> bool {
	t := strings.trim_left(s, "+-")
	if t == "" do return false
	digits, point, exp := 0, false, false
	for c, i in t {
		switch {
		case c >= '0' && c <= '9':
			digits += 1
		case c == '.' && !point && !exp:
			point = true
		case (c == 'e' || c == 'E') && !exp && digits > 0:
			exp = true
			if i + 1 < len(t) && (t[i + 1] == '+' || t[i + 1] == '-') do continue
		case (c == '+' || c == '-') && exp && (t[i - 1] == 'e' || t[i - 1] == 'E'):
		case:
			return false
		}
	}
	return digits > 0 && (point || exp)
}

// Kotlin's Double.toString for the description: 1.5, 2.0, 1.0E10.
kotlin_double :: proc(f: f64, alloc: mem.Allocator) -> string {
	a := f < 0 ? -f : f
	if a != 0 && (a >= 1e7 || a < 1e-3) {
		s := fmt.aprintf("%E", f, allocator = context.temp_allocator) // 1.000000E+10
		mant, _, ex := strings.partition(s, "E")
		mant = strings.trim_right(mant, "0")
		if strings.has_suffix(mant, ".") do mant = strings.concatenate({mant, "0"}, context.temp_allocator)
		e, _ := strconv.parse_int(ex)
		return fmt.aprintf("%sE%d", mant, e, allocator = alloc)
	}
	s := strconv.write_float(make([]byte, 32, context.temp_allocator), f, 'f', -1, 64)
	if s[0] == '+' do s = s[1:]
	if !strings.contains(s, ".") do s = strings.concatenate({s, ".0"}, context.temp_allocator)
	return strings.clone(s, alloc)
}

// DeviceOrientation.getByName: case and underscores ignored ("landscapeLeft", "LANDSCAPE_LEFT").
ORIENTATIONS :: []string{"PORTRAIT", "LANDSCAPE_LEFT", "LANDSCAPE_RIGHT", "UPSIDE_DOWN"}

orientation_by_name :: proc(name: string) -> (canonical: string, ok: bool) {
	want, _ := strings.remove_all(strings.to_lower(name, context.temp_allocator), "_", context.temp_allocator)
	for o in ORIENTATIONS {
		have, _ := strings.remove_all(strings.to_lower(o, context.temp_allocator), "_", context.temp_allocator)
		if have == want do return o, true
	}
	return "", false
}

unknown_orientation :: proc(name: string, alloc: mem.Allocator) -> string {
	return fmt.aprintf(
		"Unknown orientation: %s. Valid orientations are: [PORTRAIT, LANDSCAPE_LEFT, LANDSCAPE_RIGHT, UPSIDE_DOWN] \n(case insensitive, underscores optional, e.g 'landscape_left', 'landscapeLeft', and 'LANDSCAPE_LEFT' are all valid)",
		name, allocator = alloc)
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
		case "waitUntilVisible":      s.wait_until_visible = boolean(l, v) or_return
		case "traits":
			// Names separated by spaces (`traits: text square`), `-` for `_`, any case.
			text := str(l, v) or_return
			for t in strings.split(text, " ", l.alloc) {
				name, _ := strings.replace_all(strings.to_upper(t, l.alloc), "-", "_", l.alloc)
				switch name {
				case "TEXT":      append(&s.traits, Trait.TEXT)
				case "SQUARE":    append(&s.traits, Trait.SQUARE)
				case "LONG_TEXT": append(&s.traits, Trait.LONG_TEXT)
				case:
					fail(l, v, "unknown trait `%s`: text, square or long-text", t)
					return
				}
			}
		case "css":
			fail(l, v, "the `css` selector is for web flows, which are not supported")
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
		len(s.contains_descendants) > 0 || len(s.traits) > 0
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
