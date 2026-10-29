// speedrun: runs flow files on Android and iOS through an on-device agent, over one
// persistent TCP connection (forwarded by `adb forward`), and measures where every
// millisecond goes. Usage: see USAGE below.
package speedrun

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Op :: enum u8 {
	Ping   = 1,
	Tree   = 2,
	Tap    = 3,
	Key    = 4,
	Settle = 5,
	Find   = 6,
	Swipe  = 7,
	Type   = 8,
	Erase      = 9,
	Screen     = 10,
	Shell      = 11,
	Mark       = 12,
	Press      = 13,
	Screenshot = 14,
	Quit       = 15, // iOS agent: stop the runner
	Info       = 16, // iOS agent: simulator udid and name, build
	Launched   = 17, // wait for a launched app to be ready
	Orientation = 18, // iOS agent: rotate the device (UIDeviceOrientation)
	Appearance  = 19, // iOS agent: read or set light/dark mode
	Location    = 20, // Android agent: test-provider location, re-sent on a timer
	Label       = 21, // Android agent: an app's name in the device's language
	Perms       = 22, // Android agent: the permissions an app requests, and their state
	Taps        = 23, // iOS agent: repeated taps as one gesture
	Hit         = 24, // iOS agent: the node of the last screen read a touch at a point reaches
}

KEYCODE_BACK :: 4

// speedrun --licenses: its license and those of the third-party code built into it, which a
// binary on its own carries no file for.
LICENSES ::
	#load("../NOTICE", string) +
	"\n==== speedrun: Apache License 2.0\n\n" + #load("../LICENSE", string) +
	"\n==== QuickJS-ng: MIT License\n\n" + #load("js/quickjs-ng/LICENSE", string) +
	"\n==== Datafaker: Apache License 2.0\n\n" + #load("js/datafaker/LICENSE", string) +
	"\n==== stb_image, stb_image_write\n\n" + #load("image/build/LICENSE.txt", string)

// The release: build.sh passes it (-define:SPEEDRUN_VERSION=...), from SPEEDRUN_VERSION or git.
VERSION :: #config(SPEEDRUN_VERSION, "dev")

// Settle tuning. "Quiet" means no new frame for ~2 frames at 60 Hz plus an idle-main-thread
// probe. After an accessibility event the agent waits 120 ms instead (apps send them at most
// every ~100 ms); on Android 12+ frame stats stay empty, so events are what it mostly sees.
SETTLE_QUIET_MS     :: 34
SETTLE_NO_CHANGE_MS :: 1000 // only paid when a tap really does nothing
// After typing: the keys were delivered when the op returned (iOS: before the settle
// concludes), so an app reacting late is less of a worry; paid where the field's text is not
// exposed (React Native groups it with its label), where nothing a flow can read changes.
SETTLE_TYPED_NO_CHANGE_MS :: 300
SETTLE_TIMEOUT_MS   :: 10_000

Flag :: enum u8 {
	Clickable,
	Enabled,
	Focused,
	Scrollable,
	Checked,
	Visible,
	Selected,
	Restless, // iOS: moving on every read, an endless animation (its frame is left out of the hash)
}
Flags :: bit_set[Flag; u8]

Node :: struct {
	left, top, right, bottom: i32,
	depth:                    u16,
	flags:                    Flags,
	text, desc, id, class:    string,
	hint, error:              string,
}

// Struct-of-arrays: a selector scan over `text` touches only the text column.
Tree :: #soa[dynamic]Node

Settle_Status :: enum u8 {
	Settled,   // UI changed, then went quiet
	No_Change, // nothing changed after the action
	Timeout,
}

Settle_Method :: enum u8 {
	Frames,     // window switches, frame stats and accessibility events + main-thread idle probe
	Events,     // accessibility-event fallback
	Quiescence, // iOS: XCTest's quiescence, checked against the screen's signature
	Restless,   // Android: still changing, then the tree held still but for an endless animation
}

Settle_Result :: struct {
	status:       Settle_Status,
	ui_done_us:   u32, // last UI change, relative to the injected action
	waited_us:    u32, // when the agent declared it settled
	method:       Settle_Method,
	frames:       u32, // new frames observed
	probes:       u32, // main-thread probes made
	probe_max_us: u32, // slowest probe (large = app main thread was busy)
	events:       u32, // accessibility events from the active window observed
}

// Device-side injection route (the byte that used to be the fast_inject flag; 0/1 unchanged).
Inject_Path :: enum u8 {
	UiAutomation,      // public UiAutomation API: syncs input transactions, waits for animations
	UiAutomation_Fast, // hidden UiAutomation overload: syncs input transactions, no animation wait
	Input_Manager,     // shell-uid agent straight to the input manager: async, no syncs
	XCTest_Event,      // iOS: an event synthesized through testmanagerd, until delivered
	None = 255,        // iOS: nothing to send (deleting from an empty field)
}

Action_Result :: struct {
	prep_us:     u32, // active-window lookup + frame-stats clear on the device
	inject_us:   u32, // DOWN + UP injection on the device
	inject_path: Inject_Path,
}

Conn :: struct {
	sock:  net.TCP_Socket,
	buf:   [dynamic]byte, // reused for every response: zero steady-state allocation
	calls: int, // requests made (screen_current)
}

