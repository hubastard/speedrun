// Runs Maestro flow files (see flow.odin) on the agent, with Maestro 2.11.0's semantics:
// element matching (Orchestra.buildFilter, maestro.Filters), lookup timeouts counted from the
// last interaction, conditions, env scopes, gestures and key codes (drivers/AndroidDriver).
// What differs is how: one agent round trip per hierarchy read and frame/event-driven settle
// instead of fixed sleeps and screenshot diffs.
package speedrun

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:time"

LOOKUP_TIMEOUT_MS          :: 17_000 // Orchestra.lookupTimeoutMs
OPTIONAL_LOOKUP_TIMEOUT_MS :: 7_000 // Orchestra.optionalLookupTimeoutMs
ANIMATION_TIMEOUT_MS       :: 15_000 // Maestro.ANIMATION_TIMEOUT_MS
MAX_RETRIES_ALLOWED        :: 3 // Orchestra.MAX_RETRIES_ALLOWED
LONG_PRESS_MS              :: 3_000 // AndroidDriver.longPress: `input swipe x y x y 3000`
GBOARD_ID                  :: "com.google.android.inputmethod.latin:id" // AndroidDriver.isKeyboardVisible

// ---- hierarchy ------------------------------------------------------------------------

H_Node :: struct {
	using node: Node,
	parent:     int,
	children:   [dynamic]int, // kept children only (after the bounds filter)
	kept:       bool,
}

// Maestro's view of the screen: every window, nodes the system reports visible, minus
// those less than 10% on screen (filterOutOfBounds).
Hierarchy :: struct {
	nodes: [dynamic]H_Node,
	roots: [dynamic]int,
	order: [dynamic]int, // aggregate(): pre-order of kept nodes
	hash:  u64, // for retryTapIfNoChange
}

Record :: struct {
	seq:         int `json:"seq"`,
	path:        string `json:"path"`, // position in the flow: repeat iterations share it
	depth:       int `json:"depth"`,
	command:     string `json:"command"`,
	description: string `json:"description"`,
	status:      string `json:"status"`,
	duration_ms: f64 `json:"duration_ms"`,
	error:       string `json:"error,omitempty"`,
	start_ms:    i64 `json:"start_ms"`, // Unix time
	logs:        [dynamic]string `json:"logs,omitempty"`, // console.log lines of its scripts
	evaluated:   string `json:"evaluated,omitempty"`, // description with its ${...} values
}

Runner :: struct {
	c:                    ^Conn,
	dev:                  ^Device, // platform, simulator (iOS app control goes through simctl)
	alloc:                mem.Allocator, // the run's lifetime
	screen_arena:         virtual.Arena, // strings of the latest hierarchy read
	h:                    Hierarchy,
	w, h_px:              i32, // display size (DeviceInfo.widthGrid/heightGrid)
	env:                  [dynamic]map[string]string, // scopes, innermost last
	last_interaction:     time.Tick,
	regexes:              map[string]Rx,
	launchers:            map[string]string,
	records:              [dynamic]Record,
	depth:                int,
	path:                 string, // of the command being run
	debug:                bool, // SPEEDRUN_DEBUG: print every hierarchy read and shell command
	view:                 View, // console output (console.odin)
	reads, read_ms_total: f64,
	// JavaScript (js.odin)
	js:                   ^Js, // started on the first script
	env_gen, js_env_gen:  int, // env changes; the last one the engine has
	evals:                [dynamic]map[string]string, // ${...} values of each running command
	log_rec:              int, // record of the running command, for console.log (-1: none)
	log_node:             ^View_Node,
	script_dir:           string, // of the running runScript
	copied_text:          Maybe(string), // maestro.copiedText
	http_seq:             int,
	api_level:            int, // Android, read when needed (system.odin)
	flow_dir:             string, // this flow's debug output folder ("" for none)
	recording:            Recording, // startRecording's, until stopRecording or the end
	location:             Location_Mock, // Android's mock location (setLocation, travel)
	notifications:        string, // iOS: "allow" or "deny" answers the notification alert (system.odin)
}

Rx :: struct {
	pattern: string,
	re:      regex.Regular_Expression,
	literal: bool, // does not compile: matched as plain text, like Maestro's toRegexSafe
}

// A failure message; nil means success.
Err :: Maybe(string)

SKIPPED :: "\x00skipped" // a command whose condition was false
SUB_FLOW_FAILED :: "a command in the sub-flow failed"

// ---- entry ----------------------------------------------------------------------------

// Loads and runs `path`; `env` holds `-e KEY=VALUE` pairs. Writes per-command timings as
// JSON to `timings_path` if set. `plain`: one line per command even on a terminal.
// Returns false if the flow failed.
Flow_Result :: struct {
	name, file_path: string, // name: the flow's `name`, else its file name
	passed:          bool,
	error:           string, // the failing command's message
	duration_ms:     f64,
	start_unix_ms:   i64,
	tags:            []string,
	properties:      []Env_Pair,
	steps:           []Step, // every command, for --format html-detailed
}

Step :: struct {
	description, status, duration: string,
}

Run_Options :: struct {
	env:          []Env_Pair, // -e values
	device_id:    string, // MAESTRO_DEVICE_UDID
	shard_index:  int, // MAESTRO_SHARD_INDEX (0 when not sharded)
	timings_path: string, // --timings: this tool's per-command record
	plain:        bool, // one line per command instead of the live view
	silent:       bool, // a flow of a suite: no per-command output
	flow_dir:     string, // debug output folder of this flow ("" for none)
}

// Runs one flow file. The result's strings live in `alloc`.
run_maestro_flow :: proc(c: ^Conn, dev: ^Device, path: string, opts: Run_Options, alloc: mem.Allocator) -> (result: Flow_Result) {
	result.file_path = strings.clone(path, alloc)
	result.name = strings.clone(flow_file_name(path), alloc)
	result.start_unix_ms = time.to_unix_nanoseconds(time.now()) / 1_000_000
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	run_alloc := virtual.arena_allocator(&arena)
	context.allocator = run_alloc

	flow, err := load_flow(path, run_alloc)
	if err != "" {
		if !opts.silent do fmt.eprintln(err)
		result.error = strings.clone(err, alloc)
		return
	}
	if flow.name != "" do result.name = strings.clone(flow.name, alloc)
	result.tags = make([]string, len(flow.tags), alloc)
	for t, k in flow.tags do result.tags[k] = strings.clone(t, alloc)
	result.properties = make([]Env_Pair, len(flow.properties), alloc)
	for p, k in flow.properties do result.properties[k] = {strings.clone(p.key, alloc), strings.clone(p.value, alloc)}

	r := Runner {
		c       = c,
		dev     = dev,
		alloc   = run_alloc,
		debug   = os.get_env("SPEEDRUN_DEBUG", run_alloc) != "",
		env_gen  = 1,
		log_rec  = -1,
		flow_dir = opts.flow_dir,
	}
	_ = virtual.arena_init_growing(&r.screen_arena)
	defer virtual.arena_destroy(&r.screen_arena)
	defer js_stop(&r)
	defer location_stop_updates(&r)
	// A recording still running when the flow ends is stopped and kept.
	defer if r.recording.active do _ = stop_recording(&r)

	// The first read gives the display size (read_screen).
	if !read_screen(&r) {
		if !opts.silent do fmt.eprintln("could not read the screen")
		result.error = strings.clone("could not read the screen", alloc)
		return
	}

	// Env, Maestro's order: -e values, MAESTRO_* shell variables not given with -e, the
	// defaults it sets for every flow, then the flow's own `env:` (define_env, below).
	push_scope(&r)
	scope := &r.env[0]
	for e in opts.env do scope[e.key] = e.value
	environ, _ := os.environ(run_alloc)
	for e in environ {
		k, _, v := strings.partition(e, "=")
		if strings.has_prefix(k, "MAESTRO_") && v != "" && k not_in scope do scope[k] = v
	}
	scope["MAESTRO_FILENAME"] = flow_file_name(path)
	if opts.device_id != "" do scope["MAESTRO_DEVICE_UDID"] = opts.device_id
	scope["MAESTRO_SHARD_ID"] = fmt.aprintf("%d", opts.shard_index + 1)
	scope["MAESTRO_SHARD_INDEX"] = fmt.aprintf("%d", opts.shard_index)

	// "Running on <emulator or simulator name>", like Maestro.
	device := dev.name
	if dev.platform == .Android {
		device = strings.trim_space(shell(&r, "getprop ro.boot.qemu.avd_name"))
		if device == "" do device = strings.trim_space(shell(&r, "getprop ro.product.model"))
	}
	view_init(&r, &flow, flow.name if flow.name != "" else flow_file_name(path), device, opts.plain || r.debug, opts.silent)

	start := time.tick_now()
	r.last_interaction = start
	ok := true
	if e, bad := define_env(&r, flow.env[:]).?; bad {
		if !opts.silent do fmt.eprintln(e)
		result.error = strings.clone(e, alloc)
		ok = false
	}
	if ok && len(flow.on_start) > 0 do ok = run_list(&r, flow.on_start[:], "s")
	if ok do ok = run_list(&r, flow.commands[:])
	if len(flow.on_complete) > 0 do ok = run_list(&r, flow.on_complete[:], "c") && ok
	total := us(start) / 1000
	result.passed = ok
	result.duration_ms = total
	result.steps = make([]Step, len(r.records), alloc)
	for rec, k in r.records {
		// TestSuiteInteractor: "N. <description>", "850ms" / "1.2s".
		d := fmt.tprintf("%.1fs", rec.duration_ms / 1000) if rec.duration_ms >= 1000 else fmt.tprintf("%dms", int(rec.duration_ms))
		result.steps[k] = {
			fmt.aprintf("%d. %s", k + 1, rec.evaluated if rec.evaluated != "" else rec.description, allocator = alloc),
			strings.clone(rec.status, alloc),
			strings.clone(d, alloc),
		}
	}
	// Maestro's message only: the lines after it describe the screen, for the console.
	if !ok && result.error == "" {
		first, _, _ := strings.partition(failure_message(&r), "\n")
		result.error = strings.clone(first, alloc)
	}

	view_done(&r, fmt.tprintf(
		"%s in %s · %d commands · %d hierarchy reads, %.1f ms each",
		"✅ Flow passed" if ok else "❌ Flow failed", fmt_ms(total), len(r.records), int(r.reads),
		r.read_ms_total / max(r.reads, 1),
	))
	if opts.timings_path != "" {
		data, merr := json.marshal(r.records[:], {pretty = true}, run_alloc)
		if merr != nil || !write_file(opts.timings_path, data) do fmt.eprintln("could not write", opts.timings_path)
	}
	if opts.flow_dir != "" do write_flow_artifacts(&r, opts.flow_dir, ok)
	return
}

