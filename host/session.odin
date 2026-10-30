// speedrun session: one connection to a device kept open between commands, for an AI agent
// (or a person) exploring an app a command at a time instead of editing and rerunning a flow.
// `session start` starts a background process that holds the device's agent; `speedrun do`
// runs flow commands there and answers with how each went and what changed on screen;
// `speedrun look` lists the screen, a line per element, each with a ref (@7) that `do` takes
// in place of a selector; `session save` writes the commands that passed as a flow file.
// The output is short on purpose: an agent reads every token of it.
package speedrun

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode"

SESSION_USAGE :: `usage:
  speedrun session start --app <appId> [--platform android|ios] [--device <id>] [-e KEY=VALUE]...
  speedrun look [--shot]          the screen, a line per element, each with a ref (@7)
  speedrun do '<command>'...      flow commands, as written in a flow file (one per argument);
                                  @7 stands for that element's selector
  speedrun session log            the commands that passed, numbered
  speedrun session save <file>    them as a flow file
  speedrun session clear          forget them (the recording starts over)
  speedrun session status | stop
The session keeps the device's agent connected between commands (a command takes as long as
in a flow, nothing more), and ends after an idle hour (SPEEDRUN_SESSION_IDLE_S).`

SESSION_START_TIMEOUT :: 180 * time.Second // the iOS agent's first start takes a while
SESSION_IDLE_S :: 3600
// A request's limits. Any program on the Mac can connect, the session serves one client at a
// time: one that sends nothing, or a size no request has, must not hold it up or make it
// allocate gigabytes.
SESSION_REQUEST_MAX :: 16 * 1024 * 1024
SESSION_REQUEST_WAIT :: 5 * time.Second

Session_Info :: struct {
	pid:      int `json:"pid"`,
	port:     int `json:"port"`,
	token:    string `json:"token"`,
	app:      string `json:"app"`,
	platform:  string `json:"platform"`,
	device:    string `json:"device"`, // its name, for messages
	device_id: string `json:"device_id"`, // adb serial or simulator UDID ("": the default device)
}

// Set in the session's own process: it is the one holding the device.
in_session := false

// The running session holds the device another run is about to use: a run there would stop
// its agent (Android's) or wait for it (iOS's serves one client at a time).
session_conflict :: proc(d: ^Device) -> string {
	if in_session do return ""
	info, ok := session_running()
	if !ok || info.platform != ("ios" if d.platform == .IOS else "android") do return ""
	id := d.udid if d.platform == .IOS else adb_serial
	if id != "" && info.device_id != "" && id != info.device_id do return ""
	return fmt.tprintf("A speedrun session holds %s (app %s): stop it first (speedrun session stop), or drive it with speedrun do and speedrun look.", info.device, info.app)
}

Session :: struct {
	r:        Runner,
	app:      string,
	token:    string,
	device:   string, // its name, for messages
	refs:     map[string]int, // an element (its id, else class and label; its rank among equal ones) -> its ref
	next_ref: int,
	ref_sel:  map[int]string, // ref -> the selector it stands for, as YAML
	ref_check: map[int]string, // ref -> the selector in an assertion: with its text too
	ref_line: map[int]string, // ref -> its line when last shown
	after_do: map[int]bool, // the refs on screen when the last `do` ended
	shown:    map[int]string, // the last screen: ref -> line (0: the keyboard), for what changed
	recorded: [dynamic]string, // the commands that passed, as flow items ("- tapOn: ...")
	shots:    int,
}

SESSION_TOKEN_ENV :: "SPEEDRUN_SESSION_TOKEN" // session start to session serve

session_dir :: proc() -> string {
	if xdg := os.get_env("XDG_STATE_HOME", context.temp_allocator); xdg != "" do return fmt.tprintf("%s/speedrun/session", xdg)
	return fmt.tprintf("%s/.speedrun/session", os.get_env("HOME", context.temp_allocator))
}

@(private = "file")
info_path :: proc() -> string {
	return fmt.tprintf("%s/session.json", session_dir())
}

// The running session, if its process is alive.
session_running :: proc() -> (info: Session_Info, ok: bool) {
	data, err := os.read_entire_file(info_path(), context.temp_allocator)
	if err != nil do return
	if json.unmarshal(data, &info, allocator = context.temp_allocator) != nil do return
	if info.pid <= 0 || info.port <= 0 do return
	// kill -0: the process exists.
	if posix.kill(posix.pid_t(info.pid), posix.Signal(0)) != .OK do return
	return info, true
}

// ---- the CLI side ---------------------------------------------------------------------

run_session_cli :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.println(SESSION_USAGE)
		return 2
	}
	switch args[0] {
	case "start":
		return session_start(args[1:])
	case "serve":
		return session_serve(args[1:])
	case "stop":
		if _, ok := session_running(); !ok {
			fmt.println("No session running.")
			return 0
		}
		return session_call("stop", "")
	case "status", "log", "clear":
		return session_call(args[0], "")
	case "save":
		if len(args) != 2 {
			fmt.eprintln("usage: speedrun session save <file.yaml>")
			return 2
		}
		return session_call("save", args[1])
	case "-h", "--help", "help":
		fmt.println(SESSION_USAGE)
		return 0
	}
	fmt.eprintf("unknown session command: %s\n%s\n", args[0], SESSION_USAGE)
	return 2
}

run_do_cli :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" {
		fmt.println(`usage: speedrun do '<command>'...   (in a session: speedrun session start --app <appId>)
  speedrun do 'tapOn: "Sign in"'
  speedrun do 'inputText: hello' 'pressKey: Enter'
  speedrun do 'tapOn: @7'         (@7: a ref from speedrun look)
  speedrun do -                   (commands from stdin, as in a flow file)`)
		return 0 if len(args) > 0 else 2
	}
	cmds := args
	if len(args) == 1 && args[0] == "-" {
		data, err := os.read_entire_file_from_file(os.stdin, context.allocator)
		if err != nil {
			fmt.eprintln("could not read stdin")
			return 2
		}
		cmds = []string{string(data)}
	}
	return session_call("do", strings.join(cmds, "\x00"))
}