// ---- transport ------------------------------------------------------------------------

send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	data := data
	for len(data) > 0 {
		n, err := net.send_tcp(sock, data)
		if err != nil || n <= 0 do return false
		data = data[n:]
	}
	return true
}

recv_all :: proc(sock: net.TCP_Socket, buf: []byte) -> bool {
	got := 0
	for got < len(buf) {
		n, err := net.recv_tcp(sock, buf[got:])
		if err != nil || n <= 0 do return false
		got += n
	}
	return true
}

// One request/response. The returned body aliases c.buf and is valid until the next call.
call :: proc(c: ^Conn, req: []byte) -> (body: []byte, agent_us: u32, ok: bool) {
	c.calls += 1
	send_all(c.sock, req) or_return
	hdr: [4]byte
	recv_all(c.sock, hdr[:]) or_return
	n := endian.get_u32(hdr[:], .Big) or_return
	if n < 4 do return
	resize(&c.buf, int(n))
	recv_all(c.sock, c.buf[:]) or_return
	agent_us = endian.get_u32(c.buf[:4], .Big) or_return
	return c.buf[4:], agent_us, true
}

put_i32 :: proc(b: []byte, v: i32) {
	_ = endian.put_u32(b, .Big, u32(v))
}

// ---- decoding -------------------------------------------------------------------------

Reader :: struct {
	b:   []byte,
	off: int,
	ok:  bool,
}

rd_bytes :: proc(r: ^Reader, n: int) -> []byte {
	if !r.ok || r.off + n > len(r.b) {
		r.ok = false
		return nil
	}
	s := r.b[r.off:][:n]
	r.off += n
	return s
}

rd_u8 :: proc(r: ^Reader) -> u8 {
	b := rd_bytes(r, 1)
	return b[0] if len(b) == 1 else 0
}

rd_u16 :: proc(r: ^Reader) -> u16 {
	v, _ := endian.get_u16(rd_bytes(r, 2), .Big)
	return v
}

rd_u32 :: proc(r: ^Reader) -> u32 {
	v, _ := endian.get_u32(rd_bytes(r, 4), .Big)
	return v
}

rd_i32 :: proc(r: ^Reader) -> i32 {
	return i32(rd_u32(r))
}

rd_str :: proc(r: ^Reader, allocator: mem.Allocator) -> string {
	n := int(rd_u16(r))
	if n == 0 do return ""
	return strings.clone(string(rd_bytes(r, n)), allocator)
}

// ---- operations -----------------------------------------------------------------------

op_ping :: proc(c: ^Conn) -> (agent_us: u32, ok: bool) {
	req := [1]byte{u8(Op.Ping)}
	_, agent_us, ok = call(c, req[:])
	return
}

// Waits until the app shows a readable UI (iOS: running in the foreground).
op_launched :: proc(c: ^Conn, app_id: string, timeout_ms: i32, alloc: mem.Allocator) -> (ready, ok: bool) {
	req := make([dynamic]byte, 0, len(app_id) + 8, alloc)
	append(&req, u8(Op.Launched), u8(len(app_id) >> 8), u8(len(app_id)))
	append(&req, ..transmute([]byte)app_id)
	t: [4]byte
	put_i32(t[:], timeout_ms)
	append(&req, ..t[:])
	body: []byte
	body, _, ok = call(c, req[:])
	return ok && len(body) > 0 && body[0] == 1, ok
}

// iOS: XCUIDevice.shared.orientation, a UIDeviceOrientation (1 portrait, 2 upside down,
// 3 landscape left, 4 landscape right).
op_orientation :: proc(c: ^Conn, orientation: i32) -> bool {
	req: [5]byte
	req[0] = u8(Op.Orientation)
	put_i32(req[1:5], orientation)
	_, _, ok := call(c, req[:])
	return ok
}

// iOS: XCUIDevice.shared.appearance. `set` 0 only reads, 1 light, 2 dark; returns the
// appearance after it (UIUserInterfaceStyle: 1 light, 2 dark, 0 unspecified).
op_appearance :: proc(c: ^Conn, set: i32) -> (appearance: u8, ok: bool) {
	req: [5]byte
	req[0] = u8(Op.Appearance)
	put_i32(req[1:5], set)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok || len(body) < 1 do return 0, false
	return body[0], true
}

// Android: `lat,lon` on each provider now and every interval_ms after, in the agent (one
// binder call per provider). Returns how many it set: 0 means only the shell commands work
// here. No providers stops the re-sending.
op_location :: proc(c: ^Conn, providers: []string, latitude, longitude: string, interval_ms: int) -> (set: int, ok: bool) {
	list := strings.join(providers, ",", context.temp_allocator)
	req := str_request(.Location, fmt.tprintf("%s %s %s %d", list, latitude, longitude, interval_ms), context.temp_allocator)
	body: []byte
	body, _, ok = call(c, req)
	if !ok || len(body) < 1 do return 0, false
	return int(body[0]), true
}

// Android: the app's name as the launcher shows it, "" when unknown. In `alloc`.
op_label :: proc(c: ^Conn, app: string, alloc: mem.Allocator) -> (label: string, ok: bool) {
	body: []byte
	body, _, ok = call(c, str_request(.Label, app, context.temp_allocator))
	if !ok do return
	r := Reader{b = body, ok = true}
	label = rd_str(&r, alloc)
	return label, r.ok
}