// Maestro's names for the commands in its commands.json (the YAML name is `description`'s
// source; tapOn with a point is tapOnPointV2Command in Maestro, tapOnElement here).
@(private = "file")
MAESTRO_COMMAND_NAMES :: [][2]string {
	{"tapOn", "tapOnElement"}, {"doubleTapOn", "tapOnElement"}, {"longPressOn", "tapOnElement"},
	{"assertVisible", "assertConditionCommand"}, {"assertNotVisible", "assertConditionCommand"},
	{"extendedWaitUntil", "assertConditionCommand"}, {"back", "backPressCommand"},
	{"hideKeyboard", "hideKeyboardCommand"}, {"hide keyboard", "hideKeyboardCommand"},
	{"inputText", "inputTextCommand"}, {"eraseText", "eraseTextCommand"}, {"pressKey", "pressKeyCommand"},
	{"scroll", "scrollCommand"}, {"scrollUntilVisible", "scrollUntilVisible"}, {"swipe", "swipeCommand"},
	{"waitForAnimationToEnd", "waitForAnimationToEndCommand"}, {"openLink", "openLinkCommand"},
	{"launchApp", "launchAppCommand"}, {"stopApp", "stopAppCommand"}, {"killApp", "killAppCommand"},
	{"clearState", "clearStateCommand"}, {"clearKeychain", "clearKeychainCommand"},
	{"runFlow", "runFlowCommand"}, {"repeat", "repeatCommand"}, {"retry", "retryCommand"},
	{"takeScreenshot", "takeScreenshotCommand"}, {"evalScript", "evalScriptCommand"},
	{"runScript", "runScriptCommand"}, {"assertTrue", "assertConditionCommand"},
	{"copyTextFrom", "copyTextCommand"}, {"setClipboard", "setClipboardCommand"},
	{"pasteText", "pasteTextCommand"}, {"setPermissions", "setPermissionsCommand"},
	{"inputRandomText", "inputRandomTextCommand"}, {"inputRandomNumber", "inputRandomTextCommand"},
	{"inputRandomEmail", "inputRandomTextCommand"}, {"inputRandomPersonName", "inputRandomTextCommand"},
	{"inputRandomCityName", "inputRandomTextCommand"}, {"inputRandomCountryName", "inputRandomTextCommand"},
	{"inputRandomColorName", "inputRandomTextCommand"}, {"setOrientation", "setOrientationCommand"},
	{"setAirplaneMode", "setAirplaneModeCommand"}, {"toggleAirplaneMode", "toggleAirplaneModeCommand"},
	{"setDarkMode", "setDarkModeCommand"}, {"toggleDarkMode", "toggleDarkModeCommand"},
	{"assertDarkMode", "assertDarkModeCommand"}, {"assertLightMode", "assertLightModeCommand"},
	{"assertScreenshot", "assertScreenshotCommand"}, {"startRecording", "startRecordingCommand"},
	{"stopRecording", "stopRecordingCommand"}, {"addMedia", "addMediaCommand"},
	{"setLocation", "setLocationCommand"}, {"travel", "travelCommand"},
}

// The flow's debug output, laid out as Maestro's artifacts bundle: commands.json (each
// command under Maestro's name, with its status, start and duration), logs/maestro.log, and
// on failure screenshots/final.png.
@(private = "file")
write_flow_artifacts :: proc(r: ^Runner, dir: string, passed: bool) {
	if os.make_directory_all(fmt.tprintf("%s/logs", dir)) != nil {
		fmt.eprintln("could not create", dir)
		return
	}
	Meta :: struct {
		status:         string `json:"status"`,
		timestamp:      i64 `json:"timestamp"`,
		duration:       i64 `json:"duration"`,
		sequenceNumber: int `json:"sequenceNumber"`,
		error:          string `json:"error,omitempty"`,
	}
	Entry :: struct {
		command:  map[string]map[string]string `json:"command"`,
		metadata: Meta `json:"metadata"`,
	}
	entries := make([]Entry, len(r.records), context.temp_allocator)
	log := strings.builder_make(context.temp_allocator)
	for rec, k in r.records {
		name := rec.command
		for pair in MAESTRO_COMMAND_NAMES do if pair[0] == rec.command do name = pair[1]
		fields := make(map[string]string, 1, context.temp_allocator)
		fields["description"] = rec.description
		cmd := make(map[string]map[string]string, 1, context.temp_allocator)
		cmd[name] = fields
		entries[k] = {cmd, {rec.status, rec.start_ms, i64(rec.duration_ms), rec.seq, rec.error}}
		fmt.sbprintf(&log, "%s%s %s (%.0f ms)\n", strings.repeat("  ", rec.depth, context.temp_allocator), rec.description, rec.status, rec.duration_ms)
		for line in rec.logs do fmt.sbprintf(&log, "JsConsole: %s\n", line)
		if rec.error != "" do fmt.sbprintf(&log, "%s\n", rec.error)
	}
	if data, err := json.marshal(entries, {pretty = true}, context.temp_allocator); err == nil {
		write_file(fmt.tprintf("%s/commands.json", dir), data)
	}
	write_file(fmt.tprintf("%s/logs/maestro.log", dir), transmute([]byte)strings.to_string(log))
	if !passed {
		if png, ok := op_screenshot(r.c, context.temp_allocator); ok {
			os.make_directory_all(fmt.tprintf("%s/screenshots", dir))
			write_file(fmt.tprintf("%s/screenshots/final.png", dir), png)
		}
	}
}

// A description with its ${...} evaluated, as Maestro's messages show them (its live view
// shows them as written); as written when they do not evaluate.
evaluated :: proc(r: ^Runner, description: string) -> string {
	if v, err := eval(r, description); err == nil do return v
	return description
}

// The message of the command that failed: the last failed one that is not a container
// reporting its sub-command's failure.
@(private = "file")
failure_message :: proc(r: ^Runner) -> string {
	msg := ""
	for rec in r.records {
		if rec.status == "FAILED" && rec.error != "" && rec.error != SUB_FLOW_FAILED do msg = rec.error
	}
	return msg
}

@(private = "file")
os_base :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:] if i >= 0 else path
}

write_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data) == nil
}

// ---- command list ---------------------------------------------------------------------

// Runs commands in order. A failing command fails the list unless it is optional (then it
// is a warning); a false condition skips a command.
run_list :: proc(r: ^Runner, cmds: []Cmd, section := "") -> (ok: bool) {
	parent := r.path
	defer r.path = parent
	view_section(r, section)
	for &c, k in cmds {
		seq := len(r.records)
		node := r.view.nodes[&c]
		if node == nil { 	// not reachable from the flow tree: still shown, never a crash
			node = new(View_Node, r.alloc)
			node.cmd, node.depth, node.desc = &c, r.depth, maestro_description(r, &c)
		}
		r.path = fmt.aprintf("%s/%s%d", parent, section, k, allocator = r.alloc)
		append(&r.records, Record{
			seq = seq, path = r.path, depth = r.depth, command = c.name, description = node.desc,
			start_ms = time.to_unix_nanoseconds(time.now()) / 1_000_000,
		})
		view_started(r, node)
		t := time.tick_now()
		r.depth += 1
		// Maestro evaluates a command's scripts once, before running it: its ${...} values are
		// kept while it runs (a lookup polling the screen does not run them again).
		append(&r.evals, nil)
		saved_rec, saved_node := r.log_rec, r.log_node
		r.log_rec, r.log_node = seq, node
		mutating, err := exec(r, &c)
		rec := &r.records[seq]
		// evalScript's description is its script as written (EvalScriptCommand keeps it).
		if _, is_eval := c.data.(Eval_Script); !is_eval && strings.contains(rec.description, "${") {
			rec.evaluated = evaluated(r, rec.description)
		}
		r.log_rec, r.log_node = saved_rec, saved_node
		pop(&r.evals)
		r.depth -= 1
		rec.duration_ms = us(t) / 1000
		msg, failed := err.?
		switch {
		case !failed:
			rec.status = "COMPLETED"
		case msg == SKIPPED:
			rec.status = "SKIPPED"
		case c.optional:
			rec.status, rec.error = "WARNED", msg
		case:
			rec.status, rec.error = "FAILED", msg
		}
		if mutating do r.last_interaction = time.tick_now()
		node.ms, node.error = rec.duration_ms, rec.error
		switch rec.status {
		case "COMPLETED": node.status = .Completed
		case "SKIPPED":   node.status = .Skipped
		case "WARNED":    node.status = .Warned
		case:             node.status = .Failed
		}
		view_finished(r, node)
		if rec.status == "FAILED" do return false
	}
	return true
}