run_look_cli :: proc(args: []string) -> int {
	flags := strings.join(args, " ")
	for a in args do if a != "--shot" && a != "--all" {
		fmt.eprintln("usage: speedrun look [--shot] [--all]")
		return 2
	}
	return session_call("look", flags)
}

@(private = "file")
session_start :: proc(args: []string) -> int {
	app, platform, device := "", "", ""
	env: [dynamic]string
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value := args[i + 1] if i + 1 < len(args) else ""
		switch {
		case a == "--app" && value != "":
			app = value
		case (a == "--platform" || a == "-p") && value != "":
			platform = value
		case (a == "--device" || a == "--udid") && value != "":
			device = value
		case (a == "-e" || a == "--env") && value != "":
			append(&env, value)
		case:
			fmt.eprintf("unknown option or missing value: %s\n%s\n", a, SESSION_USAGE)
			return 2
		}
		i += 1
	}
	code, text := start_session(app, platform, device, env[:])
	if code == 0 do fmt.println(text)
	else do fmt.eprintln(text)
	return code
}

// Starts the session process and waits until it serves (or says why it did not start).
start_session :: proc(app, platform, device: string, env: []string) -> (code: int, text: string) {
	if app == "" do return 2, "A session needs the app's id (--app): the app its commands are for (launchApp's)."
	update_check_start()
	if info, ok := session_running(); ok {
		if info.app == app && (device == "" || device == info.device_id) {
			return 0, fmt.tprintf("A session is running already: %s, app %s.", info.device, info.app)
		}
		return 1, fmt.tprintf("A session is running (%s, app %s): stop it first.", info.device, info.app)
	}
	dir := session_dir()
	if !make_dirs(dir) do return 1, fmt.tprintf("could not create %s", dir)
	// The user's alone: it holds the session's token (session.json), the log of what the app
	// showed, screenshots. A Mac's home folder is readable by its other users (group staff).
	_ = os.change_mode(dir, {.Read_User, .Write_User, .Execute_User})
	os.remove(info_path())
	key: [16]byte
	crypto.rand_bytes(key[:])
	token := string(hex.encode(key[:], context.temp_allocator))
	exe, _ := os.get_executable_path(context.temp_allocator)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "perl", "-MPOSIX=setsid", "-e", "setsid(); exec @ARGV", exe, "session", "serve", "--app", app)
	if platform != "" do append(&cmd, "--platform", platform)
	if device != "" do append(&cmd, "--device", device)
	for e in env do append(&cmd, "-e", e)
	log := fmt.tprintf("%s/session.log", dir)
	f, ferr := os.open(log, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if ferr != nil do return 1, fmt.tprintf("could not create %s: %v", log, ferr)
	defer os.close(f)
	_ = os.change_mode(log, {.Read_User, .Write_User}) // one created before
	// The token in the environment, not the command line: any user of the Mac sees those (ps).
	environ, _ := os.environ(context.temp_allocator)
	server_env := make([dynamic]string, 0, len(environ) + 1, context.temp_allocator)
	append(&server_env, ..environ)
	append(&server_env, fmt.tprintf("%s=%s", SESSION_TOKEN_ENV, token))
	// Not our stdin: under `speedrun mcp` it is the client's channel.
	null, nerr := os.open("/dev/null", {.Read})
	if nerr != nil do return 1, "could not open /dev/null"
	defer os.close(null)
	p, perr := os.process_start({command = cmd[:], env = server_env[:], stdin = null, stdout = f, stderr = f})
	if perr != nil do return 1, fmt.tprintf("could not start the session: %v", perr)
	start := time.tick_now()
	for time.tick_since(start) < SESSION_START_TIMEOUT {
		if info, ok := session_running(); ok && info.pid == p.pid {
			text = fmt.tprintf("Session on %s (%s), app %s. Next: look at the screen, then run commands.", info.device, info.platform, info.app)
			if notice := update_notice(); notice != "" do text = fmt.tprintf("%s\n%s", text, notice)
			return 0, text
		}
		if state, werr := os.process_wait(p, 0); werr == nil && state.exited {
			data, _ := os.read_entire_file(log, context.temp_allocator)
			return 1, fmt.tprintf("The session did not start:\n%s", strings.trim_space(string(data)))
		}
		time.sleep(50 * time.Millisecond)
	}
	return 1, fmt.tprintf("The session did not start within %v (its log: %s).", SESSION_START_TIMEOUT, log)
}

// One request to the session, printed: its answer to stdout, a failure to reach it to stderr.
@(private = "file")
session_call :: proc(verb, payload: string) -> int {
	code, text, answered := session_request(verb, payload)
	if !answered {
		fmt.eprintln(text)
		return code
	}
	if len(text) > 0 {
		os.write_string(os.stdout, text)
		if text[len(text) - 1] != '\n' do fmt.println()
	}
	return code
}

// One request to the session: its status (0: done) and answer. answered = false: no session,
// or it did not answer (text says so).
session_request :: proc(verb, payload: string) -> (code: int, text: string, answered: bool) {
	info, ok := session_running()
	if !ok do return 1, "No session running: start one (speedrun session start --app <appId>).", false
	ep, _ := net.parse_endpoint(fmt.tprintf("127.0.0.1:%d", info.port))
	sock, err := net.dial_tcp(ep)
	if err != nil do return 1, fmt.tprintf("The session (pid %d) does not answer: stop it, then start one.", info.pid), false
	defer net.close(sock)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	body := strings.concatenate({info.token, "\n", verb, "\n", cwd, "\n", payload}, context.temp_allocator)
	size: [4]u8
	put_u32(size[:], u32(len(body)))
	if !send_all(sock, size[:]) || !send_all(sock, transmute([]byte)body) do return 1, "The session closed the connection.", false
	head: [5]u8
	if !recv_all(sock, head[:]) do return 1, fmt.tprintf("The session closed the connection (its log: %s/session.log).", session_dir()), false
	answer := make([]u8, int(get_u32(head[1:5])), context.temp_allocator)
	if !recv_all(sock, answer) do return 1, "The session closed the connection.", false
	return int(head[0]), string(answer), true
}