Requested_Permission :: struct {
	name:             string,
	granted, runtime: bool,
	app_op_mode:      u8, // MANAGE_EXTERNAL_STORAGE's: 0 allowed, 2 errored, 3 default; else 255
}

// Android: the permissions `app` requests. ok is false when the agent cannot read them (the
// caller falls back to dumpsys). Names in `alloc`.
op_perms :: proc(c: ^Conn, app: string, alloc: mem.Allocator) -> (perms: []Requested_Permission, ok: bool) {
	body: []byte
	body, _, ok = call(c, str_request(.Perms, app, context.temp_allocator))
	if !ok do return
	r := Reader{b = body, ok = true}
	if rd_u8(&r) == 0 do return nil, false
	list := make([]Requested_Permission, int(rd_u16(&r)), alloc)
	for &p in list {
		p.name = rd_str(&r, alloc)
		flags := rd_u8(&r)
		p.granted, p.runtime = flags & 1 != 0, flags & 2 != 0
		p.app_op_mode = rd_u8(&r)
	}
	return list, r.ok
}

op_quit :: proc(c: ^Conn) -> bool {
	_, _, ok := call(c, []byte{u8(Op.Quit)})
	return ok
}

// Strings in `alloc`.
op_info :: proc(c: ^Conn, alloc: mem.Allocator) -> (udid, name, build: string, ok: bool) {
	body: []byte
	body, _, ok = call(c, []byte{u8(Op.Info)})
	if !ok do return
	r := Reader{b = body, ok = true}
	udid, name, build = rd_str(&r, alloc), rd_str(&r, alloc), rd_str(&r, alloc)
	return udid, name, build, r.ok
}

// Strings live in `str_alloc` (the per-step arena); the node columns are reused across steps.
op_tree :: proc(c: ^Conn, nodes: ^Tree, str_alloc: mem.Allocator) -> (agent_us: u32, ok: bool) {
	req := [1]byte{u8(Op.Tree)}
	body: []byte
	body, agent_us, ok = call(c, req[:])
	if !ok do return
	return agent_us, read_nodes(body, nodes, str_alloc)
}

// Only the nodes whose text or description contains `text` (ignoring case), found by the
// app itself in one round trip; a cold TREE needs ~40. Depth is 0 in the results.
op_find :: proc(c: ^Conn, text: string, nodes: ^Tree, str_alloc: mem.Allocator) -> (agent_us: u32, ok: bool) {
	body: []byte
	body, agent_us, ok = call(c, str_request(.Find, text, str_alloc))
	if !ok do return
	return agent_us, read_nodes(body, nodes, str_alloc)
}

// `u8 op, str text` (str = u16 len + utf8).
str_request :: proc(op: Op, text: string, alloc: mem.Allocator) -> []byte {
	n := min(len(text), 0xFFFF)
	req := make([]byte, 3 + n, alloc)
	req[0] = u8(op)
	_ = endian.put_u16(req[1:3], .Big, u16(n))
	copy(req[3:], text[:n])
	return req
}

// Decodes `u32 count, count * node` (the TREE and FIND body) into `nodes`.
read_nodes :: proc(body: []byte, nodes: ^Tree, str_alloc: mem.Allocator) -> bool {
	r := Reader{b = body, ok = true}
	count := int(rd_u32(&r))
	clear(nodes)
	reserve(nodes, count)
	for _ in 0 ..< count {
		n: Node
		n.depth = rd_u16(&r)
		n.left = rd_i32(&r)
		n.top = rd_i32(&r)
		n.right = rd_i32(&r)
		n.bottom = rd_i32(&r)
		n.flags = transmute(Flags)rd_u8(&r)
		n.text = rd_str(&r, str_alloc)
		n.desc = rd_str(&r, str_alloc)
		n.id = rd_str(&r, str_alloc)
		n.class = rd_str(&r, str_alloc)
		n.hint = rd_str(&r, str_alloc)
		n.error = rd_str(&r, str_alloc)
		if !r.ok do break
		append(nodes, n)
	}
	return r.ok
}

read_action :: proc(body: []byte) -> (res: Action_Result, ok: bool) {
	r := Reader{b = body, ok = true}
	res.prep_us = rd_u32(&r)
	res.inject_us = rd_u32(&r)
	res.inject_path = Inject_Path(rd_u8(&r))
	return res, r.ok
}

op_tap :: proc(c: ^Conn, x, y: i32) -> (res: Action_Result, ok: bool) {
	req: [9]byte
	req[0] = u8(Op.Tap)
	put_i32(req[1:5], x)
	put_i32(req[5:9], y)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
}

// The index of the node (in the last screen read) that a touch at x, y reaches, -1 for none;
// then the frame (left, top, right, bottom) of what it reaches instead, all 0 when unknown.
op_hit :: proc(c: ^Conn, x, y: i32) -> (idx: int, frame: [4]i32, ok: bool) {
	req: [9]byte
	req[0] = u8(Op.Hit)
	put_i32(req[1:5], x)
	put_i32(req[5:9], y)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return -1, {}, false
	r := Reader{b = body, ok = true}
	idx = int(rd_i32(&r))
	for &v in frame do v = rd_i32(&r)
	return idx, frame, r.ok
}