// ---- commands -------------------------------------------------------------------------

// Executes one command. `mutating` = it may have changed the screen (Maestro then restarts
// the lookup timeout clock). `err` is empty on success, SKIPPED, or the failure.
@(private = "file")
exec :: proc(r: ^Runner, c: ^Cmd) -> (mutating: bool, err: Err) {
	switch d in c.data {
	case Launch_App:
		app := eval(r, d.app_id) or_return
		perms := d.permissions[:] if d.has_permissions else DEFAULT_PERMISSIONS
		args := eval_launch_arguments(r, d.arguments[:]) or_return
		// Maestro's order: clear the keychain, clear the state, set the permissions, launch
		// (stopping the app first unless stopApp: false).
		if r.dev.platform == .IOS {
			if d.clear_keychain {
				if out, ok := simctl("keychain", r.dev.udid, "reset"); !ok do return true, out
			}
			t := time.tick_now()
			if d.clear_state do ios_clear_state(r.dev.udid, app) or_return
			debug_step(r, "clear state", &t)
			set_permissions(r, app, perms) or_return
			debug_step(r, "permissions", &t)
			// Just reinstalled, the app is not running.
			if d.stop_app && !d.clear_state do simctl("terminate", r.dev.udid, app)
			debug_step(r, "terminate", &t)
			// `simctl launch` returns once the process starts; Android's `am start -W` once
			// it has launched. Wait for the app's UI, then settle: a tap during the launch
			// would be ignored.
			if !op_mark(r.c) do return true, "agent connection lost"
			cmd := make([dynamic]string, 0, 3 + 2 * len(args), context.temp_allocator)
			append(&cmd, "launch", r.dev.udid, app)
			append(&cmd, ..ios_launch_arguments(args))
			if out, ok := simctl(..cmd[:]); !ok do return true, out
			debug_step(r, "simctl launch", &t)
			ready, ok := op_launched(r.c, app, 20_000, r.alloc)
			debug_step(r, "app ready", &t)
			if !ok do return true, "agent connection lost"
			if !ready do return true, fmt.aprintf("%s did not come to the foreground", app, allocator = r.alloc)
			return true, settle(r)
		}
		if d.clear_state do _ = shell(r, "pm clear %s", app)
		set_permissions(r, app, perms) or_return
		if d.stop_app do _ = shell(r, "am force-stop %s", app)
		comp := launcher(r, app) or_return
		return true, android_launch(r, comp, args)
	case App_Cmd:
		app := eval(r, d.app_id) or_return
		if r.dev.platform == .IOS {
			// killApp is stopApp on iOS, as in Maestro (no process death there).
			if d.op == .Clear_State do return true, ios_clear_state(r.dev.udid, app)
			simctl("terminate", r.dev.udid, app)
			return true, nil
		}
		switch d.op {
		case .Stop:        _ = shell(r, "am force-stop %s", app)
		case .Kill:        _ = shell(r, "am kill %s", app)
		case .Clear_State: if strings.trim_space(shell(r, "pm path %s", app)) != "" do _ = shell(r, "pm clear %s", app)
		}
		return true, nil
	case Tap:
		return true, tap(r, c, d)
	case Assert:
		timeout := i64(LOOKUP_TIMEOUT_MS)
		if t, has := d.timeout.?; has do timeout = parse_timeout(r, t) or_return
		met := condition_met(r, d.cond, c.optional, timeout) or_return
		if !met do return false, fmt.aprintf("Assertion is false: %s\n%s", evaluated(r, condition_description(d.cond)), screen_summary(r), allocator = r.alloc)
		return false, nil
	case Input_Text:
		return true, type_text(r, eval(r, d.text) or_return)
	case Erase_Text:
		if _, ok := op_erase(r.c, i32(d.count)); !ok do return true, "agent connection lost"
		return true, settle(r)
	case Key_Press:
		if _, ok := op_key(r.c, d.keycode); !ok do return true, "agent connection lost"
		return true, settle(r)
	case Navigate:
		switch d {
		case .Back:
			if r.dev.platform == .IOS do return true, nil // no back key: a no-op, as in Maestro
			if _, ok := op_key(r.c, KEYCODE_BACK); !ok do return true, "agent connection lost"
			return true, settle(r)
		case .Hide_Keyboard:
			if r.dev.platform == .IOS do return true, ios_hide_keyboard(r)
			// Maestro presses BACK, then fails if (G)board ids are still on screen.
			if _, ok := op_key(r.c, KEYCODE_BACK); !ok do return true, "agent connection lost"
			if e := settle(r); e != nil do return true, e
			if !read_screen(r) do return true, "agent connection lost"
			for &n in r.h.nodes do if n.kept && strings.contains(n.id, GBOARD_ID) {
				return true, "Couldn't hide the keyboard"
			}
			return true, nil
		case .Scroll:
			return true, swipe_points(r, r.w / 2, r.h_px / 2, r.w / 2, i32(f32(r.h_px) * 0.1), 400, nil)
		case .Clear_Keychain:
			if r.dev.platform == .IOS {
				if out, ok := simctl("keychain", r.dev.udid, "reset"); !ok do return true, out
				return true, nil
			}
			return false, nil // iOS only: a no-op on Android
		}
	case Scroll_Until:
		return true, scroll_until(r, c, d)
	case Swipe:
		return true, swipe(r, c, d)
	case Wait_Animation:
		timeout := i64(ANIMATION_TIMEOUT_MS)
		if t, has := d.timeout.?; has do timeout = parse_timeout(r, t) or_return
		if !op_mark(r.c) do return true, "agent connection lost"
		s, ok := op_settle(r.c, SETTLE_QUIET_MS, 0, i32(timeout))
		if !ok do return true, "agent connection lost"
		_ = s
		return true, nil
	case Open_Link:
		link := eval(r, d.link) or_return
		if strings.contains(link, " ") do return false, "links with spaces are not supported yet"
		// iOS opens every link the same way (Maestro ignores browser and autoVerify there).
		if r.dev.platform == .IOS {
			if out, ok := simctl("openurl", r.dev.udid, link); !ok do return true, out
			return true, settle(r)
		}
		browser := ""
		if d.browser {
			// AndroidDriver.openBrowser: Chrome, else Firefox, else the default handler.
			packages := shell(r, "pm list packages")
			for p in ([]string{"com.android.chrome", "org.mozilla.firefox"}) {
				if strings.contains(packages, fmt.tprintf("package:%s\n", p)) || strings.has_suffix(strings.trim_space(packages), p) {
					browser = p
					break
				}
			}
		}
		_ = shell(r, "am start -a android.intent.action.VIEW -d %s %s", link, browser)
		settle(r) or_return
		if d.auto_verify do auto_verify(r, eval(r, d.app_id) or_return) or_return
		return true, nil
	case Run_Flow:
		if cond, has := d.cond.?; has {
			met := condition_met(r, cond, c.optional, -1) or_return
			if !met do return false, SKIPPED
		}
		return run_sub(r, d.sub)
	case Repeat:
		max_runs := max(int)
		if t, has := d.times.?; has {
			s := eval(r, t) or_return
			v, ok := strconv.parse_f64(strings.trim_space(s))
			if !ok do return false, fmt.aprintf("repeat: `times` must be a number, got `%s`", s, allocator = r.alloc)
			max_runs = int(v)
		}
		runs := 0
		node := r.view.nodes[c]
		for runs < max_runs {
			if cond, has := d.cond.?; has {
				// RepeatCommand.checkCondition evaluates its scripts again each time.
				clear(&r.evals[len(r.evals) - 1])
				met := condition_met(r, cond, c.optional, -1) or_return
				if !met do break
			}
			if runs > 0 do view_reset(node.children[:])
			m, e := run_sub(r, Sub_Flow{commands = d.commands})
			mutating = mutating || m
			if e != nil do return mutating, e
			runs += 1
			node.runs = runs
		}
		if runs == 0 do return false, SKIPPED
		return mutating, nil
	case Retry:
		s := eval(r, d.max_retries) or_return
		retries, ok := strconv.parse_int(strings.trim_space(s))
		if !ok do retries = 1
		retries = min(retries, MAX_RETRIES_ALLOWED)
		node := r.view.nodes[c]
		for attempt := 0; ; attempt += 1 {
			if attempt > 0 {
				view_reset(node.on_start[:])
				view_reset(node.children[:])
				view_reset(node.on_complete[:])
			}
			m, e := run_sub(r, d.sub)
			mutating = mutating || m
			if e == nil || attempt >= retries do return mutating, e
		}
	case Screenshot:
		file := command_output(r, "takeScreenshot", eval(r, d.path) or_return, ".png") or_return
		png := screenshot(r, d.crop_on, c.optional) or_return
		if !write_file(file, png) do return false, fmt.aprintf("cannot write %s", file, allocator = r.alloc)
		return false, nil
	case Assert_Screenshot:
		return false, assert_screenshot(r, c, d)
	case Start_Recording:
		return false, start_recording(r, command_output(r, "startRecording", eval(r, d.path) or_return, ".mp4") or_return)
	case Stop_Recording:
		return false, stop_recording(r)
	case Add_Media:
		return true, add_media(r, d.files[:])
	case Set_Location:
		lat_s, lon_s := eval(r, d.latitude) or_return, eval(r, d.longitude) or_return
		lat, lat_ok := strconv.parse_f64(strings.trim_space(lat_s))
		lon, lon_ok := strconv.parse_f64(strings.trim_space(lon_s))
		if !lat_ok || !lon_ok do return true, fmt.aprintf("setLocation: not a latitude and longitude: %s, %s", lat_s, lon_s, allocator = r.alloc)
		return true, set_location(r, lat, lon)
	case Travel:
		return true, travel(r, d)
	case Eval_Script:
		// Scripts can make requests that change the app: mutating, as in Maestro.
		_ = eval(r, d.script) or_return
		return true, nil
	case Run_Script:
		if cond, has := d.cond.?; has {
			met := condition_met(r, cond, c.optional, -1) or_return
			if !met do return false, SKIPPED
		}
		// Its env on top of the current one, for this script only (runInSubScope).
		push_scope(r)
		defer pop_scope(r)
		define_env(r, d.env[:]) or_return
		saved := r.script_dir
		r.script_dir = d.dir
		defer r.script_dir = saved
		_ = js_run(r, d.script) or_return
		return true, nil
	case Copy_Text:
		el := find_element(r, d.sel, c.optional, -1) or_return
		n := r.h.nodes[el]
		// Orchestra.resolveText: text, hint, accessibility text, error (else empty).
		text := n.text
		if text == "" do text = n.hint
		if text == "" do text = n.desc
		if text == "" do text = n.error
		return false, set_copied_text(r, strings.clone(text, r.alloc))
	case Set_Clipboard:
		return false, set_copied_text(r, eval(r, d.text) or_return)
	case Paste_Text:
		text, has := r.copied_text.?
		if !has do return true, nil
		return true, type_text(r, text)
	case Set_Permissions:
		// Behind the scenes: the screen does not change.
		return false, set_permissions(r, eval(r, d.app_id) or_return, d.permissions[:])
	case Input_Random:
		return true, type_text(r, js_random(r, d.kind, d.length) or_return)
	case Set_Orientation:
		return true, set_orientation(r, eval(r, d.orientation) or_return)
	case Device_Mode:
		return device_mode(r, d.op)
	}
	return false, "unhandled command"
}