@(private = "file")
put_u32 :: proc(b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

@(private = "file")
get_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

// ---- the session process --------------------------------------------------------------

@(private = "file")
session_serve :: proc(args: []string) -> int {
	app, platform, device := "", "", ""
	env: [dynamic]string
	for i := 0; i + 1 < len(args); i += 2 {
		switch args[i] {
		case "--app":      app = args[i + 1]
		case "--platform": platform = args[i + 1]
		case "--device":   device = args[i + 1]
		case "-e":         append(&env, args[i + 1])
		}
	}
	token := os.get_env(SESSION_TOKEN_ENV, context.allocator)
	if token == "" {
		fmt.eprintln("no session token (session serve is started by session start)")
		return 1
	}
	os.unset_env(SESSION_TOKEN_ENV) // not for the tools it starts
	in_session = true
	dev := Device {
		port = 7777,
	}
	if err := device_select(&dev, platform, device, false); err != "" {
		fmt.eprintln(err)
		return 1
	}
	if err := device_start(&dev); err != "" {
		device_stop(&dev)
		fmt.eprintln(err)
		return 1
	}
	defer device_stop(&dev)
	c, ok := connect(agent_port(&dev))
	if !ok {
		fmt.eprintf("could not reach the agent on port %d\n", agent_port(&dev))
		return 1
	}
	defer net.close(c.sock)
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		fmt.eprintln("could not listen:", lerr)
		return 1
	}
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)

	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	s := Session {
		app   = app,
		token = token,
		next_ref = 1,
	}
	r := &s.r
	r^ = Runner {
		c       = &c,
		dev     = &dev,
		alloc   = context.allocator,
		debug   = os.get_env("SPEEDRUN_DEBUG", context.allocator) != "",
		env_gen = 1,
		log_rec = -1,
	}
	_ = virtual.arena_init_growing(&r.screen_arena)
	defer virtual.arena_destroy(&r.screen_arena)
	defer js_stop(r)
	defer location_stop_updates(r)
	defer if r.recording.active do _ = stop_recording(r)
	if !read_screen(r) {
		fmt.eprintln("could not read the screen")
		return 1
	}
	push_scope(r)
	device_id := dev.udid if dev.platform == .IOS else adb_serial
	if device_id != "" do r.env[0]["MAESTRO_DEVICE_UDID"] = device_id
	for e in env {
		k, _, v := strings.partition(e, "=")
		r.env[0][k] = v
	}
	r.last_interaction = time.tick_now()

	name := dev.name
	if dev.platform == .Android {
		name = strings.trim_space(shell(r, "getprop ro.boot.qemu.avd_name"))
		if name == "" do name = strings.trim_space(shell(r, "getprop ro.product.model"))
		if adb_serial != "" do name = fmt.aprintf("%s (%s)", name, adb_serial)
	}
	s.device = name
	info := Session_Info{os.get_pid(), bound.port, token, app, "ios" if dev.platform == .IOS else "android", name, device_id}
	data, _ := json.marshal(info, {}, context.temp_allocator)
	tmp := fmt.tprintf("%s.tmp", info_path())
	if os.write_entire_file(tmp, data, {.Read_User, .Write_User}) != nil || os.rename(tmp, info_path()) != nil {
		fmt.eprintln("could not write", info_path())
		return 1
	}
	defer os.remove(info_path())
	fmt.printf("serving on 127.0.0.1:%d\n", bound.port)

	idle := time.Duration(SESSION_IDLE_S) * time.Second
	if v, vok := strconv.parse_int(os.get_env("SPEEDRUN_SESSION_IDLE_S", context.temp_allocator)); vok && v > 0 do idle = time.Duration(v) * time.Second
	// accept wakes up every 30 s: the agent gets a ping (iOS's stops itself after 10 idle
	// minutes), and the session ends once idle too long.
	_ = net.set_option(listener, .Receive_Timeout, 30 * time.Second)
	last := time.tick_now()
	for {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			if time.tick_since(last) > idle {
				fmt.println("idle: stopping")
				break
			}
			if _, pok := op_ping(&c); !pok {
				fmt.eprintln("the agent stopped answering")
				break
			}
			continue
		}
		last = time.tick_now()
		_ = net.set_option(client, .Receive_Timeout, SESSION_REQUEST_WAIT)
		stop := session_handle(&s, client)
		net.close(client)
		free_all(context.temp_allocator)
		if stop do break
	}
	return 0
}

// Serves one request: token, verb, the client's working directory, then the payload, a line
// each (the payload to the end). The answer: a status byte, then text.
@(private = "file")
session_handle :: proc(s: ^Session, sock: net.TCP_Socket) -> (stop: bool) {
	size: [4]u8
	if !recv_all(sock, size[:]) do return
	if get_u32(size[:]) > SESSION_REQUEST_MAX do return
	body := make([]u8, int(get_u32(size[:])), context.temp_allocator)
	if !recv_all(sock, body) do return
	token, _, rest := strings.partition(string(body), "\n")
	verb, _, rest2 := strings.partition(rest, "\n")
	cwd, _, payload := strings.partition(rest2, "\n")
	code: u8
	out: string
	switch {
	case crypto.compare_constant_time(transmute([]u8)token, transmute([]u8)s.token) != 1:
		code, out = 2, "not this session's token"
	case (verb == "do" || verb == "look") && !agent_alive(s):
		code, out = 1, "The device's agent stopped and could not be started again (see the session's log); speedrun session stop, then start one."
	case verb == "do":
		code, out = session_do(s, cwd, payload)
	case verb == "look":
		code, out = session_look(s, strings.contains(payload, "--shot"), strings.contains(payload, "--all"))
	case verb == "log":
		b := strings.builder_make(context.temp_allocator)
		if len(s.recorded) == 0 do strings.write_string(&b, "No commands passed yet.")
		for c, k in s.recorded do fmt.sbprintf(&b, "%d %s\n", k + 1, c[2:])
		out = strings.to_string(b)
	case verb == "save":
		code, out = session_save(s, cwd, payload)
	case verb == "clear":
		clear(&s.recorded)
		out = "The recording starts over."
	case verb == "status":
		out = fmt.tprintf("Session on %s, app %s: %d commands recorded.", s.device, s.app, len(s.recorded))
	case verb == "stop":
		out, stop = "Session stopped.", true
	case:
		code, out = 2, fmt.tprintf("unknown request: %s", verb)
	}
	head: [5]u8
	head[0] = code
	put_u32(head[1:5], u32(len(out)))
	_ = send_all(sock, head[:]) && send_all(sock, transmute([]byte)out)
	return
}