op_key :: proc(c: ^Conn, code: i32) -> (res: Action_Result, ok: bool) {
	req: [5]byte
	req[0] = u8(Op.Key)
	put_i32(req[1:5], code)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
}

// A drag. With `fling` it lifts at speed, like `adb shell input swipe`; without, it stops
// before lifting and the content moves by about the drag distance. `cancel` (Android, no
// fling): it ends with a CANCEL instead of the lift, which no list flings on, and no paging
// list snaps on.
op_swipe :: proc(c: ^Conn, x1, y1, x2, y2, duration_ms: i32, fling := false, cancel := false) -> (res: Action_Result, ok: bool) {
	req: [25]byte
	req[0] = u8(Op.Swipe)
	put_i32(req[1:5], x1)
	put_i32(req[5:9], y1)
	put_i32(req[9:13], x2)
	put_i32(req[13:17], y2)
	put_i32(req[17:21], duration_ms)
	put_i32(req[21:25], (1 if fling else 0) | (2 if cancel else 0))
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
}

// Key events into the focused field; `skipped` characters had no key sequence.
op_type :: proc(c: ^Conn, text: string, alloc: mem.Allocator) -> (res: Action_Result, skipped: u32, ok: bool) {
	body: []byte
	body, _, ok = call(c, str_request(.Type, text, alloc))
	if !ok do return
	res, ok = read_action(body)
	if !ok do return
	r := Reader{b = body[9:], ok = true} // after prep_us, inject_us, inject_path
	skipped = rd_u32(&r)
	return res, skipped, r.ok
}

// `count` DEL presses.
op_erase :: proc(c: ^Conn, count: i32) -> (res: Action_Result, ok: bool) {
	req: [5]byte
	req[0] = u8(Op.Erase)
	put_i32(req[1:5], count)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
}

// DOWN, held `hold_ms` in real time, UP.
op_press :: proc(c: ^Conn, x, y, hold_ms: i32) -> (res: Action_Result, ok: bool) {
	req: [13]byte
	req[0] = u8(Op.Press)
	put_i32(req[1:5], x)
	put_i32(req[5:9], y)
	put_i32(req[9:13], hold_ms)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
}

// iOS: count taps interval_ms apart in one gesture (each its own event record waits ~230 ms
// for testmanagerd).
op_taps :: proc(c: ^Conn, x, y, count, interval_ms: i32) -> (res: Action_Result, ok: bool) {
	req: [17]byte
	req[0] = u8(Op.Taps)
	put_i32(req[1:5], x)
	put_i32(req[5:9], y)
	put_i32(req[9:13], count)
	put_i32(req[13:17], interval_ms)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
}

// The next SETTLE measures from now.
op_mark :: proc(c: ^Conn) -> bool {
	_, _, ok := call(c, []byte{u8(Op.Mark)})
	return ok
}

// A command run as the shell user (no shell syntax); its output, copied into `alloc`.
op_shell :: proc(c: ^Conn, command: string, alloc: mem.Allocator) -> (out: string, ok: bool) {
	body: []byte
	body, _, ok = call(c, str_request(.Shell, command, alloc))
	if !ok do return
	data := read_bytes(body) or_return
	return strings.clone(string(data), alloc), true
}

// PNG of the screen, copied into `alloc`.
op_screenshot :: proc(c: ^Conn, alloc: mem.Allocator) -> (png: []byte, ok: bool) {
	body: []byte
	body, _, ok = call(c, []byte{u8(Op.Screenshot)})
	if !ok do return
	data := read_bytes(body) or_return
	return slice.clone(data, alloc), true
}

// `u32 len, data`
read_bytes :: proc(body: []byte) -> (data: []byte, ok: bool) {
	r := Reader{b = body, ok = true}
	n := int(rd_u32(&r))
	data = rd_bytes(&r, n)
	return data, r.ok
}

op_settle :: proc(c: ^Conn, quiet_ms, no_change_ms, timeout_ms: i32) -> (res: Settle_Result, ok: bool) {
	req: [13]byte
	req[0] = u8(Op.Settle)
	put_i32(req[1:5], quiet_ms)
	put_i32(req[5:9], no_change_ms)
	put_i32(req[9:13], timeout_ms)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	r := Reader{b = body, ok = true}
	res.status = Settle_Status(rd_u8(&r))
	res.ui_done_us = rd_u32(&r)
	res.waited_us = rd_u32(&r)
	res.method = Settle_Method(rd_u8(&r))
	res.frames = rd_u32(&r)
	res.probes = rd_u32(&r)
	res.probe_max_us = rd_u32(&r)
	res.events = rd_u32(&r)
	return res, r.ok
}

settle_default :: proc(c: ^Conn) -> (Settle_Result, bool) {
	return op_settle(c, SETTLE_QUIET_MS, SETTLE_NO_CHANGE_MS, SETTLE_TIMEOUT_MS)
}

// Exact match on text or content-description, visible nodes only.
find :: proc(nodes: #soa[]Node, needle: string) -> (idx: int, found: bool) {
	for i in 0 ..< len(nodes) {
		if .Visible not_in nodes[i].flags do continue
		if nodes[i].text == needle || nodes[i].desc == needle do return i, true
	}
	return -1, false
}