type_text :: proc(r: ^Runner, text: string) -> Err {
	_, skipped, ok := op_type(r.c, text, r.alloc)
	if !ok do return "agent connection lost"
	if skipped > 0 {
		return fmt.aprintf("Could not type \"%s\": %d characters have no key sequence, and no editable field has the input focus to insert them into", text, skipped, allocator = r.alloc)
	}
	return settle(r)
}

// IOSDriver.hideKeyboard: past the keyboard's introduction, then a short swipe up, and if
// the keyboard is still there (its delete key), one to the left. It never fails.
@(private = "file")
ios_hide_keyboard :: proc(r: ^Runner) -> Err {
	if !read_screen(r) do return "agent connection lost"
	intro := compile(r, "Speed up your typing by sliding your finger across the letters to compose a word.*") or_return
	cont := compile(r, "Continue") or_return
	for &n in r.h.nodes do if n.kept && has_bounds(n) && rx_full(intro, n.text) {
		y := n.top + (n.bottom - n.top) / 2
		if y < r.h_px / 2 do break
		for &b in r.h.nodes do if b.kept && has_bounds(b) && rx_full(cont, b.text) && b.top + (b.bottom - b.top) / 2 > y {
			if _, ok := op_tap(r.c, b.left + (b.right - b.left) / 2, b.top + (b.bottom - b.top) / 2); !ok do return "agent connection lost"
			settle(r) or_return
			break
		}
		break
	}
	keyboard_shown :: proc(r: ^Runner) -> (shown: bool, err: Err) {
		if !read_screen(r) do return false, "agent connection lost"
		for &n in r.h.nodes do if n.kept && n.id == "delete" do return true, nil
		return false, nil
	}
	w, h := r.w, r.h_px
	if !(keyboard_shown(r) or_return) do return nil
	swipe_points(r, w / 2, h / 2, w / 2, i32(f32(h) * 0.47), 50, nil) or_return
	if !(keyboard_shown(r) or_return) do return nil
	// swipe_points settled already (Maestro's closing waitForAppToSettle).
	return swipe_points(r, w / 2, h / 2, i32(f32(w) * 0.47), h / 2, 50, nil)
}

// A sub-flow: its own env scope, the caller's env then its own, then onFlowStart, commands,
// onFlowComplete.
@(private = "file")
run_sub :: proc(r: ^Runner, s: Sub_Flow) -> (mutating: bool, err: Err) {
	push_scope(r)
	defer pop_scope(r)
	if e := define_env(r, s.call_env[:]); e != nil do return false, e
	if e := define_env(r, s.env[:]); e != nil do return false, e
	before := len(r.records)
	ok := true
	if len(s.on_start) > 0 do ok = run_list(r, s.on_start[:], "s")
	if ok do ok = run_list(r, s.commands[:])
	if len(s.on_complete) > 0 do ok = run_list(r, s.on_complete[:], "c") && ok
	for rec in r.records[before:] do if rec.status != "SKIPPED" do mutating = true
	if !ok do return mutating, SUB_FLOW_FAILED
	return mutating, nil
}

@(private = "file")
tap :: proc(r: ^Runner, c: ^Cmd, d: Tap) -> Err {
	x, y: i32
	// The tapped element as it was (strings copied: the hierarchy's arena is reset by reads).
	tapped: struct {
		text, desc, class: string,
		flags:             Flags,
	}
	if d.sel == nil {
		p := eval(r, d.point) or_return
		ok: bool
		x, y, ok = parse_point(p, r.w, r.h_px)
		if !ok do return fmt.aprintf("invalid point `%s`", p, allocator = r.alloc)
	} else {
		el := find_element(r, d.sel, c.optional, -1) or_return
		n := r.h.nodes[el]
		x, y = n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2
		tapped = {strings.clone(n.text, r.alloc), strings.clone(n.desc, r.alloc), strings.clone(n.class, r.alloc), n.flags}
		if d.point != "" {
			p := eval(r, d.point) or_return
			ok: bool
			x, y, ok = relative_point(p, n)
			if !ok do return fmt.aprintf("invalid element-relative point `%s`", p, allocator = r.alloc)
		}
	}
	before := r.h.hash
	typing_before := typing(r)
	// The screen was read since the last tap: the checks below share that read (one costs
	// ~180 ms on iOS).
	read_since_tap := false
	for attempt := 0; attempt < (2 if d.retry else 1); attempt += 1 {
		for i in 0 ..< d.repeat {
			t := time.tick_now()
			ok: bool
			if d.long_press {
				_, ok = op_press(r.c, x, y, LONG_PRESS_MS)
			} else {
				_, ok = op_tap(r.c, x, y)
			}
			if !ok do return "agent connection lost"
			if d.repeat > 1 {
				left := f64(d.delay_ms) - us(t) / 1000
				if left > 0 do time.sleep(time.Duration(left * f64(time.Millisecond)))
			}
		}
		settle(r, d.settle_ms) or_return
		read_since_tap = false
		// The element moved between the lookup and the tap: an app that keeps laying out after
		// it looked settled (Settings inserts a banner ~0.5 s after launch). If it is still
		// there, unchanged (nothing reacted to the tap: a toggled switch would differ), the
		// tap missed it: tap it where it is now. Once.
		if d.sel != nil && d.point == "" && d.repeat == 1 && !d.long_press && attempt == 0 {
			if !read_screen(r) do return "agent connection lost"
			read_since_tap = true
			if el := select(r, d.sel) or_return; el >= 0 {
				n := r.h.nodes[el]
				nx, ny := n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2
				same := n.text == tapped.text && n.desc == tapped.desc && n.flags == tapped.flags
				moved := abs(int(nx - x)) > 4 || abs(int(ny - y)) > 4
				if r.debug && moved do fmt.printf("      [tapped %s moved by %d,%d; same %v]\n", tapped.class, nx - x, ny - y, same)
				// A field the tap focused moves out of the keyboard's way (and the read can
				// predate its focus flag): that is no miss.
				if same && moved && (typing_before || !typing(r)) {
					x, y = nx, ny
					if _, ok := op_tap(r.c, x, y); !ok do return "agent connection lost"
					settle(r, d.settle_ms) or_return
					read_since_tap = false
				}
			}
		}
		if !d.retry do break
		if !read_since_tap {
			if !read_screen(r) do return "agent connection lost"
			read_since_tap = true
		}
		if r.h.hash != before do break
	}
	// waitUntilVisible (Maestro.tap): the screen did not change and something covers the
	// element at its center: wait for it to show (10 reads, 1 s apart), then tap it again.
	if d.sel != nil && d.sel.wait_until_visible {
		if !read_since_tap && !read_screen(r) do return "agent connection lost"
		if r.h.hash != before do return nil
		for attempt in 0 ..< 10 {
			if el := select(r, d.sel) or_return; el >= 0 {
				n := r.h.nodes[el]
				x, y = n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2
				if element_at(r, r.h.roots[:], x, y) == el do break
			}
			if attempt == 9 do break
			time.sleep(time.Second)
			if !read_screen(r) do return "agent connection lost"
		}
		if _, ok := op_tap(r.c, x, y); !ok do return "agent connection lost"
		settle(r, d.settle_ms) or_return
	}
	return nil
}