// The agent answers, else it is started again (a test run on the device, the agent's own
// idle stop) and connected to.
@(private = "file")
agent_alive :: proc(s: ^Session) -> bool {
	if _, ok := op_ping(s.r.c); ok do return true
	fmt.println("the agent does not answer: connecting again")
	net.close(s.r.c.sock)
	if err := device_restart(s.r.dev); err != "" {
		fmt.eprintln(err)
		return false
	}
	c, ok := connect(agent_port(s.r.dev))
	if !ok do return false
	s.r.c^ = c
	return true
}

// Runs the commands (one per argument, or a list), then answers with a line per command and
// what changed on screen. The ones that passed are recorded, refs replaced by selectors.
@(private = "file")
session_do :: proc(s: ^Session, cwd, payload: string) -> (code: u8, out: string) {
	r := &s.r
	items := make([dynamic]string, context.temp_allocator)
	for arg in strings.split(payload, "\x00", context.temp_allocator) {
		if strings.trim_space(arg) == "" do continue
		resolved, rerr := resolve_refs(s, arg)
		if rerr != "" do return 2, rerr
		text := dedent(strings.trim_right(resolved, " \t\r\n"))
		if strings.has_prefix(text, "- ") || text == "-" {
			// A list: its items, each from a "- " at the margin to the next.
			start := 0
			lines := strings.split_lines(text, context.temp_allocator)
			offset := 0
			for line, k in lines {
				if k > 0 && strings.has_prefix(line, "-") {
					append(&items, strings.trim_right(text[start:offset - 1], " \n"))
					start = offset
				}
				offset += len(line) + 1
			}
			append(&items, strings.trim_right(text[start:], " \n"))
		} else {
			append(&items, as_item(text))
		}
	}
	if len(items) == 0 do return 2, "No command given."
	header := fmt.tprintf("appId: %s\n---\n", yaml_plain(s.app))
	// In the session's memory: commands keep strings of their text (env keys, the regex cache).
	text := strings.concatenate({header, strings.join(items[:], "\n", context.temp_allocator)}, r.alloc)
	flow, perr, pline := load_flow_text(fmt.tprintf("%s/session.yaml", cwd), text, r.alloc)
	if perr != "" {
		return 2, fmt.tprintf("Invalid command (line %d): %s\n%s", max(pline - 2, 1), perr, strings.join(items[:], "\n", context.temp_allocator))
	}
	if len(s.shown) == 0 {
		if !read_screen(r) do return 1, AGENT_LOST
		_ = screen_elements(s)
	}
	// The app changed on its own since the last `do` (a look saw it), and the first command
	// does not wait for an element (typing, a key, back): a flow would run it before the
	// change came. The recording waits for an element that appeared first (a focused field,
	// else one with an id).
	wait := ""
	if len(s.after_do) > 0 && len(flow.commands) > 0 && !waits_for_element(flow.commands[0]) {
		best, best_score := -1, 0
		for ref, line in s.shown {
			if ref == 0 || s.after_do[ref] do continue
			score := 1
			if strings.contains(line, " #") do score = 2
			if strings.has_prefix(line, "Field") && strings.contains(line, " focused") do score = 3
			if score > best_score || (score == best_score && ref < best) do best, best_score = ref, score
		}
		if best > 0 do wait = strings.concatenate({"- assertVisible: ", s.ref_check[best]}, context.temp_allocator)
	}
	view_init(r, &flow, "session", "", true, true)
	// Lookups wait from the last interaction: the time between requests is not the app's.
	r.last_interaction = time.tick_now()
	first := len(r.records)
	ok := run_list(r, flow.commands[:])
	// launchApp returns before the app is up: its UI is waited for here, as by the next command.
	due := pay_due(r)

	b := strings.builder_make(context.temp_allocator)
	k := 0
	failure := ""
	for &rec in r.records[first:] {
		if rec.depth != 0 do continue
		word := "ok"
		switch rec.status {
		case "FAILED":  word = "FAILED"
		case "WARNED":  word = "warned"
		case "SKIPPED": word = "skipped"
		}
		fmt.sbprintf(&b, "%s %s  %s\n", word, rec.evaluated if rec.evaluated != "" else rec.description, fmt_ms(rec.duration_ms))
		if rec.status == "COMPLETED" || rec.status == "WARNED" {
			if k == 0 && wait != "" do append(&s.recorded, strings.clone(wait, r.alloc))
			if k < len(items) do append(&s.recorded, strings.clone(items[k], r.alloc))
		}
		if rec.status == "FAILED" || rec.status == "WARNED" {
			// The message, without the screen it describes (the change below shows it).
			msg, _, _ := strings.partition(rec.error if rec.error != SUB_FLOW_FAILED else last_error(r, first), "\n      screen:")
			fmt.sbprintf(&b, "  %s\n", strings.trim_space(msg))
			if rec.status == "FAILED" do failure = msg
		}
		k += 1
	}
	if e, bad := due.?; bad {
		fmt.sbprintf(&b, "%s\n", e)
		ok = false
	}
	before := make(map[int]string, len(s.shown), context.temp_allocator)
	for ref, line in s.shown do before[ref] = line
	if !screen_current(r) || len(screen_elements(s)) == 0 {
		if !read_content(s) do return 1, strings.concatenate({strings.to_string(b), AGENT_LOST}, context.temp_allocator)
	}
	els := screen_elements(s)
	clear(&s.after_do)
	for e in els do s.after_do[e.ref] = true
	if failure != "" do similar(s, els, failure, &b)
	screen_change(s, els, before, &b)
	return 0 if ok else 1, strings.to_string(b)
}