// Exact match on text or content-description, visible or not.
has_text :: proc(nodes: #soa[]Node, needle: string) -> bool {
	for i in 0 ..< len(nodes) {
		if nodes[i].text == needle || nodes[i].desc == needle do return true
	}
	return false
}

// Polls until `needle` is visible or the timeout passes. Each round asks the agent to FIND
// it (one round trip to the app). When FIND brings back no exact match at all, it reads the
// whole TREE (~40 round trips after a screen change), which also sees text FIND cannot,
// such as text set by an accessibility delegate. An exact match that is only off screen
// needs no TREE: it would show the same node. The waiting is the app's time, not the tool's.
wait_for :: proc(
	c: ^Conn,
	nodes: ^Tree,
	str_alloc: mem.Allocator,
	needle: string,
	timeout_ms: f64,
) -> (
	idx: int,
	found: bool,
	rounds: int,
	tree_reads: int,
	ok: bool,
) {
	start := time.tick_now()
	for {
		rounds += 1
		if _, fok := op_find(c, needle, nodes, str_alloc); !fok do return
		idx, found = find(nodes[:], needle)
		if found {
			ok = true
			return
		}
		if !has_text(nodes[:], needle) {
			tree_reads += 1
			if _, tok := op_tree(c, nodes, str_alloc); !tok do return
			idx, found = find(nodes[:], needle)
		}
		ok = true
		if found || us(start) / 1000 >= timeout_ms do return
		time.sleep(5 * time.Millisecond)
	}
}

// ---- stats ----------------------------------------------------------------------------

// Formats through %s so padding is spaces on every Odin version.
num :: proc(v: f64) -> string {
	return fmt.tprintf("%.3f", v)
}

pct :: proc(sorted: []f64, q: f64) -> f64 {
	i := int(q * f64(len(sorted)))
	return sorted[min(i, len(sorted) - 1)]
}

report :: proc(label: string, xs: []f64, unit: string) {
	if len(xs) == 0 do return
	slice.sort(xs)
	fmt.printf(
		"  %-50s median %10s   p95 %10s   min %10s   max %10s  %s\n",
		label, num(pct(xs, 0.5)), num(pct(xs, 0.95)), num(xs[0]), num(xs[len(xs) - 1]), unit,
	)
	free_all(context.temp_allocator)
}

us :: proc(start: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_since(start))
}

// ---- main -----------------------------------------------------------------------------

connect :: proc(port: int) -> (c: Conn, ok: bool) {
	// `adb forward` accepts the connection even before the agent listens, so a working
	// connection is one that answers a PING.
	for _ in 0 ..< 100 {
		sock, dialed := agent_dial(port)
		if dialed {
			_ = net.set_option(sock, .TCP_Nodelay, true)
			c.sock = sock
			if _, pok := op_ping(&c); pok do return c, true
			net.close(sock)
		}
		time.sleep(100 * time.Millisecond)
	}
	return
}

main :: proc() {
	os.exit(run_cli(os.args[1:]))
}