// A keyboard is up or a text field has the focus, in the last read.
@(private = "file")
typing :: proc(r: ^Runner) -> bool {
	for &n in r.h.nodes {
		if !n.kept do continue
		if n.class == "Keyboard" do return true // iOS
		if .Focused in n.flags && (strings.has_suffix(n.class, "EditText") || n.class == "TextField" ||
			n.class == "SecureTextField" || n.class == "TextView" || n.class == "SearchField") {
			return true
		}
	}
	return false
}

// ViewHierarchy.getElementAt: the last element containing the point, its own children first.
@(private = "file")
element_at :: proc(r: ^Runner, list: []int, x, y: i32) -> int {
	#reverse for k in list {
		n := r.h.nodes[k]
		if !n.kept do continue
		if e := element_at(r, n.children[:], x, y); e >= 0 do return e
		if has_bounds(n) && x >= n.left && x <= n.right && y >= n.top && y <= n.bottom do return k
	}
	return -1
}

@(private = "file")
scroll_until :: proc(r: ^Runner, c: ^Cmd, d: Scroll_Until) -> Err {
	timeout := parse_timeout(r, d.timeout) or_return
	if timeout < 0 do timeout = 20_000
	speed_s := eval(r, d.speed) or_return
	speed, sok := strconv.parse_i64(strings.trim_space(speed_s))
	if !sok do return fmt.aprintf("invalid scroll speed `%s`", speed_s, allocator = r.alloc)
	duration := i64(1000 * f64(100 - speed) / 100) + 1 // ScrollUntilVisibleCommand.speedToDuration
	if duration < 0 do duration = 40
	visibility := f64(d.visibility / 100) // integer division, as Maestro's visibilityPercentageNormalized
	dir := swipe_for_scroll(d.direction)
	end := time.tick_now()._nsec + timeout * 1_000_000
	retry_center := 0
	cx, cy := r.w / 2, r.h_px / 2
	ex, ey := edge_point(r, cx, cy, dir)
	// After a swipe the content drifts on (~1.5 s on iOS, a fling on Android) and a settle
	// waits for it to stop. While the element is not on screen yet that wait is useless: the
	// next swipe's touch stops the drift anyway. So read right away, swipe again if it is not
	// there, and settle only once it shows, for Maestro's checks below on a still screen.
	// A swipe is over only after its own duration, as a finger's would be: Android's SWIPE
	// injects it at once, and gestures overlapping in time can leave a list stuck.
	moving := false
	swiped: time.Tick
	gesture := time.Duration(duration + 50) * time.Millisecond
	for {
		if moving {
			if !read_screen(r) do return "agent connection lost"
			if el := select(r, d.sel) or_return; el < 0 || visible_pct(r.h.nodes[el], r.w, r.h_px) <= 0 {
				if time.tick_now()._nsec >= end do break
				if time.tick_since(swiped) < gesture {
					time.sleep(50 * time.Millisecond)
					continue
				}
				swiped = time.tick_now()
				if _, ok := op_swipe(r.c, cx, cy, ex, ey, i32(duration), fling = true); !ok do return "agent connection lost"
				continue
			}
			settle(r, d.settle_ms) or_return
			moving = false
		}
		el, found, ferr := try_find(r, d.sel, 500)
		if ferr != nil do return ferr
		if found {
			n := r.h.nodes[el]
			vis := visible_pct(n, r.w, r.h_px)
			if d.center && vis > 0.1 && retry_center <= 4 {
				if near_center(n, dir, r.w, r.h_px) do return nil
				retry_center += 1
			} else if vis >= visibility {
				return nil
			}
		}
		// swipeFromCenter: from the screen center towards the edge.
		swiped = time.tick_now()
		if _, ok := op_swipe(r.c, cx, cy, ex, ey, i32(duration), fling = true); !ok do return "agent connection lost"
		moving = true
		if time.tick_now()._nsec >= end do break
	}
	return fmt.aprintf("No visible element found: %s\n%s", evaluated(r, selector_description(d.sel)), screen_summary(r), allocator = r.alloc)
}

@(private = "file")
swipe :: proc(r: ^Runner, c: ^Cmd, d: Swipe) -> Err {
	if dir, has := d.direction.?; has {
		if d.from != nil {
			el := find_element(r, d.from, c.optional, -1) or_return
			n := r.h.nodes[el]
			x, y := n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2
			if d.from.point != "" {
				p := eval(r, d.from.point) or_return
				ok: bool
				x, y, ok = relative_point(p, n)
				if !ok do return fmt.aprintf("invalid element-relative point `%s`", p, allocator = r.alloc)
			}
			ex, ey := edge_point(r, x, y, dir)
			return swipe_points(r, x, y, ex, ey, i32(d.duration), d.settle_ms)
		}
		w, h := f32(r.w), f32(r.h_px)
		x1, y1, x2, y2: f32
		switch dir {
		case .Up:    x1, y1, x2, y2 = w * 0.5, h * 0.5, w * 0.5, h * 0.1
		case .Down:  x1, y1, x2, y2 = w * 0.5, h * 0.2, w * 0.5, h * 0.9
		case .Right: x1, y1, x2, y2 = w * 0.1, h * 0.5, w * 0.9, h * 0.5
		case .Left:  x1, y1, x2, y2 = w * 0.9, h * 0.5, w * 0.1, h * 0.5
		}
		return swipe_points(r, i32(x1), i32(y1), i32(x2), i32(y2), i32(d.duration), d.settle_ms)
	}
	s := eval(r, d.start) or_return
	e := eval(r, d.end) or_return
	x1, y1, ok1 := parse_point(s, r.w, r.h_px)
	x2, y2, ok2 := parse_point(e, r.w, r.h_px)
	if !ok1 || !ok2 do return fmt.aprintf("invalid swipe coordinates `%s` -> `%s`", s, e, allocator = r.alloc)
	return swipe_points(r, x1, y1, x2, y2, i32(d.duration), d.settle_ms)
}

// Like `adb shell input swipe`: the content keeps the gesture's speed and flings.
@(private = "file")
swipe_points :: proc(r: ^Runner, x1, y1, x2, y2, duration: i32, settle_ms: Maybe(int)) -> Err {
	if _, ok := op_swipe(r.c, x1, y1, x2, y2, duration, fling = true); !ok do return "agent connection lost"
	return settle(r, settle_ms)
}

@(private = "file")
swipe_for_scroll :: proc(d: Swipe_Dir) -> Swipe_Dir {
	switch d {
	case .Down:  return .Up
	case .Up:    return .Down
	case .Left:  return .Right
	case .Right: return .Left
	}
	return .Up
}

// AndroidDriver.swipe(elementPoint, direction): to 10% / 90% of the screen.
@(private = "file")
edge_point :: proc(r: ^Runner, x, y: i32, dir: Swipe_Dir) -> (i32, i32) {
	switch dir {
	case .Up:    return x, i32(f32(r.h_px) * 0.1)
	case .Down:  return x, i32(f32(r.h_px) * 0.9)
	case .Right: return i32(f32(r.w) * 0.9), y
	case .Left:  return i32(f32(r.w) * 0.1), y
	}
	return x, y
}

settle :: proc(r: ^Runner, timeout_ms: Maybe(int) = nil) -> Err {
	_, err := settle_status(r, timeout_ms)
	return err
}

settle_status :: proc(r: ^Runner, timeout_ms: Maybe(int) = nil) -> (Settle_Status, Err) {
	timeout := i32(SETTLE_TIMEOUT_MS)
	if t, has := timeout_ms.?; has do timeout = i32(t)
	res, ok := op_settle(r.c, SETTLE_QUIET_MS, SETTLE_NO_CHANGE_MS, timeout)
	if !ok do return .Timeout, "agent connection lost"
	if r.debug do fmt.printf("      [settle %v: ui done %d ms, waited %d ms, %d frames, %d probes (max %d ms), %d events]\n", res.status, res.ui_done_us / 1000, res.waited_us / 1000, res.frames, res.probes, res.probe_max_us / 1000, res.events)
	return res.status, nil
}

// ---- conditions and lookups -----------------------------------------------------------