// Reads the screen; one with nothing on it yet (an app's window up before its first render:
// React Native loading its bundle) is read again until something shows, up to 5 s, then
// settled.
@(private = "file")
read_content :: proc(s: ^Session) -> bool {
	r := &s.r
	start := time.tick_now()
	waited := false
	for {
		if !read_screen(r) do return false
		if len(screen_elements(s)) > 0 || time.tick_since(start) > 5 * time.Second do break
		waited = true
		time.sleep(100 * time.Millisecond)
	}
	if waited {
		if settle(r, no_change_ms = 0) != nil do return false
		return read_screen(r)
	}
	return true
}

// A command that waits for its element (up to the lookup's time), so it runs once a screen
// it needs has come.
@(private = "file")
waits_for_element :: proc(c: Cmd) -> bool {
	#partial switch _ in c.data {
	case Tap, Assert, Scroll_Until, Copy_Text: return true
	}
	return false
}

// The innermost failure among the records from `first` on.
@(private = "file")
last_error :: proc(r: ^Runner, first: int) -> string {
	msg := ""
	for rec in r.records[first:] do if rec.status == "FAILED" && rec.error != "" && rec.error != SUB_FLOW_FAILED do msg = rec.error
	return msg
}

@(private = "file")
session_look :: proc(s: ^Session, shot, all: bool) -> (code: u8, out: string) {
	r := &s.r
	if e, bad := pay_due(r).?; bad do return 1, e
	if !read_content(s) do return 1, AGENT_LOST
	els := screen_elements(s)
	b := strings.builder_make(context.temp_allocator)
	write_screen(s, els, &b)
	// Every node of the read, indented by depth: what the listing leaves out, for when it
	// leaves out too much.
	if all {
		strings.write_string(&b, "all nodes:\n")
		for k in r.h.order {
			n := r.h.nodes[k]
			fmt.sbprintf(&b, "%s%s %d,%d-%d,%d", strings.repeat("  ", int(n.depth), context.temp_allocator), n.class[strings.last_index_byte(n.class, '.') + 1:], n.left, n.top, n.right, n.bottom)
			if n.text != "" do fmt.sbprintf(&b, " text=%s", quoted(n.text, 80))
			if n.desc != "" && n.desc != n.text do fmt.sbprintf(&b, " desc=%s", quoted(n.desc, 80))
			if n.id != "" do fmt.sbprintf(&b, " #%s", n.id)
			if n.hint != "" do fmt.sbprintf(&b, " hint=%s", quoted(n.hint, 40))
			strings.write_string(&b, "\n")
		}
	}
	if shot {
		path, err := session_shot(s)
		if err != "" do return 1, err
		fmt.sbprintf(&b, "screenshot: %s\n", path)
	}
	return 0, strings.to_string(b)
}

@(private = "file")
session_save :: proc(s: ^Session, cwd, file: string) -> (code: u8, out: string) {
	if len(s.recorded) == 0 do return 1, "No commands passed yet: nothing to save."
	path := file if strings.has_prefix(file, "/") else fmt.tprintf("%s/%s", cwd, file)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "appId: %s\n---\n", yaml_plain(s.app))
	for c in s.recorded do fmt.sbprintf(&b, "%s\n", c)
	if !write_file(path, transmute([]byte)strings.to_string(b)) do return 1, fmt.tprintf("could not write %s", path)
	return 0, fmt.tprintf("Saved %d commands to %s.", len(s.recorded), file)
}

// ---- the screen, in a few lines -------------------------------------------------------

Element :: struct {
	node: int,
	ref:  int,
	line: string, // without the ref
}