// The latency breakdown: transport, tree reads, then a tap + back step loop on target.
run_bench :: proc(conn: ^Conn, target: string, iters: int) -> int {
	c := conn^
	defer conn^ = c

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		fmt.eprintln("arena init failed:", err)
		return 1
	}
	defer virtual.arena_destroy(&arena)
	step_alloc := virtual.arena_allocator(&arena)

	nodes: Tree
	defer delete(nodes)

	// -- 1. transport ------------------------------------------------------------------
	fmt.println("\n[1] Transport round trip (host -> adb forward -> agent -> host), 500 pings")
	{
		rtt: [dynamic]f64
		defer delete(rtt)
		for _ in 0 ..< 500 {
			t := time.tick_now()
			if _, pok := op_ping(&c); !pok {
				fmt.eprintln("ping failed")
				return 1
			}
			append(&rtt, us(t) / 1000)
		}
		report("round trip", rtt[:], "ms")
	}

	// -- 2. tree -----------------------------------------------------------------------
	fmt.println("\n[2] Full UI tree fetch + decode, 30 times")
	{
		host_ms, agent_ms, decode_free: [dynamic]f64
		defer delete(host_ms)
		defer delete(agent_ms)
		defer delete(decode_free)
		for _ in 0 ..< 30 {
			virtual.arena_free_all(&arena)
			t := time.tick_now()
			a_us, tok := op_tree(&c, &nodes, step_alloc)
			if !tok {
				fmt.eprintln("tree fetch failed")
				return 1
			}
			append(&host_ms, us(t) / 1000)
			append(&agent_ms, f64(a_us) / 1000)
		}
		report("total (host view)", host_ms[:], "ms")
		report("tree walk on device", agent_ms[:], "ms")
		fmt.printf("  nodes on screen: %d\n", len(nodes))
	}

	if target == "" {
		fmt.println("\nNo target text given; skipping the step benchmark.")
		fmt.println("Visible texts you could target:")
		print_targets(nodes[:])
		return 0
	}

	// -- 3. steps ----------------------------------------------------------------------
	fmt.printf("\n[3] Step loop x%d: wait for \"%s\" -> tap -> settle, then BACK -> settle\n", iters, target)
	{
		read_ms, reads_n, find_us, tap_ms, prep_ms, inject_ms, ui_ms, settle_ms, step_ms, back_ms: [dynamic]f64
		over_frames_ms, over_events_ms, frames_n, events_n, probes_n, probe_max_ms: [dynamic]f64
		defer {
			delete(read_ms); delete(reads_n); delete(find_us); delete(tap_ms); delete(prep_ms)
			delete(inject_ms); delete(ui_ms); delete(settle_ms); delete(step_ms); delete(back_ms)
			delete(over_frames_ms); delete(over_events_ms); delete(frames_n); delete(events_n); delete(probes_n)
			delete(probe_max_ms)
		}
		inject_path: Inject_Path
		tree_fallbacks := 0
		statuses, back_statuses: [Settle_Status]int
		methods: [Settle_Method]int
		last_back: Settle_Result

		loop_start := time.tick_now()
		defer fmt.printf(
			"\n  LOOP TOTAL (wall clock, %d rounds of tap + back): %s s\n",
			iters, num(us(loop_start) / 1_000_000),
		)

		for i in 0 ..< iters {
			virtual.arena_free_all(&arena) // every string from the last step: gone in O(1)

			step := time.tick_now()

			t := time.tick_now()
			idx, found, rounds, tree_reads, rok := wait_for(&c, &nodes, step_alloc, target, 2000)
			if !rok {
				fmt.eprintln("find or tree fetch failed")
				return 1
			}
			append(&read_ms, us(t) / 1000)
			append(&reads_n, f64(rounds))
			tree_fallbacks += tree_reads
			if !found {
				_, _ = op_tree(&c, &nodes, step_alloc) // the whole screen, for diagnostics
				visible := 0
				for j in 0 ..< len(nodes) do if .Visible in nodes[j].flags do visible += 1
				fmt.eprintf(
					"step %d: \"%s\" not found within 2 s (%d FIND rounds). Screen: %d nodes, %d visible. Last BACK settle: %v after %s ms.\n",
					i, target, rounds, len(nodes), visible, last_back.status, num(f64(last_back.waited_us) / 1000),
				)
				fmt.eprintln("First nodes on screen (including invisible):")
				print_nodes(nodes[:])
				return 1
			}

			// Pure host-side lookup cost, isolated from the network.
			t = time.tick_now()
			_, _ = find(nodes[:], target)
			append(&find_us, us(t))

			n := nodes[idx]
			t = time.tick_now()
			ta, tok := op_tap(&c, (n.left + n.right) / 2, (n.top + n.bottom) / 2)
			if !tok {
				fmt.eprintln("tap failed")
				return 1
			}
			append(&tap_ms, us(t) / 1000)
			append(&prep_ms, f64(ta.prep_us) / 1000)
			append(&inject_ms, f64(ta.inject_us) / 1000)
			inject_path = ta.inject_path

			s, sok := settle_default(&c)
			if !sok {
				fmt.eprintln("settle failed")
				return 1
			}
			statuses[s.status] += 1
			methods[s.method] += 1
			append(&ui_ms, f64(s.ui_done_us) / 1000)
			append(&settle_ms, f64(s.waited_us) / 1000)
			if s.status == .Settled {
				over := f64(s.waited_us - min(s.waited_us, s.ui_done_us)) / 1000
				append(&over_frames_ms if s.method == .Frames else &over_events_ms, over)
			}
			if s.method == .Frames {
				append(&frames_n, f64(s.frames))
				append(&events_n, f64(s.events))
				append(&probes_n, f64(s.probes))
				append(&probe_max_ms, f64(s.probe_max_us) / 1000)
			}
			append(&step_ms, us(step) / 1000)

			// Return to the starting screen (not part of the measured step).
			t = time.tick_now()
			if _, kok := op_key(&c, KEYCODE_BACK); !kok {
				fmt.eprintln("back failed")
				return 1
			}
			bs, bok := settle_default(&c)
			if !bok {
				fmt.eprintln("settle after back failed")
				return 1
			}
			last_back = bs
			back_statuses[bs.status] += 1
			methods[bs.method] += 1
			append(&back_ms, us(t) / 1000)
		}

		report("FIND target on device (incl. waits)", read_ms[:], "ms")
		report("FIND rounds needed", reads_n[:], "")
		report("find on host", find_us[:], "us")
		report("tap (host view)", tap_ms[:], "ms")
		report("  window lookup + frame clear", prep_ms[:], "ms")
		report("  event injection", inject_ms[:], "ms")
		report("UI finished changing (after tap)", ui_ms[:], "ms")
		report("settle declared (after tap)", settle_ms[:], "ms")
		report("  detection overhead (frames)", over_frames_ms[:], "ms")
		report("  detection overhead (events)", over_events_ms[:], "ms")
		report("  new frames seen (frames)", frames_n[:], "")
		report("  accessibility events seen (frames)", events_n[:], "")
		report("  main-thread probes (frames)", probes_n[:], "")
		report("  slowest probe (frames)", probe_max_ms[:], "ms")
		report("WHOLE STEP", step_ms[:], "ms")
		report("back + settle (unmeasured step)", back_ms[:], "ms")
		fmt.printf(
			"  settle after tap:  %d changed+quiet, %d no change, %d timeout\n",
			statuses[.Settled], statuses[.No_Change], statuses[.Timeout],
		)
		fmt.printf(
			"  settle after BACK: %d changed+quiet, %d no change, %d timeout\n",
			back_statuses[.Settled], back_statuses[.No_Change], back_statuses[.Timeout],
		)
		fmt.printf(
			"  settle method: %d frames/events + probe (\"frames\" above), %d event-only fallback\n",
			methods[.Frames], methods[.Events],
		)
		path_label: string
		switch inject_path {
		case .Input_Manager:     path_label = "InputManager as shell uid (async, no transaction syncs)"
		case .UiAutomation_Fast: path_label = "UiAutomation, no animation wait (syncs input transactions)"
		case .UiAutomation:      path_label = "UiAutomation public API (waits for animations; see logcat tag SpeedrunAgent)"
		case .XCTest_Event:      path_label = "XCTest synthesized event (iOS)"
		case .None:              path_label = "none (nothing to send)"
		case:                    path_label = fmt.tprintf("unknown (%d)", u8(inject_path))
		}
		fmt.printf("  injection path: %s\n", path_label)
		fmt.printf("  TREE fallbacks (FIND brought back no visible exact match): %d\n", tree_fallbacks)
		fmt.println("  (\"FIND rounds needed\" > 1 means settle fired before the target was on screen.)")
		fmt.println("  (a slow probe means the app's main thread was busy, so settle correctly kept waiting.)")
	}
	return 0
}

