// E2E spike host: drives the on-device agent over one persistent TCP connection
// (forwarded by `adb forward`) and measures where every millisecond goes.
//
// Usage: spike_host [port] [target_text] [iterations]
package spike_host

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
}

KEYCODE_BACK :: 4

// Settle tuning. With window frame stats, "quiet" means no new frame for ~2 frames at
// 60 Hz plus an idle-main-thread probe. If frame stats are unavailable the agent falls
// back to accessibility events and raises the quiet window to 120 ms on its own.
SETTLE_QUIET_MS     :: 34
SETTLE_NO_CHANGE_MS :: 1000 // only paid when a tap really does nothing
SETTLE_TIMEOUT_MS   :: 10_000

Flag :: enum u8 {
	Clickable,
	Enabled,
	Focused,
	Scrollable,
	Checked,
	Visible,
}
Flags :: bit_set[Flag; u8]

Node :: struct {
	left, top, right, bottom: i32,
	depth:                    u16,
	flags:                    Flags,
	text, desc, id, class:    string,
}

// Struct-of-arrays: a selector scan over `text` touches only the text column.
Tree :: #soa[dynamic]Node

Settle_Status :: enum u8 {
	Settled,   // UI changed, then went quiet
	No_Change, // nothing changed after the action
	Timeout,
}

Settle_Method :: enum u8 {
	Frames, // window frame stats + main-thread idle probe
	Events, // accessibility-event fallback
}

Settle_Result :: struct {
	status:       Settle_Status,
	ui_done_us:   u32, // last UI change, relative to the injected action
	waited_us:    u32, // when the agent declared it settled
	method:       Settle_Method,
	frames:       u32, // new frames observed
	probes:       u32, // main-thread probes made
	probe_max_us: u32, // slowest probe (large = app main thread was busy)
}

// Device-side injection route (the byte that used to be the fast_inject flag; 0/1 unchanged).
Inject_Path :: enum u8 {
	UiAutomation,      // public UiAutomation API: syncs input transactions, waits for animations
	UiAutomation_Fast, // hidden UiAutomation overload: syncs input transactions, no animation wait
	Input_Manager,     // shell-uid agent straight to the input manager: async, no syncs
}

Action_Result :: struct {
	prep_us:     u32, // active-window lookup + frame-stats clear on the device
	inject_us:   u32, // DOWN + UP injection on the device
	inject_path: Inject_Path,
}

Conn :: struct {
	sock: net.TCP_Socket,
	buf:  [dynamic]byte, // reused for every response: zero steady-state allocation
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
	n := min(len(text), 0xFFFF)
	req := make([]byte, 3 + n, str_alloc)
	req[0] = u8(Op.Find)
	_ = endian.put_u16(req[1:3], .Big, u16(n))
	copy(req[3:], text[:n])
	body: []byte
	body, agent_us, ok = call(c, req)
	if !ok do return
	return agent_us, read_nodes(body, nodes, str_alloc)
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

op_key :: proc(c: ^Conn, code: i32) -> (res: Action_Result, ok: bool) {
	req: [5]byte
	req[0] = u8(Op.Key)
	put_i32(req[1:5], code)
	body: []byte
	body, _, ok = call(c, req[:])
	if !ok do return
	return read_action(body)
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

// Polls until `needle` is visible or the timeout passes. Each round asks the agent to FIND
// it (one round trip to the app). Only when that brings back no visible exact match does it
// read the whole TREE (~40 round trips after a screen change), which also sees text FIND
// cannot, such as text set by an accessibility delegate. After a miss `nodes` holds the full
// tree, for diagnostics. The waiting is the app's time, not the tool's.
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
		tree_reads += 1
		if _, tok := op_tree(c, nodes, str_alloc); !tok do return
		ok = true
		idx, found = find(nodes[:], needle)
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
		"  %-38s median %10s   p95 %10s   min %10s   max %10s  %s\n",
		label, num(pct(xs, 0.5)), num(pct(xs, 0.95)), num(xs[0]), num(xs[len(xs) - 1]), unit,
	)
	free_all(context.temp_allocator)
}

us :: proc(start: time.Tick) -> f64 {
	return time.duration_microseconds(time.tick_since(start))
}

// ---- main -----------------------------------------------------------------------------

