// Runs Maestro flow files (see flow.odin) on the agent, with Maestro 2.11.0's semantics:
// element matching (Orchestra.buildFilter, maestro.Filters), lookup timeouts counted from the
// last interaction, conditions, env scopes, gestures and key codes (drivers/AndroidDriver).
// What differs is how: one agent round trip per hierarchy read and frame/event-driven settle
// instead of fixed sleeps and screenshot diffs.
package spike_host

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
}

Runner :: struct {
	c:                    ^Conn,
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
	debug:                bool, // SPIKE_DEBUG: print every hierarchy read and shell command
	view:                 View, // console output (console.odin)
	reads, read_ms_total: f64,
}

Rx :: struct {
	pattern: string,
	re:      regex.Regular_Expression,
	literal: bool, // does not compile: matched as plain text, like Maestro's toRegexSafe
}

// A failure message; nil means success.
Err :: Maybe(string)

SKIPPED :: "\x00skipped" // a command whose condition was false

// ---- entry ----------------------------------------------------------------------------

// Loads and runs `path`; `env` holds `-e KEY=VALUE` pairs. Writes per-command timings as
// JSON to `timings_path` if set. `plain`: one line per command even on a terminal.
// Returns false if the flow failed.
run_maestro_flow :: proc(c: ^Conn, path: string, cli_env: []Env_Pair, timings_path: string, plain := false) -> bool {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	context.allocator = alloc

	flow, err := load_flow(path, alloc)
	if err != "" {
		fmt.eprintln(err)
		return false
	}
	r := Runner {
		c     = c,
		alloc = alloc,
		debug = os.get_env("SPIKE_DEBUG", alloc) != "",
	}
	_ = virtual.arena_init_growing(&r.screen_arena)
	defer virtual.arena_destroy(&r.screen_arena)

	// Display size: the extent of all window roots, in the current orientation.
	if !read_screen(&r) {
		fmt.eprintln("could not read the screen")
		return false
	}
	for i in r.h.roots {
		r.w = max(r.w, r.h.nodes[i].right)
		r.h_px = max(r.h.nodes[i].bottom, r.h_px)
	}

	// Env: injected MAESTRO_* shell variables and -e values, then the flow's own `env:`.
	push_scope(&r)
	scope := &r.env[0]
	environ, _ := os.environ(alloc)
	for e in environ {
		if k, _, v := strings.partition(e, "="); strings.has_prefix(k, "MAESTRO_") do scope[k] = v
	}
	base := strings.trim_suffix(strings.trim_suffix(os_base(path), ".yaml"), ".yml")
	scope["MAESTRO_FILENAME"] = base
	for e in cli_env do scope[e.key] = e.value

	// "Running on <emulator name>", like Maestro.
	device := strings.trim_space(shell(&r, "getprop ro.boot.qemu.avd_name"))
	if device == "" do device = strings.trim_space(shell(&r, "getprop ro.product.model"))
	view_init(&r, &flow, flow.name if flow.name != "" else base, device, plain || r.debug)

	start := time.tick_now()
	r.last_interaction = start
	ok := true
	if e, bad := define_env(&r, flow.env[:]).?; bad {
		fmt.eprintln(e)
		ok = false
	}
	if ok && len(flow.on_start) > 0 do ok = run_list(&r, flow.on_start[:], "s")
	if ok do ok = run_list(&r, flow.commands[:])
	if len(flow.on_complete) > 0 do ok = run_list(&r, flow.on_complete[:], "c") && ok
	total := us(start) / 1000

	view_done(&r, fmt.tprintf(
		"%s in %s · %d commands · %d hierarchy reads, %.1f ms each",
		"✅ Flow passed" if ok else "❌ Flow failed", fmt_ms(total), len(r.records), int(r.reads),
		r.read_ms_total / max(r.reads, 1),
	))
	if timings_path != "" {
		data, merr := json.marshal(r.records[:], {pretty = true}, alloc)
		if merr != nil || !write_file(timings_path, data) do fmt.eprintln("could not write", timings_path)
	}
	return ok
}

@(private = "file")
os_base :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return path[i + 1:] if i >= 0 else path
}