// What a user can see or act on, in reading order: nodes with a text, an id or a field, not
// the status bar, the keyboard as one line. A node with an id but no text of its own (an
// Android button around its label) is labelled with its texts, and a text its container
// already says is left out. Refs are kept by line across reads (the same element keeps its
// ref), and each stands for a selector that finds that element now.
@(private = "file")
screen_elements :: proc(s: ^Session) -> []Element {
	r := &s.r
	out := make([dynamic]Element, context.temp_allocator)
	skip := make([]bool, len(r.h.nodes), context.temp_allocator)
	label_of := make(map[int]string, 64, context.temp_allocator)
	seen := make(map[string]int, 64, context.temp_allocator)
	keyboard := false
	hide :: proc(r: ^Runner, skip: []bool, k: int) {
		skip[k] = true
		for m in subtree(r, k) do skip[m] = true
	}
	// Windows left out: a status or navigation bar along an edge, Android's keyboard.
	for root in r.h.roots {
		n := r.h.nodes[root]
		bar := root != r.h.roots[0] && n.bottom - n.top < r.h_px / 10 && (n.top <= 0 || n.bottom >= r.h_px)
		ime := false
		for k in subtree(r, root) do if strings.contains(r.h.nodes[k].id, "inputmethod") {
			ime = true
			break
		}
		if bar || ime do hide(r, skip, root)
		if ime do keyboard = true
	}
	// An id identifies an element when it is the only one on screen.
	ids := make(map[string]int, 64, context.temp_allocator)
	for k in r.h.order do if r.h.nodes[k].id != "" do ids[r.h.nodes[k].id] += 1
	for k in r.h.order {
		if skip[k] do continue
		n := r.h.nodes[k]
		if n.class == "StatusBar" || n.class == "Keyboard" {
			hide(r, skip, k)
			if n.class == "Keyboard" do keyboard = true
			continue
		}
		// Not a window's root (iOS's Application), nor iOS's scroll indicators ("0%").
		if n.parent < 0 || visible_share(n, r.w, r.h_px) <= 0 || scroll_indicator(r, n) do continue
		label := n.text if n.text != "" else n.desc
		field := is_field(n.class)
		if field && label == n.hint do label = "" // empty: Android reports the hint as its text
		action := actionable(r, n)
		// Android's own layouts carry ids (android:id/title): not worth a line by themselves.
		id := n.id if ids[n.id] == 1 else ""
		named := id != "" && !(r.dev.platform != .IOS && strings.contains(id, ":id/"))
		if label == "" && action && !field do label = inner_texts(r, k)
		if label == "" && !field && !action && !named do continue
		if !named && label != "" {
			for a := n.parent; a >= 0; a = r.h.nodes[a].parent {
				if l, has := label_of[a]; has {
					// Said by its container already, or an icon's glyph in a labelled button.
					if strings.contains(l, label) || (l != "" && strings.contains(label, l)) || (l != "" && !has_word(label)) do label = ""
					break
				}
			}
			if label == "" do continue
		}
		label_of[k] = label
		line := element_line(r, n, label, id, field, action)
		// The same element keeps its ref while its state or a field's value changes.
		what := strings.concatenate({"#", id}, context.temp_allocator) if id != "" else fmt.tprintf("%s\x00%s", short_class(n.class, field), label)
		rank := seen[what]
		seen[what] = rank + 1
		key := fmt.tprintf("%s\x00%d", what, rank)
		ref, known := s.refs[key]
		if !known {
			ref = s.next_ref
			s.next_ref += 1
			s.refs[strings.clone(key, s.r.alloc)] = ref
		}
		tap_sel, check_sel := element_selector(r, k, field)
		s.ref_sel[ref] = strings.clone(tap_sel, s.r.alloc)
		s.ref_check[ref] = strings.clone(check_sel, s.r.alloc) if check_sel != tap_sel else s.ref_sel[ref]
		if s.ref_line[ref] != line do s.ref_line[ref] = strings.clone(line, s.r.alloc)
		append(&out, Element{k, ref, line})
	}
	if keyboard do append(&out, Element{-1, 0, "Keyboard"})
	clear(&s.shown)
	for e in out do s.shown[e.ref] = strings.clone(e.line, s.r.alloc)
	return out[:]
}

// A letter or a digit in s: words, not an icon's glyph (⌂, ✉).
@(private = "file")
has_word :: proc(s: string) -> bool {
	for ch in s do if unicode.is_letter(ch) || unicode.is_digit(ch) do return true
	return false
}

// Something to tap: Android's clickable views; iOS's buttons, cells, links and controls.
@(private = "file")
actionable :: proc(r: ^Runner, n: H_Node) -> bool {
	if r.dev.platform != .IOS do return .Clickable in n.flags
	switch n.class {
	case "Button", "Cell", "Link", "Switch", "Toggle", "CheckBox", "Image": return true
	}
	return strings.has_prefix(n.class, "ElementType")
}

