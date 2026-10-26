// Console output for flows: a live view redrawn in place on a terminal, one line per command
// otherwise. Descriptions use the wording flow authors know; each command also shows its
// time.
package speedrun

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

Status :: enum u8 {
	Pending,
	Running,
	Completed,
	Failed,
	Warned,
	Skipped,
}

View_Node :: struct {
	cmd:                   ^Cmd,
	desc:                  string,
	status:                Status,
	runs:                  int, // repeat iterations done
	ms:                    f64,
	error:                 string,
	logs:                  [dynamic]string, // console.log lines of its scripts
	depth:                 int,
	children:              [dynamic]^View_Node, // runFlow / repeat / retry commands
	on_start, on_complete: [dynamic]^View_Node, // a sub-flow file's hooks
}

View :: struct {
	live:                     bool, // stdout is a terminal: redraw in place
	silent:                   bool, // a flow of a suite: only one line per flow
	device, flow_name:        string,
	main, on_start, on_comp:  [dynamic]^View_Node,
	nodes:                    map[^Cmd]^View_Node,
	prev_lines:               int,
	rows, cols:               int,
	footer:                   string,
}

@(private = "file")
CYAN :: "\x1b[36m"
@(private = "file")
RED :: "\x1b[31m"
@(private = "file")
YELLOW :: "\x1b[33m"
@(private = "file")
DIM :: "\x1b[2m"
@(private = "file")
RESET :: "\x1b[0m"

view_init :: proc(r: ^Runner, flow: ^Flow, flow_name, device: string, plain: bool, silent := false) {
	v := &r.view
	v.silent = silent
	v.live = !plain && !silent && os.is_tty(os.stdout)
	v.flow_name, v.device = flow_name, device
	v.nodes = make(map[^Cmd]^View_Node, 64, r.alloc)
	v.on_start = view_nodes(r, flow.on_start[:], 0)
	v.main = view_nodes(r, flow.commands[:], 0)
	v.on_comp = view_nodes(r, flow.on_complete[:], 0)
	v.rows, v.cols = terminal_size()
	if silent do return
	if v.live {
		view_render(r)
	} else {
		fmt.printf("Running on %s\n", device)
	}
}

// Plain mode: a section header before a list of commands runs.
view_section :: proc(r: ^Runner, section: string) {
	if r.view.live || r.view.silent do return
	switch section {
	case "s": fmt.printf("%s  > On Flow Start\n", pad(r.depth))
	case "c": fmt.printf("%s  > On Flow Complete\n", pad(r.depth))
	case:     if r.depth == 0 do fmt.printf(" > Flow %s\n", r.view.flow_name)
	}
}

@(private = "file")
view_nodes :: proc(r: ^Runner, cmds: []Cmd, depth: int) -> (out: [dynamic]^View_Node) {
	out.allocator = r.alloc
	for &c in cmds {
		n := new(View_Node, r.alloc)
		n.cmd, n.depth, n.desc = &c, depth, command_description(r, &c)
		switch d in c.data {
		case Run_Flow:
			n.on_start = view_nodes(r, d.on_start[:], depth + 1)
			n.children = view_nodes(r, d.commands[:], depth + 1)
			n.on_complete = view_nodes(r, d.on_complete[:], depth + 1)
		case Retry:
			n.on_start = view_nodes(r, d.on_start[:], depth + 1)
			n.children = view_nodes(r, d.commands[:], depth + 1)
			n.on_complete = view_nodes(r, d.on_complete[:], depth + 1)
		case Repeat:
			n.children = view_nodes(r, d.commands[:], depth + 1)
		case Launch_App, App_Cmd, Tap, Assert, Input_Text, Erase_Text, Key_Press, Navigate,
		     Scroll_Until, Swipe, Wait_Animation, Open_Link, Screenshot, Eval_Script, Run_Script,
		     Copy_Text, Set_Clipboard, Paste_Text, Set_Permissions, Input_Random, Set_Orientation, Device_Mode,
		     Assert_Screenshot, Start_Recording, Stop_Recording, Add_Media, Set_Location, Travel:
		}
		r.view.nodes[&c] = n
		append(&out, n)
	}
	return out
}

// Pending again for the next pass of a repeat or retry.
view_reset :: proc(nodes: []^View_Node) {
	for n in nodes {
		n.status, n.runs, n.ms, n.error = .Pending, 0, 0, ""
		clear(&n.logs)
		view_reset(n.children[:])
		view_reset(n.on_start[:])
		view_reset(n.on_complete[:])
	}
}