USAGE :: `usage:
  speedrun test [options] <flow file or folder>...   (speedrun test --help)
  speedrun session start --app <appId>   a device kept connected, for speedrun do / look
                                         (speedrun session --help)
  speedrun mcp                           the same as a Model Context Protocol server (stdio)
  speedrun update [version]              install the latest release (or the one named) in place
  speedrun --flow <file.yaml> [-e KEY=VALUE]... [--timings <out.json>] [--plain]
  speedrun --bench ["<on-screen text>" [iterations]]
  speedrun --stop-agent        stop the iOS agent kept running between runs
  speedrun --version
  speedrun --licenses
options:
  --device <id>       the device: an Android serial ("adb devices") or a booted iOS
                      simulator's UDID ("xcrun simctl list devices booted")
  --platform <p>      android or ios (default: a connected Android device, else the one
                      booted simulator)
  --port <n>          the agent's port (default 7777 on Android, on the device: a free port
                      of this machine is forwarded to it; 7778 on iOS)
  --instrument        Android: run the agent as an instrumentation (~60 ms slower per action)
Starts the agent on the device, runs, then stops it; on iOS the agent stays up for the next
run (starting it takes seconds) and stops after 10 idle minutes (SPEEDRUN_IDLE_S). On Android,
animations are turned off, as for any UI test, and stay off; on iOS, apps that launchApp
starts run their UIKit animations 10x faster.`