@(private = "file")
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
		append(&r.records, Record{seq = seq, path = r.path, depth = r.depth, command = c.name, description = node.desc})
		view_started(r, node)
		t := time.tick_now()
		r.depth += 1
		mutating, err := exec(r, &c)
		r.depth -= 1
		rec := &r.records[seq]
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
		if d.clear_state do _ = shell(r, "pm clear %s", app)
		grant_runtime_permissions(r, app)
		if d.stop_app do _ = shell(r, "am force-stop %s", app)
		comp := launcher(r, app) or_return
		out := shell(r, "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n %s", comp)
		if strings.contains(out, "Error") do return true, strings.trim_space(out)
		return true, nil
	case App_Cmd:
		app := eval(r, d.app_id) or_return
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
		if !met do return false, fmt.aprintf("Assertion is false: %s\n%s", condition_description(d.cond), screen_summary(r), allocator = r.alloc)
		return false, nil
	case Input_Text:
		text := eval(r, d.text) or_return
		_, skipped, ok := op_type(r.c, text, r.alloc)
		if !ok do return true, "agent connection lost"
		if skipped > 0 {
			return true, fmt.aprintf("%d characters of \"%s\" have no key sequence (non-ASCII text is not supported yet)", skipped, text, allocator = r.alloc)
		}
		return true, settle(r)
	case Erase_Text:
		if _, ok := op_erase(r.c, i32(d.count)); !ok do return true, "agent connection lost"
		return true, settle(r)
	case Key_Press:
		if _, ok := op_key(r.c, d.keycode); !ok do return true, "agent connection lost"
		return true, settle(r)
	case Navigate:
		switch d {
		case .Back:
			if _, ok := op_key(r.c, KEYCODE_BACK); !ok do return true, "agent connection lost"
			return true, settle(r)
		case .Hide_Keyboard:
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
		_ = shell(r, "am start -a android.intent.action.VIEW -d %s", link)
		return true, settle(r)
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
		path := eval(r, d.path) or_return
		png, ok := op_screenshot(r.c, r.alloc)
		if !ok do return false, "agent connection lost"
		if !write_file(fmt.aprintf("%s.png", path, allocator = r.alloc), png) do return false, "cannot write the screenshot"
		return false, nil
	}
	return false, "unhandled command"
}

// A sub-flow: its own env scope, its env pairs, then onFlowStart, commands, onFlowComplete.
@(private = "file")
run_sub :: proc(r: ^Runner, s: Sub_Flow) -> (mutating: bool, err: Err) {
	push_scope(r)
	defer pop(&r.env)
	if e := define_env(r, s.env[:]); e != nil do return false, e
	before := len(r.records)
	ok := true
	if len(s.on_start) > 0 do ok = run_list(r, s.on_start[:], "s")
	if ok do ok = run_list(r, s.commands[:])
	if len(s.on_complete) > 0 do ok = run_list(r, s.on_complete[:], "c") && ok
	for rec in r.records[before:] do if rec.status != "SKIPPED" do mutating = true
	if !ok do return mutating, "a command in the sub-flow failed"
	return mutating, nil
}

@(private = "file")
tap :: proc(r: ^Runner, c: ^Cmd, d: Tap) -> Err {
	x, y: i32
	if d.sel == nil {
		p := eval(r, d.point) or_return
		ok: bool
		x, y, ok = parse_point(p, r.w, r.h_px)
		if !ok do return fmt.aprintf("invalid point `%s`", p, allocator = r.alloc)
	} else {
		el := find_element(r, d.sel, c.optional, -1) or_return
		n := r.h.nodes[el]
		x, y = n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2
		if d.point != "" {
			p := eval(r, d.point) or_return
			ok: bool
			x, y, ok = relative_point(p, n)
			if !ok do return fmt.aprintf("invalid element-relative point `%s`", p, allocator = r.alloc)
		}
	}
	before := r.h.hash
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
		if e := settle(r, d.settle_ms); e != nil do return e
		if !d.retry do break
		if !read_screen(r) do return "agent connection lost"
		if r.h.hash != before do break
	}
	return nil
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
	for {
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
		cx, cy := r.w / 2, r.h_px / 2
		ex, ey := edge_point(r, cx, cy, dir)
		if e := swipe_points(r, cx, cy, ex, ey, i32(duration), d.settle_ms); e != nil do return e
		if time.tick_now()._nsec >= end do break
	}
	return fmt.aprintf("No visible element found: %s\n%s", selector_description(d.sel), screen_summary(r), allocator = r.alloc)
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

@(private = "file")
settle :: proc(r: ^Runner, timeout_ms: Maybe(int) = nil) -> Err {
	timeout := i32(SETTLE_TIMEOUT_MS)
	if t, has := timeout_ms.?; has do timeout = i32(t)
	if _, ok := op_settle(r.c, SETTLE_QUIET_MS, SETTLE_NO_CHANGE_MS, timeout); !ok do return "agent connection lost"
	return nil
}

// ---- conditions and lookups -----------------------------------------------------------