view_started :: proc(r: ^Runner, n: ^View_Node) {
	n.status = .Running
	if r.view.silent do return
	if r.view.live {
		view_render(r)
	} else if is_container(n) {
		fmt.printf("%s%s...\n", pad(n.depth), n.desc)
	}
}

view_finished :: proc(r: ^Runner, n: ^View_Node) {
	if r.view.silent do return
	if r.view.live {
		view_render(r)
		return
	}
	// Plain: the command's line, then its time.
	runs := fmt.tprintf(" (completed %d %s)", n.runs, "time" if n.runs == 1 else "times") if n.runs > 0 else ""
	fmt.printf("%s%s... %s%s  %s\n", pad(n.depth), n.desc, status_word(n.status), runs, fmt_ms(n.ms))
	if len(n.logs) > 0 {
		fmt.printf("%s    Log messages:\n", pad(n.depth))
		for line in n.logs do fmt.printf("%s      %s\n", pad(n.depth), line)
	}
	if own_error(n) != "" do print_error(n)
}

view_done :: proc(r: ^Runner, footer: string) {
	r.view.footer = footer
	if r.view.silent do return
	if r.view.live {
		view_render(r)
		// The failure's message in full below the view.
		failed :: proc(nodes: []^View_Node) {
			for n in nodes {
				if n.status != .Failed do continue
				if e := own_error(n); e != "" do fmt.printf("\n%s%s%s\n", RED, e, RESET)
				failed(n.on_start[:]); failed(n.children[:]); failed(n.on_complete[:])
			}
		}
		failed(r.view.on_start[:]); failed(r.view.main[:]); failed(r.view.on_comp[:])
	} else {
		fmt.printf("\n%s\n", footer)
	}
}

@(private = "file")
is_container :: proc(n: ^View_Node) -> bool {
	#partial switch _ in n.cmd.data {
	case Run_Flow, Repeat, Retry:
		return true
	}
	return false
}

// ---- live view ------------------------------------------------------------------------

@(private = "file")
view_render :: proc(r: ^Runner) {
	v := &r.view
	lines := make([dynamic]string, 0, 64, context.temp_allocator)
	focus := -1 // line of the deepest running command, kept on screen
	append(&lines, fmt.tprintf("Running on %s", v.device), "")
	if len(v.on_start) > 0 {
		append(&lines, " ║", " ║  > On Flow Start", " ║")
		render_nodes(v, v.on_start[:], &lines, &focus)
	}
	append(&lines, " ║", fmt.tprintf(" ║  > Flow: %s", v.flow_name), " ║")
	header := len(lines)
	render_nodes(v, v.main[:], &lines, &focus)
	if len(v.on_comp) > 0 {
		append(&lines, " ║", " ║  > On Flow Complete", " ║")
		render_nodes(v, v.on_comp[:], &lines, &focus)
	}
	append(&lines, " ║")
	if v.footer != "" do append(&lines, fmt.tprintf(" ║  %s", v.footer))

	// Taller than the terminal: keep the header and a window around the running command.
	limit := max(v.rows - 1, header + 6)
	if len(lines) > limit && v.footer == "" {
		body := lines[header:]
		room := limit - header - 2
		at := clamp((focus if focus >= 0 else header) - header - room / 3, 0, max(len(body) - room, 0))
		window := make([dynamic]string, 0, limit, context.temp_allocator)
		append(&window, ..lines[:header])
		append(&window, fmt.tprintf(" ║    %s… %d above%s", DIM, at, RESET) if at > 0 else " ║")
		append(&window, ..body[at:min(at + room, len(body))])
		below := len(body) - min(at + room, len(body))
		append(&window, fmt.tprintf(" ║    %s… %d more%s", DIM, below, RESET) if below > 0 else " ║")
		lines = window
	}

	b := strings.builder_make(context.temp_allocator)
	if v.prev_lines > 0 do fmt.sbprintf(&b, "\x1b[%dF", v.prev_lines)
	for line in lines {
		strings.write_string(&b, "\x1b[2K")
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, "\x1b[J")
	os.write_string(os.stdout, strings.to_string(b))
	v.prev_lines = len(lines)
}