// --flow runs a flow file; exit status 0 if it passed. On a terminal the output is a live
// view; --plain (or a pipe) prints one line per command instead.
// --bench prints the latency breakdown, after a `uiautomator dump` baseline.
run_cli :: proc(args: []string) -> int {
	// A session (session.odin): one device connection kept between commands.
	if len(args) > 0 {
		switch args[0] {
		case "session": return run_session_cli(args[1:])
		case "do":      return run_do_cli(args[1:])
		case "look":    return run_look_cli(args[1:])
		case "mcp":     return run_mcp_cli(args[1:])
		case "update":  return run_update_cli(args[1:])
		}
	}
	// The test form: [-p <platform>] [--device <id>] [--no-ansi] [--verbose] test [options] <flows>...
	{
		platform, device := "", ""
		for i := 0; i < len(args); i += 1 {
			a := args[i]
			name, eq, inline := strings.partition(a, "=")
			value := inline if eq != "" else (args[i + 1] if i + 1 < len(args) else "")
			switch name {
			case "test":
				// Not in a shard's process: the run that started it says it once.
				worker := slice.contains(args[i + 1:], "--shard-worker")
				if !worker do update_check_start()
				code := run_test_cli(args[i + 1:], platform, device)
				if notice := update_notice(); notice != "" && !worker do fmt.eprintf("\n%s\n", notice)
				return code
			case "-p", "--platform":
				platform = value
				if eq == "" do i += 1
				continue
			case "--device", "--udid":
				device = value
				if eq == "" do i += 1
				continue
			case "--no-ansi", "--ansi", "--verbose":
				continue
			}
			break
		}
	}
	Mode :: enum {
		None,
		Flow,
		Bench,
		Stop_Agent,
	}
	mode: Mode
	timings, platform, device := "", "", ""
	plain, port_given := false, false
	dev := Device {
		port = 7777,
	}
	env, positional: [dynamic]string
	defer delete(env)
	defer delete(positional)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value := args[i + 1] if i + 1 < len(args) else ""
		switch {
		case a == "--flow":
			mode = .Flow
		case a == "--bench":
			mode = .Bench
		case a == "--stop-agent":
			mode = .Stop_Agent
		case a == "-h" || a == "--help":
			fmt.println(USAGE)
			return 0
		case a == "--licenses":
			fmt.print(LICENSES)
			return 0
		case a == "--version":
			fmt.printfln("speedrun %s", VERSION)
			update_check_start()
			if notice := update_notice(); notice != "" do fmt.println(notice)
			return 0
		case a == "--plain":
			plain = true
		case a == "--instrument":
			dev.instrument = true
		case (a == "-e" || a == "--env") && value != "":
			append(&env, value)
			i += 1
		case a == "--timings" && value != "":
			timings = value
			i += 1
		case (a == "--device" || a == "--udid") && value != "":
			device = value
			i += 1
		case (a == "--platform" || a == "-p") && value != "":
			platform = value
			i += 1
		case a == "--port" && value != "":
			p, ok := strconv.parse_int(value)
			if !ok || p <= 0 || p > 65535 {
				fmt.eprintln("--port needs a port number")
				return 2
			}
			dev.port, port_given = p, true
			i += 1
		case len(a) > 1 && a[0] == '-':
			fmt.eprintf("unknown option or missing value: %s\n%s\n", a, USAGE)
			return 2
		case:
			append(&positional, a)
		}
	}

	file, target := "", ""
	iters := 10
	if mode == .Stop_Agent {
		port := dev.port if port_given else IOS_PORT
		if ios_quit(port) {
			fmt.printf("Stopped the iOS agent on port %d.\n", port)
		} else {
			fmt.printf("No iOS agent is running on port %d.\n", port)
		}
		return 0
	}
	if mode != .None {
		if err := device_select(&dev, platform, device, port_given); err != "" {
			fmt.eprintln(err)
			return 1
		}
	}
	switch mode {
	case .None, .Stop_Agent:
		fmt.eprintln(USAGE)
		return 2
	case .Flow:
		if len(positional) != 1 {
			fmt.eprintln("--flow needs one flow file")
			return 2
		}
		// `--flow <file>` is `test <file>`.
		o := Test_Options {
			platform   = platform,
			timings    = timings,
			plain      = plain,
			port       = dev.port,
			port_given = port_given,
			instrument = dev.instrument,
		}
		append(&o.inputs, positional[0])
		if device != "" do append(&o.devices, device)
		for e in env {
			k, _, v := strings.partition(e, "=")
			append(&o.env, Env_Pair{k, v})
		}
		return run_test(&o)
	case .Bench:
		if dev.platform == .IOS {
			fmt.eprintln("--bench is Android-only for now (on iOS: agent/ios/spike/measure.py)")
			return 2
		}
		if len(positional) > 0 do target = positional[0]
		if len(positional) > 1 {
			v, ok := strconv.parse_int(positional[1])
			if !ok || v < 1 {
				fmt.eprintln("iterations must be a positive number")
				return 2
			}
			iters = v
		}
		if len(positional) > 2 {
			fmt.eprintln("unexpected argument:", positional[2])
			return 2
		}
		// uiautomator needs the UiAutomation slot: before the agent takes it.
		if _, err := device_prepare(); err != "" {
			fmt.eprintln(err)
			return 1
		}
		bench_baseline()
		fmt.printf("\n== Starting the agent (%s)\n", "instrumentation" if dev.instrument else "shell user, app_process")
	}

	if err := device_start(&dev, verbose = mode == .Bench); err != "" {
		device_stop(&dev)
		fmt.eprintln(err)
		return 1
	}
	defer device_stop(&dev)
	c, ok := connect(agent_port(&dev))
	if !ok {
		fmt.eprintln("could not reach the agent on port", agent_port(&dev), "(logs: adb logcat -s SpeedrunAgent)")
		return 1
	}
	defer net.close(c.sock)

	return run_bench(&c, target, iters)
}

// The classic way to read the screen, for comparison: `uiautomator dump`, then read the file.
bench_baseline :: proc() {
	fmt.println("== Baseline: 'uiautomator dump' x5 (a full-hierarchy dump, the classic way to read the screen)")
	total := 0.0
	for i in 1 ..= 5 {
		t := time.tick_now()
		adb("shell", "uiautomator dump /sdcard/speedrun_dump.xml")
		adb("shell", "cat /sdcard/speedrun_dump.xml")
		ms := us(t) / 1000
		fmt.printf("  dump + read #%d: %.0f ms\n", i, ms)
		total += ms
	}
	fmt.printf("  average: %.0f ms per screen read\n", total / 5)
	free_all(context.temp_allocator)
}

print_nodes :: proc(nodes: #soa[]Node) {
	for i in 0 ..< min(len(nodes), 30) {
		n := nodes[i]
		fmt.eprintf(
			"    %*s%s  text=\"%s\" desc=\"%s\" id=\"%s\" flags=%v bounds=[%d,%d][%d,%d]\n",
			int(n.depth) * 2, "", n.class, n.text, n.desc, n.id, n.flags, n.left, n.top, n.right, n.bottom,
		)
	}
}

print_targets :: proc(nodes: #soa[]Node) {
	shown := 0
	for i in 0 ..< len(nodes) {
		n := nodes[i]
		if .Visible not_in n.flags do continue
		label := n.text if n.text != "" else n.desc
		if label == "" do continue
		fmt.printf("    \"%s\"%s\n", label, "  (clickable)" if .Clickable in n.flags else "")
		shown += 1
		if shown >= 25 do break
	}
}