// Orchestra.evaluateCondition. `timeout` < 0: the default for conditions (7 s), always
// shortened by the time since the last interaction.
@(private = "file")
condition_met :: proc(r: ^Runner, cond: Condition, optional: bool, timeout: i64) -> (met: bool, err: Err) {
	if p, has := cond.platform.?; has && !strings.equal_fold(p, "ios" if r.dev.platform == .IOS else "android") do return false, nil
	if s, has := cond.script.?; has {
		v := eval(r, s) or_return
		if strings.trim_space(v) == "" || strings.equal_fold(v, "false") || v == "undefined" || v == "null" do return false, nil
		if f, ok := strconv.parse_f64(v); ok && f == 0 do return false, nil
	}
	limit := timeout if timeout >= 0 else OPTIONAL_LOOKUP_TIMEOUT_MS
	if cond.visible != nil {
		_, found := try_find(r, cond.visible, adjusted(r, limit)) or_return
		if !found do return false, nil
	}
	if cond.not_visible != nil {
		end := time.tick_now()._nsec + adjusted(r, limit) * 1_000_000
		for {
			_, found := try_find(r, cond.not_visible, 500) or_return
			if !found do break
			if time.tick_now()._nsec >= end do return false, nil
		}
	}
	return true, nil
}

@(private = "file")
adjusted :: proc(r: ^Runner, ms: i64) -> i64 {
	return max(0, ms - i64(us(r.last_interaction) / 1000))
}

// Orchestra.findElement: polls the hierarchy until the selector matches. `timeout` < 0:
// the lookup default (17 s, optional 7 s) shortened by the time since the last interaction.
find_element :: proc(r: ^Runner, sel: ^Selector, optional: bool, timeout: i64) -> (idx: int, err: Err) {
	limit := timeout if timeout >= 0 else adjusted(r, OPTIONAL_LOOKUP_TIMEOUT_MS if optional else LOOKUP_TIMEOUT_MS)
	i, found := try_find(r, sel, limit) or_return
	if !found {
		return -1, fmt.aprintf("Element not found: %s\n%s", evaluated(r, filter_description(sel)), screen_summary(r), allocator = r.alloc)
	}
	return i, nil
}

// One read at least (Maestro's do-while), then re-reads until found or `timeout_ms` passes.
try_find :: proc(r: ^Runner, sel: ^Selector, timeout_ms: i64) -> (idx: int, found: bool, err: Err) {
	end := time.tick_now()._nsec + timeout_ms * 1_000_000
	for {
		if !read_screen(r) do return -1, false, "agent connection lost"
		i := select(r, sel) or_return
		if i >= 0 do return i, true, nil
		if time.tick_now()._nsec >= end do return -1, false, nil
	}
}

// The last hierarchy read, briefly: each window, then the texts on screen.
screen_summary :: proc(r: ^Runner) -> string {
	b := strings.builder_make(r.alloc)
	strings.write_string(&b, "      screen:")
	for root in r.h.roots {
		n := r.h.nodes[root]
		fmt.sbprintf(&b, " [%s %d,%d-%d,%d]", n.class[strings.last_index_byte(n.class, '.') + 1:], n.left, n.top, n.right, n.bottom)
	}
	shown := 0
	for i in r.h.order {
		n := r.h.nodes[i]
		label := n.text if n.text != "" else n.desc
		if label == "" do continue
		fmt.sbprintf(&b, "%s\"%s\"", " | " if shown > 0 else "\n      texts: ", label)
		shown += 1
		if shown == 15 do break
	}
	return strings.to_string(b)
}

// Orchestra.buildFilter's description, used in "Element not found: ..."
@(private = "file")
filter_description :: proc(s: ^Selector) -> string {
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if t, ok := s.text.?; ok do append(&parts, fmt.tprintf("Text matching regex: %s", t))
	if t, ok := s.id.?; ok do append(&parts, fmt.tprintf("Id matching regex: %s", t))
	if s.below != nil do append(&parts, fmt.tprintf("Below: %s", selector_description(s.below)))
	if s.above != nil do append(&parts, fmt.tprintf("Above: %s", selector_description(s.above)))
	if s.left_of != nil do append(&parts, fmt.tprintf("Left of: %s", selector_description(s.left_of)))
	if s.right_of != nil do append(&parts, fmt.tprintf("Right of: %s", selector_description(s.right_of)))
	if s.contains_child != nil do append(&parts, fmt.tprintf("Contains child: %s", selector_description(s.contains_child)))
	if s.child_of != nil do append(&parts, fmt.tprintf("Child of: %s", selector_description(s.child_of)))
	if len(s.traits) > 0 do append(&parts, trait_names(s.traits[:]))
	if t, ok := s.index.?; ok do append(&parts, fmt.tprintf("Index: %s", t))
	if v, ok := s.enabled.?; ok do append(&parts, "Enabled" if v else "Disabled")
	if v, ok := s.selected.?; ok do append(&parts, "Selected" if v else "Not selected")
	if v, ok := s.checked.?; ok do append(&parts, "Checked" if v else "Not checked")
	if v, ok := s.focused.?; ok do append(&parts, "Focused" if v else "Not focused")
	return strings.join(parts[:], ", ", context.temp_allocator)
}

// ---- matching (Orchestra.buildFilter) -------------------------------------------------

// Index of the element `sel` picks on the current hierarchy, or -1.
@(private = "file")
select :: proc(r: ^Runner, sel: ^Selector) -> (idx: int, err: Err) {
	nodes := r.h.order[:]
	if sel.child_of != nil {
		parent := resolve_parent(r, sel.child_of) or_return
		if parent < 0 do return -1, nil
		nodes = subtree(r, parent)
	}
	res := apply(r, sel, nodes) or_return
	return res[0] if len(res) > 0 else -1, nil
}

@(private = "file")
resolve_parent :: proc(r: ^Runner, s: ^Selector) -> (idx: int, err: Err) {
	nodes := r.h.order[:]
	if s.child_of != nil {
		gp := resolve_parent(r, s.child_of) or_return
		if gp < 0 do return -1, nil
		nodes = subtree(r, gp)
	}
	res := apply(r, s, nodes) or_return
	return res[0] if len(res) > 0 else -1, nil
}

// ViewHierarchy(node).aggregate(): the node and its kept descendants, pre-order.
@(private = "file")
subtree :: proc(r: ^Runner, root: int) -> []int {
	out: [dynamic]int
	out.allocator = context.temp_allocator
	stack: [dynamic]int
	stack.allocator = context.temp_allocator
	append(&stack, root)
	for len(stack) > 0 {
		i := pop(&stack)
		append(&out, i)
		ch := r.h.nodes[i].children
		#reverse for c in ch do append(&stack, c)
	}
	return out[:]
}

// The full filter of one selector over `nodes`, in Maestro's order.
@(private = "file")
apply :: proc(r: ^Runner, s: ^Selector, nodes: []int) -> (res: []int, err: Err) {
	text_rx, id_rx: ^Rx
	if t, ok := s.text.?; ok do text_rx = compile(r, eval(r, t) or_return) or_return
	if t, ok := s.id.?; ok do id_rx = compile(r, eval(r, t) or_return) or_return
	_, hw := s.width.?
	_, hh := s.height.?
	_, he := s.enabled.?
	_, hs := s.selected.?
	_, hc := s.checked.?
	_, hf := s.focused.?
	has_basic := text_rx != nil || id_rx != nil || hw || hh || he || hs || hc || hf || len(s.traits) > 0

	out: [dynamic]int
	out.allocator = context.temp_allocator
	if has_basic {
		// deepestMatchingElement: matches with no matching descendant, in pre-order.
		memo := make([]i8, len(r.h.nodes), context.temp_allocator) // 0 unknown, 1 has match below
		seen := make([]bool, len(r.h.nodes), context.temp_allocator)
		for n in nodes do deepest(r, s, text_rx, id_rx, n, &out, seen, memo)
	} else {
		append(&out, ..nodes)
	}

	// Relative filters intersect, keeping the order above.
	relative :: proc(r: ^Runner, other: ^Selector, nodes: []int, out: ^[dynamic]int, pred: proc(a, b: H_Node) -> bool) -> Err {
		others := apply(r, other, nodes) or_return
		keep := make([]bool, len(r.h.nodes), context.temp_allocator)
		for n in nodes {
			a := r.h.nodes[n]
			if !has_bounds(a) do continue
			for o in others do if has_bounds(r.h.nodes[o]) && pred(a, r.h.nodes[o]) {
				keep[n] = true
				break
			}
		}
		k := 0
		for n in out do if keep[n] {
			out[k] = n
			k += 1
		}
		resize(out, k)
		return nil
	}
	if s.below != nil do relative(r, s.below, nodes, &out, proc(a, b: H_Node) -> bool {return a.top > b.top}) or_return
	if s.above != nil do relative(r, s.above, nodes, &out, proc(a, b: H_Node) -> bool {return a.top < b.top}) or_return
	if s.left_of != nil do relative(r, s.left_of, nodes, &out, proc(a, b: H_Node) -> bool {return a.left < b.left}) or_return
	if s.right_of != nil do relative(r, s.right_of, nodes, &out, proc(a, b: H_Node) -> bool {return a.left > b.left}) or_return
	if s.contains_child != nil {
		kids := apply(r, s.contains_child, nodes) or_return
		is_kid := make([]bool, len(r.h.nodes), context.temp_allocator)
		for k in kids do is_kid[k] = true
		k := 0
		for n in out {
			for c in r.h.nodes[n].children do if is_kid[c] {
				out[k] = n
				k += 1
				break
			}
		}
		resize(&out, k)
	}
	if len(s.contains_descendants) > 0 {
		k := 0
		for n in out {
			all := true
			for d in s.contains_descendants {
				hit := false
				for c in r.h.nodes[n].children {
					sub := apply(r, d, subtree(r, c)) or_return
					if len(sub) > 0 {
						hit = true
						break
					}
				}
				if !hit {
					all = false
					break
				}
			}
			if all {
				out[k] = n
				k += 1
			}
		}
		resize(&out, k)
	}

	if idx_s, has := s.index.?; has {
		v := eval(r, idx_s) or_return
		f, ok := strconv.parse_f64(strings.trim_space(v))
		if !ok do return nil, fmt.aprintf("index must be a number, got `%s`", v, allocator = r.alloc)
		idx := int(f)
		// INDEX_COMPARATOR: by top, then left; nodes without bounds last.
		sorted := sort_by_position(r, out[:])
		resolved := idx if idx >= 0 else len(sorted) + idx
		if resolved < 0 || resolved >= len(sorted) do return nil, nil
		one := make([]int, 1, context.temp_allocator)
		one[0] = sorted[resolved]
		return one, nil
	}
	// clickableFirst: a stable sort, clickable nodes before the others.
	clickable: [dynamic]int
	clickable.allocator = context.temp_allocator
	for n in out do if .Clickable in r.h.nodes[n].flags do append(&clickable, n)
	for n in out do if .Clickable not_in r.h.nodes[n].flags do append(&clickable, n)
	return clickable[:], nil
}