@(private = "file")
render_nodes :: proc(v: ^View, nodes: []^View_Node, lines: ^[dynamic]string, focus: ^int) {
	for n in nodes {
		if n.status == .Running do focus^ = len(lines)
		append(lines, command_line(v, n))
		// Its log lines (console.log) below it.
		if len(n.logs) > 0 {
			append(lines, fmt.tprintf(" ║    %s     %sLog messages:%s", pad(n.depth), YELLOW, RESET))
			for line in n.logs do append(lines, fmt.tprintf(" ║    %s       %s", pad(n.depth), line))
		}
		// First line of the error under the command; a failure's full text follows the last frame.
		if e := own_error(n); e != "" && (n.status == .Failed || n.status == .Warned) {
			first, _, _ := strings.partition(e, "\n")
			if n.status == .Warned do first = fmt.tprintf("Warning: %s", first)
			first = ellipsize(first, max(v.cols - 11 - 2 * n.depth, 10))
			append(lines, fmt.tprintf(" ║    %s     %s%s%s", pad(n.depth), RED if n.status == .Failed else YELLOW, first, RESET))
		}
		// Sub-commands show while their container runs (or failed).
		started :: proc(list: []^View_Node) -> bool {
			for c in list do if c.status != .Pending do return true
			return false
		}
		if (n.status == .Running || n.status == .Failed) &&
		   (started(n.children[:]) || started(n.on_start[:]) || started(n.on_complete[:])) {
			if len(n.on_start) > 0 do render_nodes(v, n.on_start[:], lines, focus)
			render_nodes(v, n.children[:], lines, focus)
			if len(n.on_complete) > 0 do render_nodes(v, n.on_complete[:], lines, focus)
		}
	}
}

@(private = "file")
command_line :: proc(v: ^View, n: ^View_Node) -> string {
	symbol: string
	switch n.status {
	case .Completed: symbol = "✅"
	case .Failed:    symbol = "❌"
	case .Running:   symbol = "⏳"
	case .Pending:   symbol = "🔲"
	case .Warned:    symbol = "⚠️"
	case .Skipped:   symbol = "⚪️"
	}
	time := ""
	if n.status != .Pending && n.status != .Running do time = fmt.tprintf("  %s%s%s", DIM, fmt_ms(n.ms), RESET)
	// Fit to the terminal width: prefix (6 + indent), symbol (2 columns) and 3 spaces.
	used := 6 + 2 * n.depth + 5
	desc := ellipsize(n.desc, max(v.cols - used - len(suffix(n)) - 12, 10))
	return fmt.tprintf(" ║    %s%s   %s%s%s", pad(n.depth), symbol, highlight(desc), suffix(n), time)
}