connect :: proc(port: int) -> (c: Conn, ok: bool) {
	ep, ep_ok := net.parse_endpoint(fmt.tprintf("127.0.0.1:%d", port))
	if !ep_ok do return

	// `adb forward` accepts the connection even before the agent listens, so a working
	// connection is one that answers a PING.
	for _ in 0 ..< 100 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
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
	port := 7777
	target := ""
	iters := 10
	if len(os.args) > 1 {
		if v, vok := strconv.parse_int(os.args[1]); vok do port = v
	}
	if len(os.args) > 2 do target = os.args[2]
	if len(os.args) > 3 {
		if v, vok := strconv.parse_int(os.args[3]); vok do iters = max(1, v)
	}

	c, ok := connect(port)
	if !ok {
		fmt.eprintln("could not reach the agent on port", port, "(is `adb forward` set and the agent running?)")
		os.exit(1)
	}
	defer net.close(c.sock)

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		fmt.eprintln("arena init failed:", err)
		os.exit(1)
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
				os.exit(1)
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
				os.exit(1)
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
		return
	}

	// -- 3. steps ----------------------------------------------------------------------
	fmt.printf("\n[3] Step loop x%d: wait for \"%s\" -> tap -> settle, then BACK -> settle\n", iters, target)
	{
		read_ms, reads_n, find_us, tap_ms, prep_ms, inject_ms, ui_ms, settle_ms, step_ms, back_ms: [dynamic]f64
		over_frames_ms, over_events_ms, frames_n, probes_n, probe_max_ms: [dynamic]f64
		defer {
			delete(read_ms); delete(reads_n); delete(find_us); delete(tap_ms); delete(prep_ms)
			delete(inject_ms); delete(ui_ms); delete(settle_ms); delete(step_ms); delete(back_ms)
			delete(over_frames_ms); delete(over_events_ms); delete(frames_n); delete(probes_n)
			delete(probe_max_ms)
		}
		inject_path: Inject_Path
		tree_fallbacks := 0
		statuses, back_statuses: [Settle_Status]int
		methods: [Settle_Method]int
		last_back: Settle_Result

		loop_start := time.tick_now()
		defer fmt.printf(
			"\n  LOOP TOTAL (wall clock, %d rounds of tap + back): %s s  ->  compare with `time maestro test bench.yaml`\n",
			iters, num(us(loop_start) / 1_000_000),
		)

		for i in 0 ..< iters {
			virtual.arena_free_all(&arena) // every string from the last step: gone in O(1)

			step := time.tick_now()

			t := time.tick_now()
			idx, found, rounds, tree_reads, rok := wait_for(&c, &nodes, step_alloc, target, 2000)
			if !rok {
				fmt.eprintln("find or tree fetch failed")
				os.exit(1)
			}
			append(&read_ms, us(t) / 1000)
			append(&reads_n, f64(rounds))
			tree_fallbacks += tree_reads
			if !found {
				visible := 0
				for j in 0 ..< len(nodes) do if .Visible in nodes[j].flags do visible += 1
				fmt.eprintf(
					"step %d: \"%s\" not found within 2 s (%d FIND rounds). Screen: %d nodes, %d visible. Last BACK settle: %v after %s ms.\n",
					i, target, rounds, len(nodes), visible, last_back.status, num(f64(last_back.waited_us) / 1000),
				)
				fmt.eprintln("First nodes on screen (including invisible):")
				print_nodes(nodes[:])
				os.exit(1)
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
				os.exit(1)
			}
			append(&tap_ms, us(t) / 1000)
			append(&prep_ms, f64(ta.prep_us) / 1000)
			append(&inject_ms, f64(ta.inject_us) / 1000)
			inject_path = ta.inject_path

			s, sok := settle_default(&c)
			if !sok {
				fmt.eprintln("settle failed")
				os.exit(1)
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
				append(&probes_n, f64(s.probes))
				append(&probe_max_ms, f64(s.probe_max_us) / 1000)
			}
			append(&step_ms, us(step) / 1000)

			// Return to the starting screen (not part of the measured step).
			t = time.tick_now()
			if _, kok := op_key(&c, KEYCODE_BACK); !kok {
				fmt.eprintln("back failed")
				os.exit(1)
			}
			bs, bok := settle_default(&c)
			if !bok {
				fmt.eprintln("settle after back failed")
				os.exit(1)
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
			"  settle method: %d frame-stats, %d event fallback\n",
			methods[.Frames], methods[.Events],
		)
		path_label: string
		switch inject_path {
		case .Input_Manager:     path_label = "InputManager as shell uid (async, no transaction syncs)"
		case .UiAutomation_Fast: path_label = "UiAutomation, no animation wait (syncs input transactions)"
		case .UiAutomation:      path_label = "UiAutomation public API (waits for animations; see logcat tag SpikeAgent)"
		case:                    path_label = fmt.tprintf("unknown (%d)", u8(inject_path))
		}
		fmt.printf("  injection path: %s\n", path_label)
		fmt.printf("  TREE fallbacks (FIND brought back no visible exact match): %d\n", tree_fallbacks)
		fmt.println("  (\"FIND rounds needed\" > 1 means settle fired before the target was on screen.)")
		fmt.println("  (a slow probe means the app's main thread was busy, so settle correctly kept waiting.)")
	}
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