// The texts inside node k, as iOS joins a button's: "Qty, 2".
@(private = "file")
inner_texts :: proc(r: ^Runner, k: int) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for m in subtree(r, k) {
		if m == k do continue
		n := r.h.nodes[m]
		t := n.text if n.text != "" else n.desc
		if t != "" do append(&parts, t)
		if len(parts) == 4 do break
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

@(private = "file")
is_field :: proc(class: string) -> bool {
	return strings.has_suffix(class, "EditText") || class == "TextField" || class == "SecureTextField" || class == "SearchField" || class == "TextView"
}

// `Button "Sign in" #signin checked`: a short class, the label, the id, the state.
@(private = "file")
element_line :: proc(r: ^Runner, n: H_Node, label, id: string, field, action: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	class := short_class(n.class, field)
	if action && class == "View" do class = "Button"
	strings.write_string(&b, class)
	if label != "" do fmt.sbprintf(&b, " %s", quoted(label, 80))
	if id != "" do fmt.sbprintf(&b, " #%s", id)
	if field && n.hint != "" && n.hint != label do fmt.sbprintf(&b, " hint=%s", quoted(n.hint, 40))
	if .Checked in n.flags do strings.write_string(&b, " checked")
	if .Selected in n.flags do strings.write_string(&b, " selected")
	if .Focused in n.flags && field do strings.write_string(&b, " focused")
	if .Enabled not_in n.flags && (.Clickable in n.flags || n.class == "Button") do strings.write_string(&b, " disabled")
	if .Scrollable in n.flags do strings.write_string(&b, " scrollable")
	if n.error != "" do fmt.sbprintf(&b, " error=%s", quoted(n.error, 80))
	return strings.to_string(b)
}

// "text" with " and \ escaped, newlines as \n, cut at `room` characters.
@(private = "file")
quoted :: proc(s: string, room: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	count := 0
	for ch in s {
		if count == room {
			strings.write_string(&b, "…")
			break
		}
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case:      strings.write_rune(&b, ch)
		}
		count += 1
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

@(private = "file")
short_class :: proc(class: string, field: bool) -> string {
	c := class[strings.last_index_byte(class, '.') + 1:]
	if field do return "SecureField" if c == "SecureTextField" else "Field"
	switch c {
	case "StaticText", "TextView":                                         return "Text"
	case "Other", "ViewGroup", "View", "FrameLayout", "LinearLayout", "RelativeLayout": return "View"
	case "ImageView", "Image":                                             return "Image"
	case "ImageButton":                                                    return "Button"
	case "RadioButton":                                                    return "Radio"
	case "CheckBox":                                                       return "Checkbox"
	}
	return c
}

// A selector that finds node k first (or a node in it: a text selector takes the deepest
// match), as flow YAML: the id, else the text, alone if it picks k, else with an index; else
// k's center as a point.
@(private = "file")
element_selector :: proc(r: ^Runner, k: int, field: bool) -> (tap, check: string) {
	n := r.h.nodes[k]
	inside :: proc(r: ^Runner, k, m: int) -> bool {
		for a := m; a >= 0; a = r.h.nodes[a].parent do if a == k do return true
		return false
	}
	label := n.text if n.text != "" else n.desc
	if label == "" {
		// A row or button around its texts: its first text finds it (or a node in it).
		for m in subtree(r, k) {
			t := r.h.nodes[m].text if r.h.nodes[m].text != "" else r.h.nodes[m].desc
			if m != k && t != "" {
				label = t
				break
			}
		}
	}
	Try :: struct {
		field, value: string,
	}
	tries := [2]Try{{"id", n.id}, {"text", label}}
	for t in tries {
		if t.value == "" do continue
		sel := new(Selector, context.temp_allocator)
		pattern := rx_escape(t.value)
		if t.field == "id" {
			sel.id = pattern
		} else {
			sel.text = pattern
		}
		res, err := apply(r, sel, r.h.order[:])
		if err != nil do continue
		for m, i in res {
			if !inside(r, k, m) do continue
			// (Concatenated: fmt reads a { as the start of an argument index.)
			if i == 0 && t.field == "text" do return yaml_string(pattern), yaml_string(pattern)
			index := strings.concatenate({", index: ", fmt.tprint(i)}, context.temp_allocator) if i > 0 else ""
			tap = strings.concatenate({"{", t.field, ": ", yaml_string(pattern), index, "}"}, context.temp_allocator)
			// An assertion on an element with an id and a text checks both (not a field's
			// value: it is what changes).
			own := n.text if n.text != "" else n.desc
			if t.field == "id" && own != "" && !field && i == 0 {
				return tap, strings.concatenate({"{id: ", yaml_string(pattern), ", text: ", yaml_string(rx_escape(own)), "}"}, context.temp_allocator)
			}
			return tap, tap
		}
	}
	x := 100 * f64(n.left + (n.right - n.left) / 2) / f64(max(r.w, 1))
	y := 100 * f64(n.top + (n.bottom - n.top) / 2) / f64(max(r.h_px, 1))
	point := strings.concatenate({"{point: \"", fmt.tprintf("%d%%,%d%%", int(x + 0.5), int(y + 0.5)), "\"}"}, context.temp_allocator)
	return point, point
}

// A regex matching s exactly (selectors are regexes); `$` and `{` escaped keep ${...} out.
@(private = "file")
rx_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in s {
		switch ch {
		case '\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}':
			strings.write_byte(&b, '\\')
		}
		strings.write_rune(&b, ch)
	}
	return strings.to_string(b)
}

// s as is when it needs no quotes (an app id), else quoted.
@(private = "file")
yaml_plain :: proc(s: string) -> string {
	for ch in s do if !(unicode.is_letter(ch) || unicode.is_digit(ch) || ch == '.' || ch == '_' || ch == '-') do return yaml_string(s)
	return s
}

// A YAML double-quoted string.
@(private = "file")
yaml_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for ch in s {
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case:      strings.write_rune(&b, ch)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// The listing: a header, then `@ref line` per element.
@(private = "file")
write_screen :: proc(s: ^Session, els: []Element, b: ^strings.Builder) {
	r := &s.r
	fmt.sbprintf(b, "%s %dx%d, %d elements\n", "ios" if r.dev.platform == .IOS else "android", r.w, r.h_px, len(els))
	for e in els do fmt.sbprintf(b, "%s\n", ref_line(e))
}

// After commands: the new screen in full when most of it is new, else what changed, by ref:
// `+` new, `~` changed (its state, a field's value), `-` gone.
@(private = "file")
screen_change :: proc(s: ^Session, els: []Element, before: map[int]string, b: ^strings.Builder) {
	added := make([dynamic]Element, context.temp_allocator)
	changed := make([dynamic]Element, context.temp_allocator)
	now := make(map[int]bool, len(els), context.temp_allocator)
	for e in els {
		now[e.ref] = true
		if old, had := before[e.ref]; !had {
			append(&added, e)
		} else if old != e.line {
			append(&changed, e)
		}
	}
	gone := make([dynamic]int, context.temp_allocator)
	for ref in before do if !now[ref] do append(&gone, ref)
	slice.sort(gone[:])
	removed := make([dynamic]string, context.temp_allocator)
	for ref in gone do append(&removed, before[ref])
	if len(added) == 0 && len(changed) == 0 && len(removed) == 0 {
		strings.write_string(b, "screen unchanged\n")
		return
	}
	if len(before) == 0 || len(added) > 12 || 3 * len(added) > 2 * len(els) {
		strings.write_string(b, "screen now: ")
		write_screen(s, els, b)
		return
	}
	for e in added do fmt.sbprintf(b, "+ %s\n", ref_line(e))
	for e in changed do fmt.sbprintf(b, "~ %s\n", ref_line(e))
	for l, k in removed {
		if k == 8 {
			fmt.sbprintf(b, "- (%d more)\n", len(removed) - 8)
			break
		}
		fmt.sbprintf(b, "- %s\n", l)
	}
}

@(private = "file")
ref_line :: proc(e: Element) -> string {
	if e.ref > 0 do return fmt.tprintf("@%d %s", e.ref, e.line)
	return e.line
}

// After "Element not found: Text matching regex: X" or "Assertion is false: "X" is visible":
// the elements sharing a word of 4 letters or more with X, one containing the other, ignoring
// case (in their line: the label, inner texts included, and the id): "Shop" for "Shopping".
@(private = "file")
similar :: proc(s: ^Session, els: []Element, failure: string, b: ^strings.Builder) {
	pattern := ""
	if _, found, rest := strings.partition(failure, "regex: "); found != "" {
		pattern = rest
	} else if _, quote, rest2 := strings.partition(failure, "is false: \""); quote != "" {
		pattern, _, _ = strings.partition(rest2, "\"")
	}
	wanted := words(pattern)
	if len(wanted) == 0 do return
	shown := 0
	outer: for e in els {
		if e.ref == 0 do continue
		for w in words(e.line) do for x in wanted {
			if !strings.contains(w, x) && !strings.contains(x, w) do continue
			if shown == 0 do strings.write_string(b, "  similar:")
			fmt.sbprintf(b, " @%d %s;", e.ref, e.line)
			shown += 1
			if shown == 5 do break outer
			continue outer
		}
	}
	if shown > 0 do strings.write_string(b, "\n")
}

// The words of 4 letters or digits or more in s, lowercase.
@(private = "file")
words :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	word := strings.builder_make(context.temp_allocator)
	for ch in strings.to_lower(s, context.temp_allocator) {
		if unicode.is_letter(ch) || unicode.is_digit(ch) {
			strings.write_rune(&word, ch)
			continue
		}
		if strings.builder_len(word) >= 4 do append(&out, strings.clone(strings.to_string(word), context.temp_allocator))
		strings.builder_reset(&word)
	}
	if strings.builder_len(word) >= 4 do append(&out, strings.clone(strings.to_string(word), context.temp_allocator))
	return out[:]
}

// `tapOn: @7` -> `tapOn: {id: "qty-plus"}`: refs outside quotes become their selectors.
@(private = "file")
resolve_refs :: proc(s: ^Session, text: string) -> (out: string, err: string) {
	b := strings.builder_make(context.temp_allocator)
	quote: u8 = 0
	for i := 0; i < len(text); i += 1 {
		ch := text[i]
		switch {
		case quote != 0:
			if ch == quote do quote = 0
		case ch == '"' || ch == '\'':
			quote = ch
		case ch == '@' && i + 1 < len(text) && text[i + 1] >= '0' && text[i + 1] <= '9':
			j := i + 1
			for j < len(text) && text[j] >= '0' && text[j] <= '9' do j += 1
			ref, _ := strconv.parse_int(text[i + 1:j])
			// In an assertion (or a wait), the selector checks the text too.
			line_start := strings.last_index_byte(text[:i], '\n') + 1
			before_ref := text[line_start:i]
			checking := strings.contains(before_ref, "assert") || strings.contains(before_ref, "visible") || strings.contains(before_ref, "Visible")
			sel, ok := (s.ref_check if checking else s.ref_sel)[ref]
			if !ok do return "", fmt.tprintf("No element @%d: refs come from speedrun look (or a do's output).", ref)
			if _, shown := s.shown[ref]; !shown {
				return "", fmt.tprintf("@%d (%s) is not on the last screen read: speedrun look shows the current refs.", ref, s.ref_line[ref])
			}
			strings.write_string(&b, sel)
			i = j - 1
			continue
		}
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b), ""
}

// A command as a flow item: "- " before its first line, its other lines indented under it
// by 4 (their own indentation kept relative to each other).
@(private = "file")
as_item :: proc(text: string) -> string {
	lines := strings.split_lines(text, context.temp_allocator)
	margin := max(int)
	for l in lines[1:] {
		if strings.trim_space(l) == "" do continue
		margin = min(margin, len(l) - len(strings.trim_left_space(l)))
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "- %s", lines[0])
	for l in lines[1:] {
		strings.write_string(&b, "\n")
		if strings.trim_space(l) != "" do fmt.sbprintf(&b, "    %s", l[min(margin, len(l)):])
	}
	return strings.to_string(b)
}

// The lines without their common indentation.
@(private = "file")
dedent :: proc(text: string) -> string {
	lines := strings.split_lines(text, context.temp_allocator)
	margin := max(int)
	for l in lines {
		if strings.trim_space(l) == "" do continue
		margin = min(margin, len(l) - len(strings.trim_left_space(l)))
	}
	if margin == 0 || margin == max(int) do return text
	for &l in lines do l = l[min(margin, len(l)):]
	return strings.join(lines, "\n", context.temp_allocator)
}

// A screenshot scaled to 500 pixels wide (enough to read, a few hundred tokens for a
// model), in the session folder.
@(private = "file")
session_shot :: proc(s: ^Session) -> (path: string, err: string) {
	png, ok := op_screenshot(s.r.c, context.temp_allocator)
	if !ok do return "", "could not take a screenshot"
	img, dok := image_decode(png)
	if !dok do return "", "could not decode the screenshot"
	defer image_free(img)
	small := image_scale(img, 500)
	defer image_free(small)
	out, pok := image_png(small, context.temp_allocator)
	if !pok do return "", "could not encode the screenshot"
	s.shots += 1
	path = fmt.tprintf("%s/shot-%d.png", session_dir(), s.shots)
	if !write_file(path, out) do return "", fmt.tprintf("could not write %s", path)
	return path, ""
}

// The image scaled down to `width` pixels (each pixel the average of the block it covers);
// as is when narrower.
@(private = "file")
image_scale :: proc(img: Image, width: int) -> Image {
	if img.width <= width {
		return {slice_clone(img.pixels), img.width, img.height}
	}
	w := width
	h := max(1, img.height * width / img.width)
	pixels := make([]u8, w * h * 4)
	for y in 0 ..< h {
		y0, y1 := y * img.height / h, max((y + 1) * img.height / h, y * img.height / h + 1)
		for x in 0 ..< w {
			x0, x1 := x * img.width / w, max((x + 1) * img.width / w, x * img.width / w + 1)
			sum: [4]int
			for sy in y0 ..< y1 do for sx in x0 ..< x1 {
				p := img.pixels[(sy * img.width + sx) * 4:]
				for c in 0 ..< 4 do sum[c] += int(p[c])
			}
			count := (y1 - y0) * (x1 - x0)
			for c in 0 ..< 4 do pixels[(y * w + x) * 4 + c] = u8(sum[c] / count)
		}
	}
	return {pixels, w, h}
}

@(private = "file")
slice_clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}