@(private = "file")
sort_by_position :: proc(r: ^Runner, list: []int) -> []int {
	Keyed :: struct {
		i:    int,
		y, x: i64,
	}
	keyed := make([]Keyed, len(list), context.temp_allocator)
	for n, k in list {
		h := r.h.nodes[n]
		keyed[k] = {n, i64(h.top), i64(h.left)} if has_bounds(h) else {n, i64(max(i32)), i64(max(i32))}
	}
	slice.stable_sort_by(keyed, proc(a, b: Keyed) -> bool {
		return a.y < b.y || (a.y == b.y && a.x < b.x)
	})
	out := make([]int, len(list), context.temp_allocator)
	for k, j in keyed do out[j] = k.i
	return out
}

@(private = "file")
deepest :: proc(r: ^Runner, s: ^Selector, text_rx, id_rx: ^Rx, n: int, out: ^[dynamic]int, seen: []bool, memo: []i8) -> bool {
	found := false
	for c in r.h.nodes[n].children do if deepest(r, s, text_rx, id_rx, c, out, seen, memo) do found = true
	if found do return true
	if basic_match(r, s, text_rx, id_rx, r.h.nodes[n]) {
		if !seen[n] {
			seen[n] = true
			append(out, n)
		}
		return true
	}
	return false
}

@(private = "file")
basic_match :: proc(r: ^Runner, s: ^Selector, text_rx, id_rx: ^Rx, n: H_Node) -> bool {
	if text_rx != nil {
		// Filters.textMatches: text, hint, content description, or a non-empty error.
		if !(text_match(text_rx, n.text) || text_match(text_rx, n.hint) || text_match(text_rx, n.desc) ||
			   (n.error != "" && text_match(text_rx, n.error))) {
			return false
		}
	}
	if id_rx != nil {
		suffix := n.id[strings.last_index_byte(n.id, '/') + 1:]
		if !(rx_full(id_rx, n.id) || rx_full(id_rx, suffix)) do return false
	}
	if v, ok := s.enabled.?; ok && (.Enabled in n.flags) != v do return false
	if v, ok := s.selected.?; ok && (.Selected in n.flags) != v do return false
	if v, ok := s.checked.?; ok && (.Checked in n.flags) != v do return false
	if v, ok := s.focused.?; ok && (.Focused in n.flags) != v do return false
	_, hw := s.width.?
	_, hh := s.height.?
	if hw || hh {
		if !has_bounds(n) do return false
		tol := s.tolerance.? or_else 0
		if w, ok := s.width.?; ok && abs(int(n.right - n.left) - w) > tol do return false
		if h, ok := s.height.?; ok && abs(int(n.bottom - n.top) - h) > tol do return false
	}
	// TraitFilters. Every element has a text attribute in Maestro's hierarchy (empty when
	// it shows none), so `text` keeps them all.
	for t in s.traits {
		switch t {
		case .TEXT:
		case .SQUARE:
			if !has_bounds(n) do return false
			off := 1 - f32(n.right - n.left) / f32(n.bottom - n.top) // NaN or ±Inf when flat
			if !(off < 0.03 && off > -0.03) do return false
		case .LONG_TEXT:
			if strings.rune_count(n.text) <= 200 do return false
		}
	}
	return true
}

@(private = "file")
text_match :: proc(rx: ^Rx, value: string) -> bool {
	if rx_full(rx, value) do return true
	if !strings.contains_rune(value, '\n') do return false
	stripped, _ := strings.replace_all(value, "\n", " ", context.temp_allocator)
	return rx_full(rx, stripped)
}

// regex.matches(value) || regex.pattern == value
rx_full :: proc(rx: ^Rx, value: string) -> bool {
	if rx.literal do return strings.equal_fold(rx.pattern, value)
	if value == rx.pattern do return true
	cap, ok := regex.match(rx.re, value, context.temp_allocator, context.temp_allocator)
	_ = cap
	return ok
}

// Java patterns Odin's regex engine lacks: rejected rather than matched differently.
JAVA_ONLY_REGEX :: []string{"(?=", "(?!", "(?<=", "(?<!", "(?<", "(?i", "(?s", "(?m", "(?u", "(?x", "\\p{", "\\P{", "\\Q", "\\k<", "++", "*+", "?+", "}+"}

compile :: proc(r: ^Runner, pattern: string) -> (rx: ^Rx, err: Err) {
	if cached, ok := &r.regexes[pattern]; ok do return cached, nil
	for j in JAVA_ONLY_REGEX do if strings.contains(pattern, j) {
		return nil, fmt.aprintf("regex `%s` uses `%s`, which this runner's regex engine does not support", pattern, j, allocator = r.alloc)
	}
	entry := Rx {
		pattern = pattern,
	}
	re, cerr := regex.create(fmt.tprintf("^(?:%s)$", pattern), {.Case_Insensitive, .Unicode}, r.alloc, context.temp_allocator)
	if cerr != nil {
		entry.literal = true // Maestro's toRegexSafe: an invalid pattern matches as text
	} else {
		entry.re = re
	}
	r.regexes[pattern] = entry
	return &r.regexes[pattern], nil
}

has_bounds :: proc(n: H_Node) -> bool {
	return n.right > n.left || n.bottom > n.top || n.left != 0 || n.top != 0
}

// UiElement.getVisiblePercentage
@(private = "file")
visible_pct :: proc(n: H_Node, w, h: i32) -> f64 {
	bw, bh := n.right - n.left, n.bottom - n.top
	if bw == 0 && bh == 0 do return 0
	if n.left <= 0 && n.top <= 0 && n.right >= w && n.bottom >= h do return 1
	vx := max(0, min(n.right, w) - max(n.left, 0))
	vy := max(0, min(n.bottom, h) - max(n.top, 0))
	area := f64(bw) * f64(bh)
	if area == 0 do return 0
	return f64(vx) * f64(vy) / area
}

// UiElement.isElementNearScreenCenter
@(private = "file")
near_center :: proc(n: H_Node, dir: Swipe_Dir, w, h: i32) -> bool {
	cx, cy := w / 2, h / 2
	ex, ey := n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2
	margin := h / 5 if dir == .Up || dir == .Down else w / 5
	switch dir {
	case .Right: return ex > cx - margin
	case .Left:  return ex < cx + margin
	case .Up:    return ey < cy + margin
	case .Down:  return ey > cy - margin
	}
	return false
}

// "x, y" pixels or "x%, y%" of the screen.
@(private = "file")
parse_point :: proc(p: string, w, h: i32) -> (x, y: i32, ok: bool) {
	a, _, b := strings.partition(p, ",")
	pct := strings.contains(p, "%")
	xa, ok1 := strconv.parse_int(strings.trim_space(strings.trim_suffix(strings.trim_space(a), "%")))
	yb, ok2 := strconv.parse_int(strings.trim_space(strings.trim_suffix(strings.trim_space(b), "%")))
	if !ok1 || !ok2 do return
	if pct {
		if xa < 0 || xa > 100 || yb < 0 || yb > 100 do return
		return w * i32(xa) / 100, h * i32(yb) / 100, true
	}
	return i32(xa), i32(yb), true
}

// calculateElementRelativePoint: "x%, y%" of the element, or pixels inside it.
@(private = "file")
relative_point :: proc(p: string, n: H_Node) -> (x, y: i32, ok: bool) {
	bw, bh := n.right - n.left, n.bottom - n.top
	if strings.contains(p, "%") {
		px, py, pok := parse_point(p, 100, 100)
		if !pok do return
		return n.left + bw * px / 100, n.top + bh * py / 100, true
	}
	px, py, pok := parse_point(p, 0, 0)
	if !pok || px < 0 || py < 0 || px >= bw || py >= bh do return
	return n.left + px, n.top + py, true
}

@(private = "file")
parse_timeout :: proc(r: ^Runner, raw: string) -> (ms: i64, err: Err) {
	s := eval(r, raw) or_return
	clean, _ := strings.replace_all(strings.trim_space(s), "_", "", context.temp_allocator)
	v, ok := strconv.parse_i64(clean)
	if !ok do return 0, fmt.aprintf("invalid timeout `%s`: a number of milliseconds", s, allocator = r.alloc)
	return v, nil
}