// Orchestra.evaluateCondition. `timeout` < 0: the default for conditions (7 s), always
// shortened by the time since the last interaction.
@(private = "file")
condition_met :: proc(r: ^Runner, cond: Condition, optional: bool, timeout: i64) -> (met: bool, err: Err) {
	if p, has := cond.platform.?; has && !strings.equal_fold(p, "android") do return false, nil
	if s, has := cond.script.?; has {
		v := eval(r, s) or_return
		if v == "" || strings.equal_fold(v, "false") || v == "undefined" || v == "null" do return false, nil
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
@(private = "file")
find_element :: proc(r: ^Runner, sel: ^Selector, optional: bool, timeout: i64) -> (idx: int, err: Err) {
	limit := timeout if timeout >= 0 else adjusted(r, OPTIONAL_LOOKUP_TIMEOUT_MS if optional else LOOKUP_TIMEOUT_MS)
	i, found := try_find(r, sel, limit) or_return
	if !found {
		return -1, fmt.aprintf("Element not found: %s\n%s", filter_description(sel), screen_summary(r), allocator = r.alloc)
	}
	return i, nil
}

// One read at least (Maestro's do-while), then re-reads until found or `timeout_ms` passes.
@(private = "file")
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
@(private = "file")
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
	has_basic := text_rx != nil || id_rx != nil || hw || hh || he || hs || hc || hf

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
@(private = "file")
rx_full :: proc(rx: ^Rx, value: string) -> bool {
	if rx.literal do return strings.equal_fold(rx.pattern, value)
	if value == rx.pattern do return true
	cap, ok := regex.match(rx.re, value, context.temp_allocator, context.temp_allocator)
	_ = cap
	return ok
}

// Java patterns Odin's regex engine lacks: rejected rather than matched differently.
JAVA_ONLY_REGEX :: []string{"(?=", "(?!", "(?<=", "(?<!", "(?<", "(?i", "(?s", "(?m", "(?u", "(?x", "\\p{", "\\P{", "\\Q", "\\k<", "++", "*+", "?+", "}+"}

@(private = "file")
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

@(private = "file")
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
}

@(private = "file")
define_env :: proc(r: ^Runner, pairs: []Env_Pair) -> Err {
	for p in pairs {
		v := eval(r, p.value) or_return
		r.env[len(r.env) - 1][p.key] = v
	}
	return nil
}

// Replaces `${NAME}` with the variable's value (`\${` stays literal). Maestro evaluates
// `${...}` as JavaScript; only plain variable names are supported here, anything else is
// an error naming the expression.
@(private = "file")
eval :: proc(r: ^Runner, s: string) -> (out: string, err: Err) {
	if !strings.contains(s, "${") do return s, nil
	b := strings.builder_make(r.alloc)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && strings.has_prefix(s[i + 1:], "${") {
			strings.write_string(&b, "${")
			i += 3
			continue
		}
		if !strings.has_prefix(s[i:], "${") {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		close := strings.index_byte(s[i:], '}')
		if close < 0 {
			strings.write_string(&b, s[i:])
			break
		}
		expr := strings.trim_space(s[i + 2:i + close])
		i += close + 1
		if expr == "" do continue
		for c in expr {
			if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
				// (not fmt: it reads `{` as a format directive)
				return "", strings.concatenate({"`${", expr, "}`: JavaScript expressions are not supported, only `${NAME}`"}, r.alloc)
			}
		}
		found := false
		#reverse for scope in r.env {
			if v, ok := scope[expr]; ok {
				strings.write_string(&b, v)
				found = true
				break
			}
		}
		if !found do return "", strings.concatenate({"`${", expr, "}`: variable is not defined"}, r.alloc)
	}
	return strings.to_string(b), nil
}

// ---- device ---------------------------------------------------------------------------

// Reads every window into r.h and applies Maestro's bounds filter.
read_screen :: proc(r: ^Runner) -> bool {
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
	// filterOutOfBounds: drop nodes less than 10% on screen whose children are all dropped.
	w, h := r.w, r.h_px
	if w == 0 || h == 0 do w, h = max(i32), max(i32) // first read, display size not known yet
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

@(private = "file")
shell :: proc(r: ^Runner, format: string, args: ..any) -> string {
	t := time.tick_now()
	out, _ := op_shell(r.c, fmt.tprintf(format, ..args), r.alloc)
	if r.debug do fmt.printf("      [shell %.0f ms: %s -> %d bytes]\n", us(t) / 1000, fmt.tprintf(format, ..args), len(out))
	return out
}

// LaunchAppCommand: the package's launcher activity (cached).
@(private = "file")
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

// Maestro grants every permission in the manifest on launch (pm grant per permission;
// only runtime permissions can change). Same end state, faster: grant the runtime ones
// that are not granted yet, plus MANAGE_EXTERNAL_STORAGE through appops.
@(private = "file")
grant_runtime_permissions :: proc(r: ^Runner, app: string) {
	out := shell(r, "dumpsys package %s", app)
	for line in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_suffix(l, "granted=false") || strings.contains(l, ": granted=false,") {
			perm, _, _ := strings.partition(l, ":")
			_ = shell(r, "pm grant %s %s", app, perm)
		}
		if l == "android.permission.MANAGE_EXTERNAL_STORAGE" {
			_ = shell(r, "appops set %s MANAGE_EXTERNAL_STORAGE allow", app)
		}
	}
}

@(private = "file")
abs :: proc(v: int) -> int {
	return v if v >= 0 else -v
}

_ :: math