// Unresolved ${...} in cyan.
@(private = "file")
highlight :: proc(s: string) -> string {
	if !strings.contains(s, "${") do return s
	b := strings.builder_make(context.temp_allocator)
	rest := s
	for {
		i := strings.index(rest, "${")
		if i < 0 do break
		j := strings.index_byte(rest[i:], '}')
		if j < 0 do break
		strings.write_string(&b, rest[:i])
		strings.write_string(&b, CYAN)
		strings.write_string(&b, rest[i:i + j + 1])
		strings.write_string(&b, RESET)
		rest = rest[i + j + 1:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// ---- shared ---------------------------------------------------------------------------

@(private = "file")
// Cuts s to at most room characters, ending with "…" when cut.
ellipsize :: proc(s: string, room: int) -> string {
	k := 0
	for _, i in s {
		if k == room - 1 && utf8.rune_count_in_string(s[i:]) > 1 do return fmt.tprintf("%s…", s[:i])
		k += 1
	}
	return s
}

// A container's own error only says that a sub-command failed: that sub-command shows it.
own_error :: proc(n: ^View_Node) -> string {
	for list in ([3][]^View_Node{n.on_start[:], n.children[:], n.on_complete[:]}) {
		for c in list do if c.status == .Failed do return ""
	}
	return n.error
}

print_error :: proc(n: ^View_Node) {
	for e in strings.split_lines(n.error, context.temp_allocator) do fmt.printf("%s    %s\n", pad(n.depth), e)
}

@(private = "file")
suffix :: proc(n: ^View_Node) -> string {
	#partial switch n.status {
	case .Skipped:
		return " (skipped)"
	case .Warned:
		return " (warned)"
	}
	if n.runs > 0 do return fmt.tprintf(" (completed %d %s)", n.runs, "time" if n.runs == 1 else "times")
	return ""
}

@(private = "file")
status_word :: proc(s: Status) -> string {
	switch s {
	case .Completed: return "COMPLETED"
	case .Failed:    return "FAILED"
	case .Running:   return "RUNNING"
	case .Pending:   return "PENDING"
	case .Skipped:   return "SKIPPED"
	case .Warned:    return "WARNED"
	}
	return ""
}

@(private = "file")
pad :: proc(depth: int) -> string {
	return strings.repeat("  ", depth, context.temp_allocator)
}

fmt_ms :: proc(ms: f64) -> string {
	if ms >= 1000 do return fmt.tprintf("%.1f s", ms / 1000)
	return fmt.tprintf("%.0f ms", ms)
}

// ---- command descriptions (the wording flow authors know) -----------------------------

command_description :: proc(r: ^Runner, c: ^Cmd) -> string {
	if c.label != "" do return c.label
	opt := "(Optional) " if c.optional else ""
	s: string
	switch d in c.data {
	case Tap:
		word := "Tap"
		if d.long_press {
			word = "Long press"
		} else if d.repeat == 2 {
			word = "Double tap"
		} else if d.repeat > 2 {
			word = fmt.tprintf("Tap x%d", d.repeat)
		}
		if d.sel == nil {
			s = fmt.tprintf("%s on point (%s)", word, d.point)
		} else {
			at := fmt.tprintf(" at %s", d.point) if d.point != "" else ""
			s = fmt.tprintf("%s on %s%s%s", word, opt, selector_description(d.sel), at)
		}
	case Assert:
		s = fmt.tprintf("Assert that %s%s", opt, condition_description(d.cond))
	case Navigate:
		switch d {
		case .Back:           s = "Press back"
		case .Hide_Keyboard:  s = "Hide Keyboard"
		case .Scroll:         s = "Scroll vertically"
		case .Clear_Keychain: s = "Clear keychain"
		}
	case Scroll_Until:
		settle := ""
		if ms, has := d.settle_ms.?; has do settle = fmt.tprintf(", wait to settle %d ms", ms)
		s = fmt.tprintf(
			"Scrolling %s until %s is visible with speed %s, visibility percentage %d%%, timeout %s ms%s, with centering %s",
			dir_word(d.direction), selector_description(d.sel), d.speed, d.visibility, d.timeout, settle,
			"enabled" if d.center else "disabled",
		)
	case Swipe:
		if dir, has := d.direction.?; has {
			if d.from != nil {
				at := fmt.tprintf(" at %s", d.from.point) if d.from.point != "" else ""
				s = fmt.tprintf("Swiping in %s direction on %s%s", dir_word(dir), selector_description(d.from), at)
			} else {
				s = fmt.tprintf("Swiping in %s direction in %d ms", dir_word(dir), d.duration)
			}
		} else if strings.contains(d.start, "%") {
			s = fmt.tprintf("Swipe from (%s) to (%s) in %d ms", d.start, d.end, d.duration)
		} else {
			compact :: proc(p: string) -> string {
				out, _ := strings.replace_all(p, " ", "", context.temp_allocator)
				return out
			}
			s = fmt.tprintf("Swipe from (%s) to (%s) in %d ms", compact(d.start), compact(d.end), d.duration)
		}
	case Input_Text:
		s = fmt.tprintf("Input text %s", d.text)
	case Erase_Text:
		s = fmt.tprintf("Erase %d characters", d.count) if d.explicit else "Erase text"
	case Key_Press:
		for k in KEYS do if k.code == d.keycode do s = fmt.tprintf("Press %s key", k.name)
	case Launch_App:
		s = fmt.tprintf(
			"Launch app \"%s\"%s%s%s", d.app_id, " with clear state" if d.clear_state else "",
			" and clear keychain" if d.clear_keychain else "", " without stopping app" if !d.stop_app else "",
		)
		if d.has_arguments {
			// Kotlin's Map.toString: {key=value, other=value}
			b := strings.builder_make(context.temp_allocator)
			for a, i in d.arguments do fmt.sbprintf(&b, "%s%s=%s", ", " if i > 0 else "", a.key, a.value)
			s = strings.concatenate({s, " (launch arguments: {", strings.to_string(b), "})"}, context.temp_allocator)
		}
	case Set_Permissions:
		s = "Set permissions"
	case Input_Random:
		s = fmt.tprintf("Input text random %v", d.kind)
	case Set_Orientation:
		name, known := orientation_by_name(d.orientation)
		s = fmt.tprintf("Set orientation %s", name if known else d.orientation)
	case Device_Mode:
		switch d.op {
		case .Airplane_On:     s = "Enable airplane mode"
		case .Airplane_Off:    s = "Disable airplane mode"
		case .Airplane_Toggle: s = "Toggle airplane mode"
		case .Dark_On:         s = "Enable dark mode"
		case .Dark_Off:        s = "Disable dark mode"
		case .Dark_Toggle:     s = "Toggle dark mode"
		case .Assert_Dark:     s = "Assert dark mode is enabled"
		case .Assert_Light:    s = "Assert dark mode is disabled"
		}
	case App_Cmd:
		switch d.op {
		case .Stop:        s = fmt.tprintf("Stop %s", d.app_id)
		case .Kill:        s = fmt.tprintf("Kill %s", d.app_id)
		case .Clear_State: s = fmt.tprintf("Clear state of %s", d.app_id)
		}
	case Run_Flow:
		s = fmt.tprintf("Run %s", d.source) if d.source != "" else "Run flow"
		if cond, has := d.cond.?; has do s = fmt.tprintf("%s when %s", s, condition_description(cond))
	case Repeat:
		times := 1
		if t, has := d.times.?; has {
			if v, ok := parse_int_strict(t); ok do times = v
		}
		cond, has_cond := d.cond.?
		switch {
		case has_cond && times > 1: s = fmt.tprintf("Repeat while %s (up to %d times)", condition_description(cond), times)
		case has_cond:              s = fmt.tprintf("Repeat while %s", condition_description(cond))
		case times > 1:             s = fmt.tprintf("Repeat %d times", times)
		case:                       s = "Repeat indefinitely"
		}
	case Retry:
		n, ok := parse_int_strict(d.max_retries)
		if !ok do n = 1
		s = fmt.tprintf("Retry %s%d times", fmt.tprintf("%s ", d.source) if d.source != "" else "", n)
	case Screenshot:
		s = fmt.tprintf("Take screenshot %s", d.path)
		if d.crop_on != nil do s = fmt.tprintf("%s, cropped to %s", s, selector_description(d.crop_on))
	case Assert_Screenshot:
		s = fmt.tprintf("Assert screenshot matches %s (threshold: %s%%)", d.path, d.threshold)
		if d.crop_on != nil do s = fmt.tprintf("%s (cropped on %s)", s, selector_description(d.crop_on))
	case Start_Recording:
		s = fmt.tprintf("Start recording %s", d.path)
	case Stop_Recording:
		s = "Stop recording"
	case Add_Media:
		s = fmt.tprintf("Adding media files(%d) to the device", len(d.files))
	case Set_Location:
		s = fmt.tprintf("Set location (%s, %s)", d.latitude, d.longitude)
	case Travel:
		b := strings.builder_make(context.temp_allocator)
		for p, i in d.points {
			fmt.sbprintf(&b, "%s(%s, %s)", ", " if i > 0 else "", kotlin_double(p[0], context.temp_allocator), kotlin_double(p[1], context.temp_allocator))
		}
		s = fmt.tprintf("Travel path %s", strings.to_string(b))
	case Wait_Animation:
		s = "Wait for animation to end"
		if t, has := d.timeout.?; has do s = fmt.tprintf("%s within %s ms", s, t)
	case Open_Link:
		s = fmt.tprintf("Open %s%s%s", d.link, " with auto verification" if d.auto_verify else "", " in browser" if d.browser else "")
	case Eval_Script:
		s = fmt.tprintf("Run %s", d.script)
	case Run_Script:
		s = fmt.tprintf("Run %s", d.file)
		if cond, has := d.cond.?; has do s = fmt.tprintf("%s when %s", s, condition_description(cond))
	case Copy_Text:
		s = fmt.tprintf("Copy text from element with %s", selector_description(d.sel))
	case Set_Clipboard:
		s = fmt.tprintf("Set clipboard to %s", d.text)
	case Paste_Text:
		s = "Paste text"
	}
	return strings.clone(s, r.alloc)
}

// ElementTrait.description, joined.
trait_names :: proc(traits: []Trait) -> string {
	names := make([dynamic]string, 0, len(traits), context.temp_allocator)
	for t in traits {
		switch t {
		case .TEXT:      append(&names, "Has text")
		case .SQUARE:    append(&names, "Is square")
		case .LONG_TEXT: append(&names, "Has long text")
		}
	}
	return strings.join(names[:], ", ", context.temp_allocator)
}

selector_description :: proc(s: ^Selector) -> string {
	parts := make([dynamic]string, 0, 4, context.temp_allocator)
	if t, ok := s.text.?; ok do append(&parts, fmt.tprintf("\"%s\"", t))
	if t, ok := s.id.?; ok do append(&parts, fmt.tprintf("id: %s", t))
	if v, ok := s.enabled.?; ok do append(&parts, "enabled" if v else "disabled")
	if s.below != nil do append(&parts, fmt.tprintf("Below %s", selector_description(s.below)))
	if s.above != nil do append(&parts, fmt.tprintf("Above %s", selector_description(s.above)))
	if s.left_of != nil do append(&parts, fmt.tprintf("Left of %s", selector_description(s.left_of)))
	if s.right_of != nil do append(&parts, fmt.tprintf("Right of %s", selector_description(s.right_of)))
	if s.contains_child != nil do append(&parts, fmt.tprintf("Contains child: %s", selector_description(s.contains_child)))
	if len(s.contains_descendants) > 0 {
		ds := make([dynamic]string, 0, len(s.contains_descendants), context.temp_allocator)
		for d in s.contains_descendants do append(&ds, selector_description(d))
		append(&parts, fmt.tprintf("Contains descendants: [%s]", strings.join(ds[:], ", ", context.temp_allocator)))
	}
	w, hw := s.width.?
	h, hh := s.height.?
	if hw || hh {
		size := fmt.tprintf("Size: %vx%v", w if hw else 0, h if hh else 0)
		if t, ok := s.tolerance.?; ok do size = fmt.tprintf("%s(tolerance: %d)", size, t)
		append(&parts, size)
	}
	if len(s.traits) > 0 do append(&parts, fmt.tprintf("Has traits: %s", trait_names(s.traits[:])))
	if t, ok := s.index.?; ok {
		n, iok := parse_int_strict(t)
		append(&parts, fmt.tprintf("Index: %d", n) if iok else fmt.tprintf("Index: %s", t))
	}
	if v, ok := s.checked.?; ok do append(&parts, "checked" if v else "not checked")
	if v, ok := s.selected.?; ok do append(&parts, "selected" if v else "not selected")
	if v, ok := s.focused.?; ok do append(&parts, "focused" if v else "not focused")
	if s.child_of != nil do append(&parts, fmt.tprintf("Child of: %s", selector_description(s.child_of)))
	return strings.join(parts[:], ", ", context.temp_allocator)
}

condition_description :: proc(c: Condition) -> string {
	parts := make([dynamic]string, 0, 3, context.temp_allocator)
	if p, ok := c.platform.?; ok do append(&parts, fmt.tprintf("Platform is %s", p))
	if c.visible != nil do append(&parts, fmt.tprintf("%s is visible", selector_description(c.visible)))
	if c.not_visible != nil do append(&parts, fmt.tprintf("%s is not visible", selector_description(c.not_visible)))
	if s, ok := c.script.?; ok do append(&parts, fmt.tprintf("%s is true", s))
	if len(parts) == 0 do return "true"
	return strings.join(parts[:], " and ", context.temp_allocator)
}

@(private = "file")
dir_word :: proc(d: Swipe_Dir) -> string {
	switch d {
	case .Up:    return "UP"
	case .Down:  return "DOWN"
	case .Left:  return "LEFT"
	case .Right: return "RIGHT"
	}
	return ""
}

// Kotlin's toIntOrNull / toDouble().toInt(): "2" and "2.0" are 2, "${TIMES}" is not a number.
@(private = "file")
parse_int_strict :: proc(s: string) -> (int, bool) {
	t := strings.trim_space(s)
	if t == "" do return 0, false
	for ch in t do if !(ch >= '0' && ch <= '9') && ch != '-' && ch != '.' do return 0, false
	n := 0
	neg := false
	for ch, i in t {
		if ch == '-' && i == 0 {
			neg = true
			continue
		}
		if ch == '.' do break
		if ch < '0' || ch > '9' do return 0, false
		n = n * 10 + int(ch - '0')
	}
	return -n if neg else n, true
}

// ---- terminal size --------------------------------------------------------------------

when ODIN_OS == .Darwin || ODIN_OS == .Linux {
	foreign import libc "system:c"

	@(private = "file")
	Winsize :: struct {
		rows, cols, xpixel, ypixel: u16,
	}

	@(default_calling_convention = "c", private = "file")
	foreign libc {
		ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	}

	@(private = "file")
	TIOCGWINSZ :: 0x40087468 when ODIN_OS == .Darwin else 0x5413

	terminal_size :: proc() -> (rows, cols: int) {
		ws: Winsize
		if ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.rows > 0 && ws.cols > 0 do return int(ws.rows), int(ws.cols)
		return 50, 120
	}
} else {
	terminal_size :: proc() -> (rows, cols: int) {
		return 50, 120
	}
}