// ---- env ------------------------------------------------------------------------------

@(private = "file")
push_scope :: proc(r: ^Runner) {
	m := make(map[string]string, 8, r.alloc)
	append(&r.env, m)
	r.env_gen += 1
}

@(private = "file")
pop_scope :: proc(r: ^Runner) {
	pop(&r.env)
	r.env_gen += 1
}

// DefineVariablesCommand: every value is evaluated first, then all are defined (a value
// does not see the keys before it in the same `env:`).
@(private = "file")
define_env :: proc(r: ^Runner, pairs: []Env_Pair) -> Err {
	if len(pairs) == 0 do return nil
	append(&r.evals, nil)
	defer pop(&r.evals)
	values := make([]string, len(pairs), context.temp_allocator)
	for p, k in pairs do values[k] = eval(r, p.value) or_return
	for p, k in pairs do r.env[len(r.env) - 1][p.key] = values[k]
	r.env_gen += 1
	return nil
}

// Env.evaluateScripts: each `${script}` is replaced by the script's value (JavaScript, see
// js.odin), an escaped `\${...}` stays as written without its backslash. Maestro's regexes
// exactly: a script runs to the last `}` before the next `$`; a blank one gives "".
eval :: proc(r: ^Runner, s: string) -> (out: string, err: Err) {
	if !strings.contains(s, "${") do return s, nil
	b := strings.builder_make(r.alloc)
	i := 0
	for {
		j := strings.index(s[i:], "${")
		if j < 0 do break
		at := i + j
		script, ok := script_at(s, at + 2)
		if !ok || (at > 0 && s[at - 1] == '\\') {
			strings.write_string(&b, s[i:at + 1])
			i = at + 1
			continue
		}
		strings.write_string(&b, s[i:at])
		if strings.trim_space(script) != "" do strings.write_string(&b, script_value(r, script) or_return)
		i = at + 2 + len(script) + 1
	}
	strings.write_string(&b, s[i:])
	done := strings.to_string(b)
	if !strings.contains(done, "\\${") do return done, nil

	// Then `\${...}` loses its backslash.
	b = strings.builder_make(r.alloc)
	i = 0
	for {
		j := strings.index(done[i:], "\\${")
		if j < 0 do break
		at := i + j
		script, ok := script_at(done, at + 3)
		if !ok {
			strings.write_string(&b, done[i:at + 1])
			i = at + 1
			continue
		}
		strings.write_string(&b, done[i:at])
		end := at + 3 + len(script) + 1
		strings.write_string(&b, done[at + 1:end])
		i = end
	}
	strings.write_string(&b, done[i:])
	return strings.to_string(b), nil
}

// `([^$]*)}` from `start`: up to the last `}` before the next `$`.
@(private = "file")
script_at :: proc(s: string, start: int) -> (script: string, ok: bool) {
	rest := s[start:]
	if d := strings.index_byte(rest, '$'); d >= 0 do rest = rest[:d]
	close := strings.last_index_byte(rest, '}')
	if close < 0 do return "", false
	return rest[:close], true
}

// A script's value, run once per command (see run_list).
@(private = "file")
script_value :: proc(r: ^Runner, script: string) -> (value: string, err: Err) {
	if len(r.evals) > 0 {
		if v, ok := r.evals[len(r.evals) - 1][script]; ok do return v, nil
	}
	value = js_run(r, script) or_return
	if len(r.evals) > 0 {
		top := &r.evals[len(r.evals) - 1]
		if top^ == nil do top^ = make(map[string]string, 4, r.alloc)
		top[strings.clone(script, r.alloc)] = value
	}
	return value, nil
}

// ---- device ---------------------------------------------------------------------------

// Reads every window into r.h and applies Maestro's bounds filter.
read_screen :: proc(r: ^Runner) -> bool {
	if !read_screen_once(r) do return false
	// Maestro's iOS runner answers the notification alert on its hierarchy reads.
	if r.dev.platform == .IOS && r.notifications != "" {
		tapped, ok := answer_notification_alert(r)
		if !ok do return false
		if tapped {
			if settle(r) != nil do return false
			return read_screen_once(r)
		}
	}
	return true
}

@(private = "file")
read_screen_once :: proc(r: ^Runner) -> bool {
	virtual.arena_free_all(&r.screen_arena)
	alloc := virtual.arena_allocator(&r.screen_arena)
	t := time.tick_now()
	body, _, ok := call(r.c, []byte{u8(Op.Screen)})
	if !ok do return false
	rd := Reader {
		b  = body,
		ok = true,
	}
	count := int(rd_u32(&rd))
	// The previous read's arrays lived in the arena just reset: start new ones.
	r.h.nodes = make([dynamic]H_Node, 0, count, alloc)
	r.h.roots = make([dynamic]int, 0, 8, alloc)
	r.h.order = make([dynamic]int, 0, count, alloc)
	stack := make([dynamic]int, 0, 64, alloc) // ancestors by depth
	hash: u64 = 14695981039346656037
	for k in 0 ..< count {
		n: H_Node
		n.depth = rd_u16(&rd)
		n.left, n.top, n.right, n.bottom = rd_i32(&rd), rd_i32(&rd), rd_i32(&rd), rd_i32(&rd)
		n.flags = transmute(Flags)rd_u8(&rd)
		n.text, n.desc, n.id, n.class = rd_str(&rd, alloc), rd_str(&rd, alloc), rd_str(&rd, alloc), rd_str(&rd, alloc)
		n.hint, n.error = rd_str(&rd, alloc), rd_str(&rd, alloc)
		if !rd.ok do return false
		n.children.allocator = alloc
		d := int(n.depth)
		resize(&stack, d)
		n.parent = stack[d - 1] if d > 0 else -1
		append(&r.h.nodes, n)
		if d == 0 do append(&r.h.roots, k)
		append(&stack, k)
		for v in ([]i32{n.left, n.top, n.right, n.bottom}) do hash = (hash ~ u64(u32(v))) * 1099511628211
		for c in transmute([]u8)n.text do hash = (hash ~ u64(c)) * 1099511628211
	}
	r.h.hash = hash
	// Display size: the extent of the window roots, in the current orientation (it changes
	// with setOrientation).
	w, h: i32
	for i in r.h.roots {
		w = max(w, r.h.nodes[i].right)
		h = max(h, r.h.nodes[i].bottom)
	}
	if w > 0 && h > 0 do r.w, r.h_px = w, h
	// filterOutOfBounds: drop nodes less than 10% on screen whose children are all dropped.
	w, h = r.w, r.h_px
	if w == 0 || h == 0 do w, h = max(i32), max(i32) // display size not known yet
	#reverse for &n, k in r.h.nodes {
		if !n.kept do n.kept = visible_pct(n, w, h) >= 0.1
		if n.kept && n.parent >= 0 do r.h.nodes[n.parent].kept = true
		_ = k
	}
	any_kept := false
	for &n in r.h.nodes do any_kept ||= n.kept
	if !any_kept do for &n in r.h.nodes do n.kept = true
	for &n, k in r.h.nodes do if n.kept && n.parent >= 0 do append(&r.h.nodes[n.parent].children, k)
	for root in r.h.roots do if r.h.nodes[root].kept do append(&r.h.order, ..subtree(r, root))
	r.reads += 1
	r.read_ms_total += us(t) / 1000
	if r.debug {
		first := ""
		for i in r.h.order do if r.h.nodes[i].text != "" { first = r.h.nodes[i].text; break }
		fmt.printf("      [read %.0f ms: %d nodes, %d roots, root0=%v first text %q]\n", us(t) / 1000, len(r.h.nodes), len(r.h.roots), r.h.nodes[r.h.roots[0]].class if len(r.h.roots) > 0 else "-", first)
	}
	return true
}

// SPEEDRUN_DEBUG: how long a step of a command took (since `t`, which moves to now).
debug_step :: proc(r: ^Runner, what: string, t: ^time.Tick) {
	if r.debug do fmt.printf("      [%s %.0f ms]\n", what, us(t^) / 1000)
	t^ = time.tick_now()
}

shell :: proc(r: ^Runner, format: string, args: ..any) -> string {
	t := time.tick_now()
	out, _ := op_shell(r.c, fmt.tprintf(format, ..args), r.alloc)
	if r.debug do fmt.printf("      [shell %.0f ms: %s -> %d bytes]\n", us(t) / 1000, fmt.tprintf(format, ..args), len(out))
	return out
}

// LaunchAppCommand: the package's launcher activity (cached).
launcher :: proc(r: ^Runner, app: string) -> (comp: string, err: Err) {
	if c, ok := r.launchers[app]; ok do return c, nil
	out := shell(r, "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER %s", app)
	lines := strings.split_lines(strings.trim_space(out), r.alloc)
	last := strings.trim_space(lines[len(lines) - 1]) if len(lines) > 0 else ""
	if !strings.contains(last, "/") {
		return "", fmt.aprintf("No launcher intent found for package %s (is it installed?)", app, allocator = r.alloc)
	}
	r.launchers[app] = last
	return last, nil
}

@(private = "file")
abs :: proc(v: int) -> int {
	return v if v >= 0 else -v
}

_ :: math
