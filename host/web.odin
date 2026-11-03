// The web "device": Chrome, driven over the DevTools protocol through a pipe (Chrome's
// --remote-debugging-pipe: requests on its fd 3, answers and events on its fd 4, each message
// JSON ended by a NUL), with no WebDriver, Selenium or Node in between; or Firefox (device
// "firefox"), driven over WebDriver BiDi on a WebSocket (web_firefox.odin). Flows run on it through
// the same agent operations as on Android and iOS: an agent thread in this process serves them
// on 127.0.0.1 (a port of its own, the per-run token first, as the other agents), and turns each
// into DevTools calls and calls into web/agent.js, which runs in every document of the page.
//
// Chrome: SPEEDRUN_CHROME when set; else for --headless Chrome's headless shell, and otherwise
// the Chrome installed on this machine; either downloaded from Chrome for Testing into the
// user's cache when this machine has none.
package speedrun

import "base:runtime"
import "core:c"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

WEB_AGENT_JS :: #load("web/agent.js", string)
// The page's agent (agent.js), set up first for the current document when it is not yet.
WEB_AGENT :: "((window.__speedrun && window.__speedrun.document === document) || !window.__speedrunInstall || window.__speedrunInstall(), window.__speedrun)"

WEB_DEVICE :: "chromium" // the device a web flow runs on (Maestro's name for it)
WEB_DEFAULT_SIZE :: [2]int{1024, 768} // the headless window, as Maestro's
WEB_START_TIMEOUT :: 30 * time.Second
WEB_CALL_TIMEOUT :: 30 * time.Second // a DevTools call that takes longer: Chrome is stuck
WEB_LOAD_TIMEOUT :: 30 * time.Second // a navigation's document
WEB_SYNTHETIC :: 100000 // <option>s live from here (agent.js's SYNTHETIC)

// SPEEDRUN_WEB_DEBUG: every DevTools message in and out, on stderr.
web_debug: bool

// --headless and --screen-size (cli.odin).
web_headless: bool
web_size: [2]int

// Op values past the mobile agents' (host/main.odin's Op enum goes to 24).
WEB_OP_NAVIGATE :: 25 // str url -> u8 ok, str error
WEB_OP_CLEAR :: 26 // str url: the data of its origin -> u8 ok
WEB_OP_CSS :: 27 // str selector -> u8 ok, (ok) u32 count, count * u32 index into the last read; (not) str error
WEB_OP_GLOBALS :: 28 // str "key\x1fvalue\x1e..." -> empty: launch arguments, as globals of every document
WEB_OP_GEO :: 29 // str "latitude longitude" -> empty
WEB_OP_RECORD :: 30 // u8 on -> (off) u32 count, count * (u32 ms, u32 len, jpeg)
WEB_OP_CHANGE :: 31 // i32 timeout_ms -> u8 changed: waits for the page to change after the last read
WEB_OP_REVEAL :: 32 // i32 index in the last read -> u8 ok: scrolls it into view
WEB_OP_STEADY :: 33 // i32 index in the last read, i32 timeout_ms -> u8 waited: until it stops moving

Web_Page :: struct {
	session: string, // its DevTools session
	target:  string, // its target id, which is its main frame's id
}

Web :: struct {
	pid:          posix.pid_t,
	to, from:     posix.FD, // the pipe's ends on this side: to Chrome's fd 3, from its fd 4 (Firefox: its WebSocket, both)
	firefox:      bool, // Firefox over WebDriver BiDi (web_firefox.odin), not Chrome over DevTools
	no_sandbox:   bool, // Chrome without its sandbox: a start with it failed (web_start)
	ws_raw:       [dynamic]byte, // Firefox: read from the WebSocket, not yet a whole frame
	ws_message:   [dynamic]byte, // Firefox: a message's frames so far
	nav_events:   int, // Firefox: the driven page's documents loaded or failed (bidi_navigate)
	profile:      string, // the temporary user data folder
	product:      string, // "HeadlessChrome/156.0..." (Browser.getVersion)
	headless:     bool,
	next_id:      int,
	inbox:        [dynamic]byte, // read from Chrome, not yet a whole message
	pages:        [dynamic]Web_Page, // the tab, then pop-ups it opened (the last one is driven)
	listener:     net.TCP_Socket,
	port:         int,
	thread:       ^thread.Thread,
	quit:         bool,
	dead:         string, // why Chrome is gone ("" while it runs)
	// The driven page's state, from its events.
	navigating:   bool, // its main frame started loading a document that is not loaded yet
	documents:    int, // documents its main frame loaded (DOMContentLoaded)
	globals:      string, // launch arguments' script (agent.js's globals), "" for none
	globals_id:   string, // its addScriptToEvaluateOnNewDocument identifier
	dark:         Maybe(bool), // the color scheme set (setDarkMode), for new pages too
	geo:          Maybe([2]f64), // the location set, for new pages too
	recording:    bool,
	frames:       [dynamic]Web_Frame, // screencast frames while recording
	record_start: time.Tick,
	alloc:        mem.Allocator, // the agent thread's long-lived allocations
}

Web_Frame :: struct {
	at_ms: u32,
	jpeg:  []byte,
}

@(private = "file")
web: ^Web // this process's browser (one device per process)

// ---- Chrome ------------------------------------------------------------------------------

// Starts Chrome and the agent thread serving it on a port of its own (d.port).
web_start :: proc(d: ^Device) -> string {
	if web != nil do return ""
	web_debug = os.get_env("SPEEDRUN_WEB_DEBUG", context.temp_allocator) != ""
	exe, err: string
	if web_firefox do exe, err = firefox_executable()
	else do exe, err = web_chrome(web_headless)
	if err != "" do return err
	w: ^Web
	// Chrome whose sandbox cannot run here exits at once: Ubuntu 23.10 and later keep it from
	// the user namespaces it needs (GitHub's ubuntu-24.04 runners among them). Then it is
	// started again without it, as Playwright starts Chrome by default, and the run says so.
	for no_sandbox in ([]bool{false, true}) {
		w = new(Web, runtime.heap_allocator())
		w.alloc = runtime.heap_allocator()
		w.headless = web_headless
		w.firefox = web_firefox
		w.no_sandbox = no_sandbox
		w.inbox.allocator = w.alloc
		w.pages.allocator = w.alloc
		w.frames.allocator = w.alloc
		w.ws_raw.allocator = w.alloc
		w.ws_message.allocator = w.alloc
		if e := firefox_spawn(w, exe) if w.firefox else web_spawn(w, exe); e != "" {
			web = w
			web_stop()
			return e
		}
		web = w
		e := bidi_open(w) if w.firefox else web_open(w)
		if e == "" do break
		sandbox := !w.firefox && !no_sandbox && web_sandbox_failed(w)
		web_stop()
		if !sandbox do return e
		fmt.eprintln("Chrome's sandbox cannot run on this machine (on Ubuntu 23.10 and later: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 allows it): running Chrome without it.")
	}
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		web_stop()
		return fmt.tprintf("could not listen on 127.0.0.1: %v", lerr)
	}
	bound, _ := net.bound_endpoint(listener)
	w.listener, w.port = listener, bound.port
	d.port = bound.port
	_ = new_agent_token(bound.port)
	w.thread = thread.create_and_start_with_poly_data(w, web_serve)
	size := web_size if web_size != {} else WEB_DEFAULT_SIZE
	d.udid = WEB_FIREFOX if w.firefox else WEB_DEVICE
	d.name = strings.clone(fmt.tprintf("%s%s", strings.trim_prefix(w.product, "Headless"), fmt.tprintf(", headless %dx%d", size[0], size[1]) if w.headless else ""))
	return ""
}

// Chrome's log tells its start failed for want of its sandbox ("No usable sandbox!", the
// namespace or setuid helper errors).
@(private = "file")
web_sandbox_failed :: proc(w: ^Web) -> bool {
	data, _ := os.read_entire_file(fmt.tprintf("%s/speedrun-chrome.log", w.profile), context.temp_allocator)
	return strings.contains(strings.to_lower(string(data), context.temp_allocator), "sandbox")
}

// Stops Chrome (and with it the agent thread) and deletes its profile. Safe to call twice, and
// from the Ctrl-C handler.
web_stop :: proc() {
	w := web
	if w == nil do return
	web = nil
	w.quit = true
	if w.firefox && w.to > 0 {
		posix.close(w.to)
		w.to, w.from = 0, 0
	}
	if w.pid > 0 {
		// Firefox: its process group, its content processes too (it was started in a session of
		// its own, so the group is its pid).
		group := -w.pid if w.firefox else w.pid
		posix.kill(group, .SIGTERM)
		status: c.int
		for _ in 0 ..< 50 {
			if posix.waitpid(w.pid, &status, {.NOHANG}) != 0 do break
			time.sleep(20 * time.Millisecond)
		}
		posix.kill(group, .SIGKILL)
		posix.waitpid(w.pid, &status, {.NOHANG})
		w.pid = 0
	}
	if w.listener != 0 do net.close(w.listener)
	if w.profile != "" do os.remove_all(w.profile)
}

// The flags Playwright starts Chrome with (its chromiumSwitches), minus its own, and Maestro's
// --lang=en. Smooth scrolling off: a scroll lands at once, not over a few frames.
@(private = "file")
WEB_FLAGS :: []string {
	"--disable-field-trial-config", "--disable-background-networking", "--disable-background-timer-throttling",
	"--disable-backgrounding-occluded-windows", "--disable-back-forward-cache", "--disable-breakpad",
	"--disable-client-side-phishing-detection", "--disable-component-extensions-with-background-pages",
	"--disable-component-update", "--no-default-browser-check", "--disable-default-apps", "--disable-dev-shm-usage",
	"--disable-extensions",
	"--disable-features=AvoidUnnecessaryBeforeUnloadCheckSync,DestroyProfileOnBrowserClose,DialMediaRouteProvider,GlobalMediaControls,HttpsUpgrades,LensOverlay,MediaRouter,PaintHolding,ThirdPartyStoragePartitioning,Translate,AutoDeElevate,OptimizationHints,NetworkTimeServiceQuerying,AimEnabled",
	"--allow-pre-commit-input", "--disable-hang-monitor", "--disable-ipc-flooding-protection", "--disable-popup-blocking",
	"--disable-prompt-on-repost", "--disable-renderer-backgrounding", "--force-color-profile=srgb", "--metrics-recording-only",
	"--no-first-run", "--password-store=basic", "--use-mock-keychain", "--no-service-autorun", "--disable-search-engine-choice-screen",
	"--disable-infobars", "--disable-sync", "--disable-smooth-scrolling", "--lang=en", "--mute-audio",
}

@(private = "file")
web_spawn :: proc(w: ^Web, exe: string) -> string {
	web_sweep_profiles()
	profile, perr := os.make_directory_temp("", fmt.tprintf("speedrun-chrome-%d-*", os.get_pid()), w.alloc)
	if perr != nil do return fmt.tprintf("could not create a profile folder: %v", perr)
	w.profile = profile
	size := web_size if web_size != {} else WEB_DEFAULT_SIZE
	args := make([dynamic]string, context.temp_allocator)
	append(&args, exe)
	append(&args, ..WEB_FLAGS)
	if w.headless do append(&args, "--headless", "--hide-scrollbars")
	// Only after a start that failed for want of it (web_start): Chrome's sandbox is kept.
	if w.no_sandbox do append(&args, "--no-sandbox")
	if w.headless || web_size != {} do append(&args, fmt.tprintf("--window-size=%d,%d", size[0], size[1]))
	append(&args, fmt.tprintf("--user-data-dir=%s", profile), "--remote-debugging-pipe", "--no-startup-window")
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args do argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	cexe := argv[0]

	to, from: [2]posix.FD
	if posix.pipe(&to) != .OK || posix.pipe(&from) != .OK do return "could not create a pipe for Chrome"
	// The ends Chrome keeps go to its fds 3 and 4: moved above them first, so that dup2 cannot
	// overwrite one with the other. The ends kept here are closed on exec.
	high :: proc(fd: posix.FD) -> posix.FD {
		h := posix.FD(posix.fcntl(fd, .DUPFD_CLOEXEC, c.int(10)))
		posix.close(fd)
		return h
	}
	child_in, child_out := high(to[0]), high(from[1])
	w.to, w.from = high(to[1]), high(from[0])
	null := posix.open("/dev/null", {.RDWR})
	// Its output goes to a file in the profile, quoted when it fails to start.
	clog := strings.clone_to_cstring(fmt.tprintf("%s/speedrun-chrome.log", profile), context.temp_allocator)
	log_fd := posix.open(clog, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if log_fd < 0 do log_fd = null
	pid := posix.fork()
	if pid == 0 {
		// Only async-signal-safe calls until exec.
		posix.dup2(null, 0)
		posix.dup2(log_fd, 1)
		posix.dup2(log_fd, 2)
		posix.dup2(child_in, 3)
		posix.dup2(child_out, 4)
		posix.setsid() // its own session: a Ctrl-C at the terminal reaches this process, which stops it
		posix.execv(cexe, raw_data(argv))
		posix._exit(127)
	}
	posix.close(child_in)
	posix.close(child_out)
	if log_fd != null do posix.close(log_fd)
	posix.close(null)
	if pid < 0 do return "could not start Chrome (fork failed)"
	w.pid = pid
	return ""
}

// Profiles left by runs that were killed (`speedrun-chrome-<pid>-*`, `speedrun-firefox-<pid>-*`,
// the pid gone): Chrome exits when the pipe closes, the folder stays.
@(private)
web_sweep_profiles :: proc() {
	tmp, _ := os.temp_directory(context.temp_allocator)
	entries, err := os.read_all_directory_by_path(tmp, context.temp_allocator)
	if err != nil do return
	for e in entries {
		rest := strings.trim_prefix(e.name, "speedrun-chrome-")
		if rest == e.name do rest = strings.trim_prefix(e.name, "speedrun-firefox-")
		if rest == e.name do continue
		pid_s, _, _ := strings.partition(rest, "-")
		pid, ok := strconv.parse_int(pid_s)
		if !ok || pid <= 0 do continue
		if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK || posix.errno() == .EPERM do continue
		os.remove_all(e.fullpath)
	}
}

// The first page, ready: Chrome answers, every new page is attached before it runs (so the
// agent script is in it first), then a tab is opened.
@(private = "file")
web_open :: proc(w: ^Web) -> string {
	version, err := web_call(w, "Browser.getVersion", "{}", "", WEB_START_TIMEOUT)
	if err != "" {
		data, _ := os.read_entire_file(fmt.tprintf("%s/speedrun-chrome.log", w.profile), context.temp_allocator)
		lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
		return fmt.tprintf("Chrome did not start: %s\n%s", err, strings.join(lines[max(len(lines) - 15, 0):], "\n", context.temp_allocator))
	}
	if v, ok := version["product"].(json.String); ok do w.product = strings.clone(v, w.alloc)
	if _, e := web_call(w, "Target.setAutoAttach", `{"autoAttach":true,"waitForDebuggerOnStart":true,"flatten":true}`); e != "" do return e
	if _, e := web_call(w, "Target.createTarget", `{"url":"about:blank"}`); e != "" do return e
	// Attached as it is created (web_event): wait for it.
	start := time.tick_now()
	for len(w.pages) == 0 {
		if time.tick_since(start) > WEB_START_TIMEOUT do return "Chrome opened no tab"
		if !web_pump(w, 100) do return fmt.tprintf("Chrome stopped: %s", w.dead)
	}
	// The blank tab's document predates the script.
	_, _ = web_eval(w, WEB_AGENT_JS, false)
	return ""
}

// A page attached (the first tab, a pop-up): the agent script in each of its documents, the
// settings flows changed, its events, then it runs. It becomes the driven page, as Maestro
// switches to a new window.
@(private = "file")
web_page_attached :: proc(w: ^Web, session, target: string) {
	s := strings.clone(session, w.alloc)
	web_send(w, "Page.enable", "{}", s)
	web_send(w, "Page.addScriptToEvaluateOnNewDocument", fmt.tprintf(`{{"source":%s}}`, jq(WEB_AGENT_JS)), s)
	if w.globals != "" do web_send(w, "Page.addScriptToEvaluateOnNewDocument", fmt.tprintf(`{{"source":%s}}`, jq(w.globals)), s)
	// Screenshots in the page's own units, as the hierarchy's bounds (a Retina display's
	// window draws at 2x).
	if !w.headless do web_send(w, "Emulation.setDeviceMetricsOverride", `{"width":0,"height":0,"deviceScaleFactor":1,"mobile":false}`, s)
	if media := web_media(w); media != "" do web_send(w, "Emulation.setEmulatedMedia", media, s)
	// --animations: the page's animations (CSS, Web Animations) sped up, its timers not.
	#partial switch animations_for(.Web) {
	case .Fast: web_send(w, "Animation.setPlaybackRate", `{"playbackRate":10}`, s)
	case .Off:  web_send(w, "Animation.setPlaybackRate", `{"playbackRate":100}`, s)
	}
	if geo, set := w.geo.?; set do web_send(w, "Emulation.setGeolocationOverride", fmt.tprintf(`{{"latitude":%f,"longitude":%f,"accuracy":1}}`, geo[0], geo[1]), s)
	web_send(w, "Runtime.runIfWaitingForDebugger", "{}", s)
	append(&w.pages, Web_Page{s, strings.clone(target, w.alloc)})
	w.navigating = false
}

// The media features a page is told (one call sets them all): the color scheme a flow set,
// and reduced motion with --animations off. Empty: none.
@(private)
web_media :: proc(w: ^Web) -> string {
	features := make([dynamic]string, context.temp_allocator)
	if dark, set := w.dark.?; set {
		append(&features, fmt.tprintf(`{{"name":"prefers-color-scheme","value":"%s"}}`, "dark" if dark else "light"))
	}
	if animations_for(.Web) == .Off do append(&features, `{"name":"prefers-reduced-motion","value":"reduce"}`)
	if len(features) == 0 do return ""
	return fmt.tprintf(`{{"features":[%s]}}`, strings.join(features[:], ",", context.temp_allocator))
}

// The driven page.
@(private)
web_page :: proc(w: ^Web) -> Web_Page {
	return w.pages[len(w.pages) - 1] if len(w.pages) > 0 else {}
}

// ---- DevTools transport ------------------------------------------------------------------

// A JSON string literal.
jq :: proc(s: string, alloc := context.temp_allocator) -> string {
	b := strings.builder_make(0, len(s) + 2, alloc)
	strings.write_byte(&b, '"')
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if ch < 0x20 {
				fmt.sbprintf(&b, `\u%04x`, ch)
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// Sends a request; its id.
@(private)
web_send :: proc(w: ^Web, method, params: string, session := "") -> int {
	w.next_id += 1
	msg: string
	if session != "" {
		msg = fmt.tprintf(`{{"id":%d,"method":"%s","params":%s,"sessionId":"%s"}}`, w.next_id, method, params, session)
	} else {
		msg = fmt.tprintf(`{{"id":%d,"method":"%s","params":%s}}`, w.next_id, method, params)
	}
	if web_debug do fmt.eprintf("web -> %s\n", msg[:min(len(msg), 300)])
	if w.firefox {
		ws_send(w, msg)
		return w.next_id
	}
	out := make([]byte, len(msg) + 1, context.temp_allocator) // each message ends with a NUL
	copy(out, msg)
	data := out
	for len(data) > 0 && w.dead == "" {
		n := posix.write(w.to, raw_data(data), c.size_t(len(data)))
		if n <= 0 {
			if posix.errno() == .EINTR do continue
			w.dead = "its pipe closed"
			break
		}
		data = data[n:]
	}
	return w.next_id
}

// Reads what Chrome sent, waiting up to timeout_ms for something (0: what is there already),
// and handles every whole message but answers (kept in the inbox for web_wait). False once
// Chrome is gone.
@(private)
web_pump :: proc(w: ^Web, timeout_ms: int) -> bool {
	if w.dead != "" do return false
	fds := [1]posix.pollfd{{fd = w.from, events = {.IN}}}
	n := posix.poll(&fds[0], 1, c.int(timeout_ms))
	if n < 0 && posix.errno() != .EINTR do return false
	if n > 0 {
		buf: [64 * 1024]byte
		got := posix.read(w.from, &buf[0], len(buf))
		if got <= 0 {
			if got < 0 && posix.errno() == .EINTR do return true
			w.dead = "it exited"
			return false
		}
		if w.firefox {
			append(&w.ws_raw, ..buf[:got])
			if !ws_decode(w) do return false
		} else {
			append(&w.inbox, ..buf[:got])
		}
	}
	return true
}

// The next whole message in the inbox, removed from it; ok false when there is none.
@(private)
web_next :: proc(w: ^Web) -> (msg: json.Object, ok: bool) {
	for {
		end := -1
		for b, i in w.inbox do if b == 0 {
			end = i
			break
		}
		if end < 0 do return nil, false
		v, err := json.parse(w.inbox[:end], allocator = context.temp_allocator)
		if web_debug do fmt.eprintf("web <- %s (%v)\n", string(w.inbox[:min(end, 300)]), err)
		remove_range(&w.inbox, 0, end + 1)
		if err != nil do continue
		if o, is := v.(json.Object); is do return o, true
	}
}

// Waits for the answer to request `id`, handling the events that come first. result: its
// "result"; err: its error's message, or why none came.
@(private)
web_wait :: proc(w: ^Web, id: int, timeout := WEB_CALL_TIMEOUT) -> (result: json.Object, err: string) {
	start := time.tick_now()
	for {
		for {
			msg, ok := web_next(w)
			if !ok do break
			if mid, has := msg["id"]; has {
				if int(json_num(mid)) != id do continue // a request no one waits for
				if e, failed := msg["error"].(json.Object); failed {
					m, _ := e["message"].(json.String)
					return nil, m if m != "" else "error"
				}
				// WebDriver BiDi's: "type": "error", the error's name and a message.
				if t, _ := msg["type"].(json.String); t == "error" {
					name, _ := msg["error"].(json.String)
					m, _ := msg["message"].(json.String)
					return nil, fmt.tprintf("%s: %s", name, m) if m != "" else name
				}
				r, _ := msg["result"].(json.Object)
				return r, ""
			}
			web_event(w, msg)
		}
		left := timeout - time.tick_since(start)
		if left <= 0 do return nil, fmt.tprintf("no answer from %s", web_browser_name(w))
		if !web_pump(w, int(min(left, 200 * time.Millisecond) / time.Millisecond)) do return nil, fmt.tprintf("%s stopped (%s)", web_browser_name(w), w.dead)
	}
}

@(private)
web_call :: proc(w: ^Web, method, params: string, session := "", timeout := WEB_CALL_TIMEOUT) -> (json.Object, string) {
	return web_wait(w, web_send(w, method, params, session), timeout)
}

// A request to the driven page.
@(private)
web_page_call :: proc(w: ^Web, method, params: string, timeout := WEB_CALL_TIMEOUT) -> (json.Object, string) {
	return web_call(w, method, params, web_page(w).session, timeout)
}

json_num :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float:   return n
	}
	return 0
}

// Evaluates JavaScript in the driven page (its main world), the value returned as JSON; with
// `await`, a promise's value. err: the exception's description, or the call's error.
@(private)
web_eval :: proc(w: ^Web, expr: string, await: bool, timeout := WEB_CALL_TIMEOUT) -> (value: json.Value, err: string) {
	if w.firefox do return bidi_eval(w, expr, await, timeout)
	params := fmt.tprintf(`{{"expression":%s,"returnByValue":true,"awaitPromise":%v}}`, jq(expr), await)
	r, e := web_page_call(w, "Runtime.evaluate", params, timeout)
	if e != "" do return nil, e
	if ex, threw := r["exceptionDetails"].(json.Object); threw {
		if exc, has := ex["exception"].(json.Object); has {
			if d, ok := exc["description"].(json.String); ok do return nil, d
		}
		t, _ := ex["text"].(json.String)
		return nil, t if t != "" else "exception"
	}
	res, _ := r["result"].(json.Object)
	return res["value"], ""
}

// An evaluation that failed because the page's document went (a navigation): it is run again
// in the next one.
@(private)
web_gone :: proc(err: string) -> bool {
	return strings.contains(err, "context was destroyed") || strings.contains(err, "navigated or closed") ||
		strings.contains(err, "Cannot find context") || strings.contains(err, "__speedrun is not defined") ||
		strings.contains(err, "Cannot read properties of undefined") || strings.contains(err, "Promise was collected") ||
		// Firefox's
		strings.contains(err, "no such frame") || strings.contains(err, "__speedrun is undefined") ||
		strings.contains(err, "can't access property") || strings.contains(err, "DiscardedBrowsingContext") ||
		strings.contains(err, "AbortError")
}

@(private)
web_event :: proc(w: ^Web, msg: json.Object) {
	if w.firefox {
		bidi_event(w, msg)
		return
	}
	method, _ := msg["method"].(json.String)
	params, _ := msg["params"].(json.Object)
	session, _ := msg["sessionId"].(json.String)
	page := web_page(w)
	switch method {
	case "Target.attachedToTarget":
		s, _ := params["sessionId"].(json.String)
		info, _ := params["targetInfo"].(json.Object)
		kind, _ := info["type"].(json.String)
		target, _ := info["targetId"].(json.String)
		if kind == "page" {
			web_page_attached(w, s, target)
		} else {
			web_send(w, "Runtime.runIfWaitingForDebugger", "{}", s)
		}
	case "Target.detachedFromTarget":
		s, _ := params["sessionId"].(json.String)
		for p, i in w.pages do if p.session == s {
			ordered_remove(&w.pages, i)
			break
		}
	case "Page.javascriptDialogOpening":
		// Accepted, as a user would: flows have no command for browser dialogs.
		web_send(w, "Page.handleJavaScriptDialog", `{"accept":true}`, session)
	case "Page.frameStartedLoading":
		if session == page.session {
			if f, _ := params["frameId"].(json.String); f == page.target do w.navigating = true
		}
	case "Page.domContentEventFired":
		if session == page.session {
			w.navigating = false
			w.documents += 1
		}
	case "Page.frameStoppedLoading":
		if session == page.session {
			if f, _ := params["frameId"].(json.String); f == page.target do w.navigating = false
		}
	case "Page.screencastFrame":
		data, _ := params["data"].(json.String)
		sid := json_num(params["sessionId"])
		web_send(w, "Page.screencastFrameAck", fmt.tprintf(`{{"sessionId":%d}}`, int(sid)), session)
		if w.recording {
			jpeg, derr := base64.decode(data, allocator = w.alloc)
			if derr == nil do append(&w.frames, Web_Frame{u32(time.tick_since(w.record_start) / time.Millisecond), jpeg})
		}
	case "Inspector.targetCrashed":
		if session == page.session do w.navigating = false
	}
}

// Waits until the driven page's main frame has a document loaded (DOMContentLoaded) and the
// agent script answers. False after timeout.
@(private)
web_document_ready :: proc(w: ^Web, timeout: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if !w.navigating {
			v, err := web_eval(w, "document.readyState !== 'loading' && !!" + WEB_AGENT, false, timeout)
			if err == "" {
				if ready, _ := v.(json.Boolean); ready do return true
			}
		}
		if !web_pump(w, 20) do return false
		for {
			msg, ok := web_next(w)
			if !ok do break
			if _, answer := msg["id"]; !answer do web_event(w, msg)
		}
	}
	return false
}

// ---- the agent thread --------------------------------------------------------------------

// Serves one client at a time on w.listener, Chrome's events handled between requests.
@(private = "file")
web_serve :: proc(w: ^Web) {
	context.allocator = runtime.heap_allocator()
	for !w.quit {
		fds := [2]posix.pollfd{{fd = posix.FD(w.listener), events = {.IN}}, {fd = w.from, events = {.IN}}}
		if posix.poll(&fds[0], 2, 1000) < 0 && posix.errno() != .EINTR do return
		if .IN in fds[1].revents || .HUP in fds[1].revents {
			if !web_idle(w) do return
		}
		if .IN not_in fds[0].revents do continue
		client, _, aerr := net.accept_tcp(w.listener)
		if aerr != nil do continue
		_ = net.set_option(client, .TCP_Nodelay, true)
		token: [AGENT_TOKEN_LENGTH]byte
		if !recv_all(client, token[:]) || string(token[:]) != agent_tokens[w.port] {
			net.close(client)
			continue
		}
		web_client(w, client)
		net.close(client)
		free_all(context.temp_allocator)
	}
}

// Chrome's events while no request runs (a dialog opening, a pop-up).
@(private = "file")
web_idle :: proc(w: ^Web) -> bool {
	if !web_pump(w, 0) do return false
	for {
		msg, ok := web_next(w)
		if !ok do break
		if _, answer := msg["id"]; !answer do web_event(w, msg)
	}
	free_all(context.temp_allocator)
	return true
}

@(private = "file")
web_client :: proc(w: ^Web, client: net.TCP_Socket) {
	for !w.quit {
		fds := [2]posix.pollfd{{fd = posix.FD(client), events = {.IN}}, {fd = w.from, events = {.IN}}}
		if posix.poll(&fds[0], 2, 1000) < 0 && posix.errno() != .EINTR do return
		if .IN in fds[1].revents || .HUP in fds[1].revents {
			if !web_idle(w) && .IN not_in fds[0].revents do return
		}
		if .IN not_in fds[0].revents && .HUP not_in fds[0].revents do continue
		op: [1]byte
		if !recv_all(client, op[:]) do return
		t := time.tick_now()
		body := make([dynamic]byte, 0, 256, context.temp_allocator)
		quit := web_op(w, client, op[0], &body)
		if quit == .Lost do return
		out := make([]byte, 8 + len(body), context.temp_allocator)
		_ = endian.put_u32(out[0:4], .Big, u32(4 + len(body)))
		_ = endian.put_u32(out[4:8], .Big, u32(time.duration_microseconds(time.tick_since(t))))
		copy(out[8:], body[:])
		if !send_all(client, out) do return
		free_all(context.temp_allocator)
		if quit == .Quit {
			w.quit = true
			return
		}
	}
}

@(private = "file")
Op_End :: enum {
	Answer,
	Quit, // answered, then stop
	Lost, // the request could not be read
}

@(private = "file")
rd_req_i32 :: proc(client: net.TCP_Socket, ok: ^bool) -> i32 {
	b: [4]byte
	if !ok^ || !recv_all(client, b[:]) {
		ok^ = false
		return 0
	}
	v, _ := endian.get_u32(b[:], .Big)
	return i32(v)
}

@(private = "file")
rd_req_str :: proc(client: net.TCP_Socket, ok: ^bool) -> string {
	b: [2]byte
	if !ok^ || !recv_all(client, b[:]) {
		ok^ = false
		return ""
	}
	n, _ := endian.get_u16(b[:], .Big)
	s := make([]byte, int(n), context.temp_allocator)
	if n > 0 && !recv_all(client, s) do ok^ = false
	return string(s)
}

@(private)
wr_u8 :: proc(b: ^[dynamic]byte, v: u8) {append(b, v)}

@(private)
wr_u16 :: proc(b: ^[dynamic]byte, v: u16) {append(b, u8(v >> 8), u8(v))}

@(private)
wr_u32 :: proc(b: ^[dynamic]byte, v: u32) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

@(private)
wr_str :: proc(b: ^[dynamic]byte, s: string) {
	n := min(len(s), 0xFFFF)
	// Not cut inside a character.
	for n < len(s) && n > 0 && !utf8.rune_start(s[n]) do n -= 1
	wr_u16(b, u16(n))
	append(b, ..transmute([]byte)s[:n])
}

@(private = "file")
wr_action :: proc(b: ^[dynamic]byte, inject_us: u32, sent: bool) {
	wr_u32(b, 0)
	wr_u32(b, inject_us)
	wr_u8(b, u8(Inject_Path.DevTools) if sent else u8(Inject_Path.None))
}

// Handles one request; its answer's body goes in `b`.
@(private = "file")
web_op :: proc(w: ^Web, client: net.TCP_Socket, op: u8, b: ^[dynamic]byte) -> Op_End {
	ok := true
	switch op {
	case u8(Op.Ping):
	case u8(Op.Mark):
		web_mark(w)
	case u8(Op.Quit):
		return .Quit
	case u8(Op.Info):
		wr_str(b, WEB_FIREFOX if w.firefox else WEB_DEVICE)
		wr_str(b, w.product)
		wr_str(b, "")
	case u8(Op.Screen), u8(Op.Tree):
		web_read_nodes(w, b, op == u8(Op.Screen))
	case u8(Op.Find):
		_ = rd_req_str(client, &ok)
		wr_u32(b, 0)
	case u8(Op.Tap):
		x, y := rd_req_i32(client, &ok), rd_req_i32(client, &ok)
		if !ok do return .Lost
		t := time.tick_now()
		web_mark(w)
		web_click(w, x, y, 1, 0)
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), true)
	case u8(Op.Press):
		x, y, hold := rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok)
		if !ok do return .Lost
		t := time.tick_now()
		web_mark(w)
		web_click(w, x, y, 1, hold)
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), true)
	case u8(Op.Taps):
		x, y, count, interval := rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok)
		if !ok do return .Lost
		t := time.tick_now()
		web_mark(w)
		web_click(w, x, y, int(max(count, 1)), 0, interval)
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), true)
	case u8(Op.Key):
		code := rd_req_i32(client, &ok)
		if !ok do return .Lost
		t := time.tick_now()
		web_mark(w)
		sent := web_key(w, code)
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), sent)
	case u8(Op.Type):
		text := rd_req_str(client, &ok)
		if !ok do return .Lost
		t := time.tick_now()
		web_mark(w)
		web_type(w, text)
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), text != "")
		wr_u32(b, 0)
		wr_u8(b, 1) // focused: not checked on the web
	case u8(Op.Erase):
		count := rd_req_i32(client, &ok)
		if !ok do return .Lost
		t := time.tick_now()
		web_mark(w)
		sent := web_erase(w, int(count))
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), sent)
	case u8(Op.Swipe):
		x1, y1, x2, y2, duration, flags := rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok)
		if !ok do return .Lost
		_, _ = duration, flags
		t := time.tick_now()
		web_mark(w)
		web_scroll(w, x1, y1, x2 - x1, y2 - y1)
		wr_action(b, u32(time.duration_microseconds(time.tick_since(t))), true)
	case u8(Op.Settle):
		quiet, no_change, timeout := rd_req_i32(client, &ok), rd_req_i32(client, &ok), rd_req_i32(client, &ok)
		if !ok do return .Lost
		web_settle(w, quiet, no_change, timeout, b)
	case u8(Op.Screenshot):
		png := web_screenshot(w)
		wr_u32(b, u32(len(png)))
		append(b, ..png)
	case u8(Op.Hit):
		x, y := rd_req_i32(client, &ok), rd_req_i32(client, &ok)
		if !ok do return .Lost
		web_hit(w, x, y, b)
	case u8(Op.Launched):
		_ = rd_req_str(client, &ok)
		timeout := rd_req_i32(client, &ok)
		if !ok do return .Lost
		wr_u8(b, 1 if web_document_ready(w, time.Duration(timeout) * time.Millisecond) else 0)
	case u8(Op.Appearance):
		set := rd_req_i32(client, &ok)
		if !ok do return .Lost
		if set == 1 || set == 2 {
			w.dark = set == 2
			if w.firefox do bidi_appearance(w)
			else do for p in w.pages do web_call(w, "Emulation.setEmulatedMedia", web_media(w), p.session)
		}
		v, _ := web_eval(w, "matchMedia('(prefers-color-scheme: dark)').matches", false)
		dark, _ := v.(json.Boolean)
		wr_u8(b, 2 if dark else 1)
	case u8(Op.Orientation):
		_ = rd_req_i32(client, &ok) // a browser window does not turn (Maestro: a no-op)
	case u8(Op.Shell), u8(Op.Label):
		_ = rd_req_str(client, &ok)
		if op == u8(Op.Shell) do wr_u32(b, 0)
		else do wr_str(b, "")
	case u8(Op.Perms):
		_ = rd_req_str(client, &ok)
		wr_u8(b, 0)
	case u8(Op.Location):
		_ = rd_req_str(client, &ok)
		wr_u8(b, 0)
	case WEB_OP_NAVIGATE:
		url := rd_req_str(client, &ok)
		if !ok do return .Lost
		err := web_navigate(w, url)
		wr_u8(b, 1 if err == "" else 0)
		wr_str(b, err)
	case WEB_OP_CLEAR:
		url := rd_req_str(client, &ok)
		if !ok do return .Lost
		wr_u8(b, 1 if web_clear(w, url) else 0)
	case WEB_OP_CSS:
		sel := rd_req_str(client, &ok)
		if !ok do return .Lost
		v, err := web_eval(w, fmt.tprintf("%s.css(%s)", WEB_AGENT, jq(sel)), false)
		if err != "" {
			wr_u8(b, 0)
			_, _, msg := strings.partition(err, ": ")
			wr_str(b, msg if msg != "" else err)
		} else {
			list, _ := v.(json.Array)
			wr_u8(b, 1)
			wr_u32(b, u32(len(list)))
			for i in list do wr_u32(b, u32(json_num(i)))
		}
	case WEB_OP_GLOBALS:
		pairs := rd_req_str(client, &ok)
		if !ok do return .Lost
		web_globals(w, pairs)
	case WEB_OP_GEO:
		s := rd_req_str(client, &ok)
		if !ok do return .Lost
		lat_s, _, lon_s := strings.partition(s, " ")
		lat, _ := strconv.parse_f64(lat_s)
		lon, _ := strconv.parse_f64(lon_s)
		w.geo = [2]f64{lat, lon}
		if w.firefox {
			for p in w.pages do bidi_geo(w, p.target)
		} else {
			web_call(w, "Browser.grantPermissions", `{"permissions":["geolocation"]}`)
			for p in w.pages do web_call(w, "Emulation.setGeolocationOverride", fmt.tprintf(`{{"latitude":%f,"longitude":%f,"accuracy":1}}`, lat, lon), p.session)
		}
	case WEB_OP_CHANGE:
		timeout := rd_req_i32(client, &ok)
		if !ok do return .Lost
		v, err := web_eval(w, fmt.tprintf("%s.waitChange(%d)", WEB_AGENT, timeout), true, time.Duration(timeout) * time.Millisecond + 5 * time.Second)
		changed, _ := v.(json.Boolean)
		wr_u8(b, 1 if changed || err != "" else 0)
	case WEB_OP_REVEAL:
		i := rd_req_i32(client, &ok)
		if !ok do return .Lost
		web_mark(w)
		v, _ := web_eval(w, fmt.tprintf("%s.reveal(%d)", WEB_AGENT, i), false)
		revealed, _ := v.(json.Boolean)
		wr_u8(b, 1 if revealed else 0)
	case WEB_OP_STEADY:
		i := rd_req_i32(client, &ok)
		timeout := rd_req_i32(client, &ok)
		if !ok do return .Lost
		v, _ := web_eval(w, fmt.tprintf("%s.steady(%d, %d)", WEB_AGENT, i, timeout), true, time.Duration(timeout) * time.Millisecond + 5 * time.Second)
		waited, _ := v.(json.Boolean)
		wr_u8(b, 1 if waited else 0)
	case WEB_OP_RECORD:
		on: [1]byte
		if !recv_all(client, on[:]) do return .Lost
		web_record(w, on[0] == 1, b)
	case:
		// Unknown: answered empty, as the device agents do.
	}
	if !ok do return .Lost
	return .Answer
}

// The next settle measures from now (each action marks before it acts, as the device agents).
@(private)
web_mark :: proc(w: ^Web) {
	_, _ = web_eval(w, WEB_AGENT + ".mark()", false)
}

// ---- reading the page --------------------------------------------------------------------

// The page as flows see it (agent.js's tree): `u32 count, nodes`, then with `unsettled` the
// byte telling whether it changed since the last settle ended.
@(private = "file")
web_read_nodes :: proc(w: ^Web, b: ^[dynamic]byte, unsettled: bool) {
	text := ""
	for attempt in 0 ..< 3 {
		v, err := web_eval(w, WEB_AGENT + ".tree()", false)
		if err == "" {
			text, _ = v.(json.String)
			break
		}
		// A document going or coming: read the next one.
		if !web_gone(err) || attempt == 2 do break
		web_document_ready(w, WEB_LOAD_TIMEOUT)
	}
	nodes := strings.split(text, "\x1e", context.temp_allocator)
	flag := ""
	if len(nodes) > 0 {
		flag = nodes[len(nodes) - 1]
		nodes = nodes[:len(nodes) - 1]
	}
	wr_u32(b, u32(len(nodes)))
	for n in nodes {
		f := strings.split(n, "\x1f", context.temp_allocator)
		if len(f) < 12 {
			// Keeps the count right: an empty node.
			wr_u16(b, 0)
			for _ in 0 ..< 4 do wr_u32(b, 0)
			wr_u8(b, 0)
			for _ in 0 ..< 6 do wr_str(b, "")
			continue
		}
		depth, _ := strconv.parse_int(f[0])
		wr_u16(b, u16(depth))
		for k in 1 ..= 4 {
			v, _ := strconv.parse_int(f[k])
			wr_u32(b, u32(i32(v)))
		}
		fl, _ := strconv.parse_int(f[5])
		wr_u8(b, u8(fl))
		for k in 6 ..= 11 do wr_str(b, f[k])
	}
	if unsettled do wr_u8(b, 1 if flag == "1" else 0)
}

@(private = "file")
web_hit :: proc(w: ^Web, x, y: i32, b: ^[dynamic]byte) {
	v, err := web_eval(w, fmt.tprintf("%s.hit(%d,%d)", WEB_AGENT, x, y), false)
	list, _ := v.(json.Array)
	if err != "" || len(list) < 5 {
		wr_u32(b, transmute(u32)i32(-1))
		for _ in 0 ..< 4 do wr_u32(b, 0)
		return
	}
	for k in 0 ..< 5 do wr_u32(b, transmute(u32)i32(json_num(list[k])))
}

@(private = "file")
web_screenshot :: proc(w: ^Web) -> []byte {
	r: json.Object
	err: string
	if w.firefox do r, err = web_call(w, "browsingContext.captureScreenshot", fmt.tprintf(`{{"context":%s}}`, jq(web_page(w).target)))
	else do r, err = web_page_call(w, "Page.captureScreenshot", `{"format":"png"}`)
	if err != "" do return nil
	data, _ := r["data"].(json.String)
	png, derr := base64.decode(data, allocator = context.temp_allocator)
	if derr != nil do return nil
	return png
}

// ---- input -------------------------------------------------------------------------------

// The viewport's size, in the page's units.
@(private)
web_viewport :: proc(w: ^Web) -> (vw, vh: i32) {
	v, _ := web_eval(w, "[innerWidth, innerHeight]", false)
	list, _ := v.(json.Array)
	if len(list) == 2 do return i32(json_num(list[0])), i32(json_num(list[1]))
	return 0, 0
}

// A point outside the viewport (an element partly on screen, its center off it) is brought in
// by scrolling the window, at once, as Maestro scrolls to it (smoothly, then 3 s); the point's
// place after that.
@(private)
web_reach :: proc(w: ^Web, x, y: i32) -> (i32, i32) {
	if x >= WEB_SYNTHETIC && y >= WEB_SYNTHETIC do return x, y
	vw, vh := web_viewport(w)
	if vw <= 0 || (x >= 0 && x < vw && y >= 0 && y < vh) do return x, y
	dx := x - vw / 2 if x < 0 || x >= vw else 0
	dy := y - vh / 2 if y < 0 || y >= vh else 0
	v, _ := web_eval(w, fmt.tprintf("(() => {{ const x = scrollX, y = scrollY; scrollBy(%d, %d); return [scrollX - x, scrollY - y] }})()", dx, dy), false)
	list, _ := v.(json.Array)
	if len(list) == 2 do return x - i32(json_num(list[0])), y - i32(json_num(list[1]))
	return x, y
}

// `count` clicks at x, y (a double click: clickCount 1 then 2, `interval` ms apart), each held
// `hold` ms. The pointer moves there first, as a user's (hover styles, mouseover).
@(private = "file")
web_click :: proc(w: ^Web, x, y: i32, count: int, hold: i32, interval: i32 = 0) {
	if x >= WEB_SYNTHETIC && y >= WEB_SYNTHETIC {
		_, _ = web_eval(w, fmt.tprintf("%s.tapOption(%d,%d)", WEB_AGENT, x, y), false)
		return
	}
	x, y := web_reach(w, x, y)
	if w.firefox {
		bidi_click(w, x, y, count, hold, interval)
		return
	}
	s := web_page(w).session
	web_send(w, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseMoved","x":%d,"y":%d}}`, x, y), s)
	last := 0
	for k in 1 ..= count {
		if k > 1 && interval > 0 {
			web_wait(w, last)
			time.sleep(time.Duration(interval) * time.Millisecond)
		}
		web_send(w, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mousePressed","x":%d,"y":%d,"button":"left","buttons":1,"clickCount":%d}}`, x, y, k), s)
		if hold > 0 {
			web_wait(w, w.next_id)
			time.sleep(time.Duration(hold) * time.Millisecond)
		}
		last = web_send(w, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseReleased","x":%d,"y":%d,"button":"left","buttons":0,"clickCount":%d}}`, x, y, k), s)
	}
	web_wait(w, last)
}

Web_Key :: struct {
	key, code: string,
	key_code:  int,
	text:      string,
}

// Android key codes (flow.odin's names) as the browser's keys.
@(private)
web_key_for :: proc(code: i32) -> (Web_Key, bool) {
	switch code {
	case 66:  return {"Enter", "Enter", 13, "\r"}, true
	case 67:  return {"Backspace", "Backspace", 8, ""}, true
	case 112: return {"Delete", "Delete", 46, ""}, true
	case 61:  return {"Tab", "Tab", 9, ""}, true
	case 111: return {"Escape", "Escape", 27, ""}, true
	case 62:  return {" ", "Space", 32, " "}, true
	case 19:  return {"ArrowUp", "ArrowUp", 38, ""}, true
	case 20:  return {"ArrowDown", "ArrowDown", 40, ""}, true
	case 21:  return {"ArrowLeft", "ArrowLeft", 37, ""}, true
	case 22:  return {"ArrowRight", "ArrowRight", 39, ""}, true
	case 122: return {"Home", "Home", 36, ""}, true
	case 123: return {"End", "End", 35, ""}, true
	case 92:  return {"PageUp", "PageUp", 33, ""}, true
	case 93:  return {"PageDown", "PageDown", 34, ""}, true
	}
	return {}, false
}

// Sends the key down and up; the id of the last request.
@(private = "file")
web_key_events :: proc(w: ^Web, k: Web_Key) -> int {
	if w.firefox do return bidi_keys(w, {bidi_key_value(k)})
	s := web_page(w).session
	down := fmt.tprintf(`{{"type":"%s","key":%s,"code":%s,"windowsVirtualKeyCode":%d,"nativeVirtualKeyCode":%d%s}}`,
		"keyDown" if k.text != "" else "rawKeyDown", jq(k.key), jq(k.code), k.key_code, k.key_code,
		fmt.tprintf(`,"text":%s,"unmodifiedText":%s`, jq(k.text), jq(k.text)) if k.text != "" else "")
	web_send(w, "Input.dispatchKeyEvent", down, s)
	return web_send(w, "Input.dispatchKeyEvent", fmt.tprintf(`{{"type":"keyUp","key":%s,"code":%s,"windowsVirtualKeyCode":%d,"nativeVirtualKeyCode":%d}}`, jq(k.key), jq(k.code), k.key_code, k.key_code), s)
}

// pressKey. Back goes back in the history; keys a browser has no use for (home, volume, power,
// lock) do nothing.
@(private = "file")
web_key :: proc(w: ^Web, code: i32) -> bool {
	if code == KEYCODE_BACK {
		_, _ = web_eval(w, "history.back()", false)
		return true
	}
	k, known := web_key_for(code)
	if !known do return false
	web_wait(w, web_key_events(w, k))
	return true
}

// inputText into the focused element, as typed: a key down and up per character (keydown,
// keypress, input, keyup, as a keyboard sends them), all sent at once; a character no key
// types (an emoji, a CJK one) inserted as text. Maestro types one key at a time, 20-100 ms
// apart.
@(private = "file")
web_type :: proc(w: ^Web, text: string) {
	if text == "" do return
	if w.firefox {
		bidi_type(w, text)
		return
	}
	s := web_page(w).session
	last := 0
	for r in text {
		switch {
		case r == '\n':
			last = web_key_events(w, {"Enter", "Enter", 13, "\r"})
		case r == '\t':
			last = web_key_events(w, {"Tab", "Tab", 9, ""})
		case r >= ' ' && r < 0x7f:
			ch := fmt.tprintf("%c", r)
			code := 0
			switch {
			case r >= 'a' && r <= 'z': code = int(r - 'a' + 'A')
			case r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == ' ': code = int(r)
			}
			last = web_key_events(w, {ch, "", code, ch})
		case:
			last = web_send(w, "Input.insertText", fmt.tprintf(`{{"text":%s}}`, jq(fmt.tprintf("%c", r))), s)
		}
	}
	web_wait(w, last)
}

// eraseText: Backspace `count` times, at most as many as the focused field holds; all of it
// selected and one Backspace when it holds no more. False: an empty field, nothing to erase.
@(private = "file")
web_erase :: proc(w: ^Web, count: int) -> bool {
	v, _ := web_eval(w, WEB_AGENT + ".fieldLength()", false)
	n := int(json_num(v))
	if n == 0 do return false
	if n > 0 && n <= count {
		all, _ := web_eval(w, WEB_AGENT + ".selectField()", false)
		if selected, _ := all.(json.Boolean); selected {
			web_wait(w, web_key_events(w, {"Backspace", "Backspace", 8, ""}))
			return true
		}
	}
	if n > 0 do n = min(n, count)
	else do n = count
	if w.firefox {
		keys := make([]string, n, context.temp_allocator)
		for &k in keys do k = bidi_key_value({"Backspace", "Backspace", 8, ""})
		web_wait(w, bidi_keys(w, keys))
		return true
	}
	last := 0
	for _ in 0 ..< n do last = web_key_events(w, {"Backspace", "Backspace", 8, ""})
	web_wait(w, last)
	return true
}

// A swipe: a mouse wheel at its start, scrolling what is under it as far as the finger moved
// (the content follows the finger: a swipe up scrolls down), then a frame, for the scroll to
// show in the next read.
@(private = "file")
web_scroll :: proc(w: ^Web, x, y, dx, dy: i32) {
	vw, vh := web_viewport(w)
	x, y := clamp(x, 0, max(vw - 1, 0)), clamp(y, 0, max(vh - 1, 0))
	if w.firefox {
		bidi_wheel(w, x, y, -dx, -dy)
	} else {
		s := web_page(w).session
		web_send(w, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseMoved","x":%d,"y":%d}}`, x, y), s)
		web_wait(w, web_send(w, "Input.dispatchMouseEvent", fmt.tprintf(`{{"type":"mouseWheel","x":%d,"y":%d,"deltaX":%d,"deltaY":%d}}`, x, y, -dx, -dy), s))
	}
	_, _ = web_eval(w, "new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))", true)
}

// ---- settling and navigating -------------------------------------------------------------

// SETTLE: in the page (agent.js's settle), followed into the next document when a navigation
// replaces the page meanwhile (that counts as a change).
@(private = "file")
web_settle :: proc(w: ^Web, quiet, no_change, timeout: i32, b: ^[dynamic]byte) {
	start := time.tick_now()
	status: u8 = u8(Settle_Status.Timeout)
	ui_done, frames: u32
	navigated := false
	for {
		elapsed := i32(time.tick_since(start) / time.Millisecond)
		if elapsed >= timeout do break
		if w.navigating {
			navigated = true
			if !web_document_ready(w, time.Duration(timeout - elapsed) * time.Millisecond) do break
			continue
		}
		left := timeout - elapsed
		v, err := web_eval(w, fmt.tprintf("%s.settle(%d,%d,%d,%v)", WEB_AGENT, quiet, no_change, left, navigated), true, time.Duration(left) * time.Millisecond + 5 * time.Second)
		if err != "" {
			if !web_gone(err) do break
			// The document went: the next one.
			navigated = true
			if !web_document_ready(w, time.Duration(max(timeout - i32(time.tick_since(start) / time.Millisecond), 0)) * time.Millisecond) do break
			continue
		}
		// A navigation that began while the old document sat still: settle on the new one.
		if w.navigating do continue
		parts := strings.split(v.(json.String) or_else "", ",", context.temp_allocator)
		if len(parts) == 5 {
			st, _ := strconv.parse_int(parts[0])
			ui, _ := strconv.parse_int(parts[1])
			fr, _ := strconv.parse_int(parts[3])
			status, ui_done, frames = u8(st), u32(ui) * 1000, u32(fr)
			if navigated && status == u8(Settle_Status.No_Change) do status = u8(Settle_Status.Settled)
			if web_debug do fmt.eprintfln("web settle %s (last waited for: %s)", v.(json.String) or_else "", parts[4] if parts[4] != "" else "changes")
		}
		break
	}
	wr_u8(b, status)
	wr_u32(b, ui_done)
	wr_u32(b, u32(time.duration_microseconds(time.tick_since(start))))
	wr_u8(b, u8(Settle_Method.Page))
	wr_u32(b, frames)
	wr_u32(b, 0)
	wr_u32(b, 0)
	wr_u32(b, 0)
	wr_u32(b, 0)
}

// Opens `url` in the driven page; returns once the browser has its response (the document
// then loads: Launched or a settle waits for it). "" or why it could not.
@(private = "file")
web_navigate :: proc(w: ^Web, url: string) -> string {
	web_mark(w)
	if w.firefox do return bidi_navigate(w, url)
	r, err := web_page_call(w, "Page.navigate", fmt.tprintf(`{{"url":%s}}`, jq(url)), WEB_LOAD_TIMEOUT)
	if err != "" do return err
	if e, failed := r["errorText"].(json.String); failed && e != "" do return fmt.tprintf("could not open %s: %s", url, e)
	if _, document := r["loaderId"].(json.String); document do w.navigating = true
	return ""
}

// clearState: the data the browser keeps for the url's origin (cookies, storage, caches,
// service workers), as Maestro's clearDataForOrigin. A url with no origin (file:) has none.
@(private = "file")
web_clear :: proc(w: ^Web, url: string) -> bool {
	scheme, sep, rest := strings.partition(url, "://")
	if sep == "" || scheme == "file" do return true
	host := rest
	if i := strings.index_any(rest, "/?#"); i >= 0 do host = rest[:i]
	if host == "" do return true
	origin := fmt.tprintf("%s://%s", scheme, host)
	if w.firefox do return bidi_clear(w, origin)
	// Through the page: Chrome answers this on the browser's own session with an internal error.
	_, err := web_page_call(w, "Storage.clearDataForOrigin", fmt.tprintf(`{{"origin":%s,"storageTypes":"all"}}`, jq(origin)))
	return err == ""
}

// launchApp's arguments, as globals of every document from now on (Maestro sets them before
// each script it runs): `key = value` as strings, on window.
@(private = "file")
web_globals :: proc(w: ^Web, pairs: string) {
	b := strings.builder_make(context.temp_allocator)
	for pair in strings.split(pairs, "\x1e", context.temp_allocator) {
		if pair == "" do continue
		k, _, v := strings.partition(pair, "\x1f")
		fmt.sbprintf(&b, "window[%s] = %s;\n", jq(k), jq(v))
	}
	src := strings.to_string(b)
	if w.firefox {
		bidi_globals(w, src)
		return
	}
	page := web_page(w)
	if w.globals_id != "" {
		web_call(w, "Page.removeScriptToEvaluateOnNewDocument", fmt.tprintf(`{{"identifier":%s}}`, jq(w.globals_id)), page.session)
		w.globals_id = ""
	}
	if w.globals != "" do delete(w.globals, w.alloc)
	w.globals = strings.clone(src, w.alloc)
	if src == "" do return
	r, err := web_call(w, "Page.addScriptToEvaluateOnNewDocument", fmt.tprintf(`{{"source":%s}}`, jq(src)), page.session)
	if err == "" {
		id, _ := r["identifier"].(json.String)
		w.globals_id = strings.clone(id, w.alloc)
	}
	_, _ = web_eval(w, src, false)
}

// startRecording / stopRecording: the page's frames as Chrome draws them (a screencast, JPEG),
// kept until stopped; then `u32 count`, each `u32 ms, u32 len, jpeg`.
@(private = "file")
web_record :: proc(w: ^Web, on: bool, b: ^[dynamic]byte) {
	if w.firefox {
		if !on do wr_u32(b, 0) // WebDriver BiDi has no screencast
		return
	}
	if on {
		for f in w.frames do delete(f.jpeg, w.alloc)
		clear(&w.frames)
		w.recording, w.record_start = true, time.tick_now()
		web_page_call(w, "Page.startScreencast", `{"format":"jpeg","quality":80,"everyNthFrame":1}`)
		return
	}
	web_page_call(w, "Page.stopScreencast", "{}")
	w.recording = false
	wr_u32(b, u32(len(w.frames)))
	for f in w.frames {
		wr_u32(b, f.at_ms)
		wr_u32(b, u32(len(f.jpeg)))
		append(b, ..f.jpeg)
		delete(f.jpeg, w.alloc)
	}
	clear(&w.frames)
}

// ---- finding Chrome ----------------------------------------------------------------------

// The Chrome to run: SPEEDRUN_CHROME, else (headless) the headless shell from the cache, else
// an installed Chrome (headless: as --headless), else one downloaded into the cache. A cached
// one is kept current (web_refresh); an installed one updates itself.
web_chrome :: proc(headless: bool) -> (path: string, err: string) {
	if p := os.get_env("SPEEDRUN_CHROME", context.temp_allocator); p != "" {
		if !os.exists(p) do return "", fmt.tprintf("SPEEDRUN_CHROME: %s does not exist", p)
		return p, ""
	}
	if headless {
		if p, version := web_cached("chrome-headless-shell"); p != "" do return web_refresh("chrome-headless-shell", p, version), ""
		return web_download("chrome-headless-shell")
	}
	if p := web_installed(); p != "" do return p, ""
	if p, version := web_cached("chrome"); p != "" do return web_refresh("chrome", p, version), ""
	return web_download("chrome")
}

// A cached browser kept current: once a day (browser_check_due), Chrome for Testing's current
// stable `kind` is asked for, and downloaded when it is newer than the cached one (a release
// carries the browser's security fixes); older copies but the one before are deleted
// (browser_prune). The cached one when the check is not due, fails or finds nothing newer.
@(private = "file")
web_refresh :: proc(kind, exe, version: string) -> string {
	if !browser_check_due(web_cache_dir(), kind) do return exe
	latest, url, err := cft_stable(kind)
	if err != "" || !version_newer(latest, version) do return exe
	fresh, ferr := web_fetch(kind, latest, url, version)
	if ferr != "" {
		fmt.eprintf("%s: running %s %s\n", ferr, kind, version)
		return exe
	}
	browser_prune(web_cache_dir(), kind)
	return fresh
}

// Whether to ask now for the browser `kind`'s current version: once a day, unless
// SPEEDRUN_NO_BROWSER_UPDATE is set. The check is marked as made (`<cache>/<kind>.checked`,
// its time) whatever its answer: offline, the cached browser runs, and tomorrow it asks again.
@(private)
browser_check_due :: proc(cache, kind: string) -> bool {
	if os.get_env("SPEEDRUN_NO_BROWSER_UPDATE", context.temp_allocator) != "" do return false
	stamp := fmt.tprintf("%s/%s.checked", cache, kind)
	if info, err := os.stat(stamp, context.temp_allocator); err == nil && time.since(info.modification_time) < 24 * time.Hour do return false
	_ = os.write_entire_file(stamp, []byte{})
	return true
}

// Deletes the downloads of `kind` in `cache` (folders `<kind>-<version>`) but the newest two:
// a run that started on the one before keeps its files.
@(private)
browser_prune :: proc(cache, kind: string) {
	entries, err := os.read_all_directory_by_path(cache, context.temp_allocator)
	if err != nil do return
	versions := make([dynamic]string, context.temp_allocator)
	for e in entries {
		version := strings.trim_prefix(e.name, fmt.tprintf("%s-", kind))
		if version == e.name || version == "" || version[0] < '0' || version[0] > '9' do continue
		append(&versions, version)
	}
	slice.sort_by(versions[:], proc(a, b: string) -> bool {return version_newer(a, b)})
	for v in versions[min(2, len(versions)):] do os.remove_all(fmt.tprintf("%s/%s-%s", cache, kind, v))
}

@(private = "file")
web_installed :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	when ODIN_OS == .Darwin {
		paths := []string {
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			fmt.tprintf("%s/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", home),
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
		}
		for p in paths do if os.exists(p) do return p
	} else {
		path := os.get_env("PATH", context.temp_allocator)
		for name in ([]string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser"}) {
			for dir in strings.split(path, ":", context.temp_allocator) {
				p := fmt.tprintf("%s/%s", dir, name)
				if dir != "" && os.exists(p) do return p
			}
		}
	}
	return ""
}

// Chrome for Testing's name for this machine.
@(private = "file")
web_platform :: proc() -> string {
	when ODIN_OS == .Darwin {
		return "mac-arm64" when ODIN_ARCH == .arm64 else "mac-x64"
	} else {
		return "linux64"
	}
}

@(private)
web_cache_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	when ODIN_OS == .Darwin {
		return fmt.tprintf("%s/Library/Caches/speedrun/chrome", home)
	} else {
		xdg := os.get_env("XDG_CACHE_HOME", context.temp_allocator)
		return fmt.tprintf("%s/speedrun/chrome", xdg if xdg != "" else fmt.tprintf("%s/.cache", home))
	}
}

// The executable inside an unpacked download of `kind` (chrome or chrome-headless-shell).
@(private = "file")
web_executable :: proc(dir, kind: string) -> string {
	plat := web_platform()
	if kind == "chrome-headless-shell" do return fmt.tprintf("%s/chrome-headless-shell-%s/chrome-headless-shell", dir, plat)
	when ODIN_OS == .Darwin {
		return fmt.tprintf("%s/chrome-%s/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", dir, plat)
	} else {
		return fmt.tprintf("%s/chrome-%s/chrome", dir, plat)
	}
}

// The newest download of `kind` in the cache and its version ("" for none): folders
// `<kind>-<version>`.
@(private = "file")
web_cached :: proc(kind: string) -> (exe, version: string) {
	entries, err := os.read_all_directory_by_path(web_cache_dir(), context.temp_allocator)
	if err != nil do return
	for e in entries {
		if !strings.has_prefix(e.name, kind) || len(e.name) <= len(kind) + 1 || e.name[len(kind)] != '-' do continue
		v := e.name[len(kind) + 1:]
		if v[0] < '0' || v[0] > '9' do continue
		x := web_executable(e.fullpath, kind)
		if !os.exists(x) do continue
		if exe == "" || version_newer(v, version) do exe, version = x, v
	}
	return
}

@(private)
version_newer :: proc(a, b: string) -> bool {
	pa, pb := strings.split(a, ".", context.temp_allocator), strings.split(b, ".", context.temp_allocator)
	for i in 0 ..< min(len(pa), len(pb)) {
		x, _ := strconv.parse_int(pa[i])
		y, _ := strconv.parse_int(pb[i])
		if x != y do return x > y
	}
	return len(pa) > len(pb)
}

// Downloads Chrome for Testing's current stable `kind` into the cache, with curl and unzip.
@(private = "file")
web_download :: proc(kind: string) -> (exe: string, err: string) {
	version, url, lerr := cft_stable(kind)
	if lerr != "" do return "", lerr
	return web_fetch(kind, version, url, "")
}

// Chrome for Testing's current stable version of `kind`, and its download for this machine.
@(private = "file")
cft_stable :: proc(kind: string) -> (version, url, err: string) {
	LIST :: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
	state, out, stderr, perr := os.process_exec({command = {"curl", "-fsSL", "--max-time", "60", LIST}}, context.temp_allocator)
	if perr != nil || !state.success {
		return "", "", fmt.tprintf("No Chrome on this machine, and the list of Chrome for Testing downloads could not be fetched (%s). Install Chrome, or set SPEEDRUN_CHROME to a Chrome or Chromium executable.", strings.trim_space(string(stderr)))
	}
	v, jerr := json.parse(out, allocator = context.temp_allocator)
	if jerr != nil do return "", "", "could not read the list of Chrome for Testing downloads"
	root, _ := v.(json.Object)
	channels, _ := root["channels"].(json.Object)
	stable, _ := channels["Stable"].(json.Object)
	version, _ = stable["version"].(json.String)
	downloads, _ := stable["downloads"].(json.Object)
	list, _ := downloads[kind].(json.Array)
	for item in list {
		o, _ := item.(json.Object)
		if p, _ := o["platform"].(json.String); p == web_platform() do url, _ = o["url"].(json.String)
	}
	if url == "" || version == "" do return "", "", fmt.tprintf("Chrome for Testing has no %s for %s", kind, web_platform())
	return version, url, ""
}

// Downloads `kind` `version` from `url` into the cache; `replacing`: the cached version it is
// newer than ("" for none).
@(private = "file")
web_fetch :: proc(kind, version, url, replacing: string) -> (exe: string, err: string) {
	cache := web_cache_dir()
	if e := os.make_directory_all(cache); e != nil && e != .Exist do return "", fmt.tprintf("could not create %s: %v", cache, e)
	if replacing != "" do fmt.eprintf("Downloading %s %s (Chrome for Testing, newer than the cached %s) into %s...\n", kind, version, replacing, cache)
	else do fmt.eprintf("Downloading %s %s (Chrome for Testing) into %s...\n", kind, version, cache)
	tmp, terr := os.make_directory_temp(cache, "download-*", context.temp_allocator)
	if terr != nil do return "", fmt.tprintf("could not create a folder in %s: %v", cache, terr)
	defer os.remove_all(tmp)
	zip := fmt.tprintf("%s/chrome.zip", tmp)
	state, _, stderr, perr := os.process_exec({command = {"curl", "-fL", "--max-time", "600", "-o", zip, url}}, context.temp_allocator)
	if perr != nil || !state.success do return "", fmt.tprintf("could not download %s: %s", url, strings.trim_space(string(stderr)))
	unpacked := fmt.tprintf("%s/unpacked", tmp)
	state, _, stderr, perr = os.process_exec({command = {"unzip", "-q", zip, "-d", unpacked}}, context.temp_allocator)
	if perr != nil || !state.success do return "", fmt.tprintf("could not unpack %s (unzip): %s", zip, strings.trim_space(string(stderr)))
	final := fmt.tprintf("%s/%s-%s", cache, kind, version)
	if e := os.rename(unpacked, final); e != nil && !os.exists(web_executable(final, kind)) {
		return "", fmt.tprintf("could not move Chrome to %s: %v", final, e)
	}
	exe = web_executable(final, kind)
	if !os.exists(exe) do return "", fmt.tprintf("the download has no %s", exe)
	return strings.clone(exe), ""
}

// ---- the host's side of the web operations ------------------------------------------------

op_web_navigate :: proc(c: ^Conn, url: string, alloc: mem.Allocator) -> (err: string, ok: bool) {
	body: []byte
	body, _, ok = call(c, str_request(Op(WEB_OP_NAVIGATE), url, context.temp_allocator))
	if !ok do return
	r := Reader{b = body, ok = true}
	opened := rd_u8(&r) == 1
	msg := rd_str(&r, alloc)
	if !opened && msg == "" do msg = fmt.aprintf("could not open %s", url, allocator = alloc)
	return msg, r.ok
}

op_web_clear :: proc(c: ^Conn, url: string) -> bool {
	_, _, ok := call(c, str_request(Op(WEB_OP_CLEAR), url, context.temp_allocator))
	return ok
}

// The indices in the last read of the elements `selector` matches; err: an invalid selector.
op_web_css :: proc(c: ^Conn, selector: string, alloc: mem.Allocator) -> (indices: []u32, err: string, ok: bool) {
	body: []byte
	body, _, ok = call(c, str_request(Op(WEB_OP_CSS), selector, context.temp_allocator))
	if !ok do return
	r := Reader{b = body, ok = true}
	if rd_u8(&r) != 1 do return nil, rd_str(&r, alloc), r.ok
	indices = make([]u32, int(rd_u32(&r)), alloc)
	for &i in indices do i = rd_u32(&r)
	return indices, "", r.ok
}

op_web_globals :: proc(c: ^Conn, args: []Launch_Arg) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for a in args do fmt.sbprintf(&b, "%s\x1f%s\x1e", a.key, a.value)
	_, _, ok := call(c, str_request(Op(WEB_OP_GLOBALS), strings.to_string(b), context.temp_allocator))
	return ok
}

// Waits up to timeout_ms for the page to change after the last read; changed: it did.
op_web_change :: proc(c: ^Conn, timeout_ms: i64) -> (changed, ok: bool) {
	req: [5]byte
	req[0] = WEB_OP_CHANGE
	put_i32(req[1:5], i32(clamp(timeout_ms, 0, 60_000)))
	body: []byte
	body, _, ok = call(c, req[:])
	return ok && len(body) > 0 && body[0] == 1, ok
}

// Scrolls node `index` of the last read into view; false when it is gone.
op_web_reveal :: proc(c: ^Conn, index: int) -> (revealed, ok: bool) {
	req: [5]byte
	req[0] = WEB_OP_REVEAL
	put_i32(req[1:5], i32(index))
	body: []byte
	body, _, ok = call(c, req[:])
	return ok && len(body) > 0 && body[0] == 1, ok
}

// Waits up to `timeout_ms` for node `index` of the last read and its containers to stop moving;
// true when it waited (the element is to be found again, where it rests).
op_web_steady :: proc(c: ^Conn, index: int, timeout_ms: i32) -> (waited, ok: bool) {
	req: [9]byte
	req[0] = WEB_OP_STEADY
	put_i32(req[1:5], i32(index))
	put_i32(req[5:9], timeout_ms)
	body: []byte
	body, _, ok = call(c, req[:])
	return ok && len(body) > 0 && body[0] == 1, ok
}

op_web_geo :: proc(c: ^Conn, latitude, longitude: f64) -> bool {
	_, _, ok := call(c, str_request(Op(WEB_OP_GEO), fmt.tprintf("%f %f", latitude, longitude), context.temp_allocator))
	return ok
}

// startRecording on web: the page's frames, kept by the agent until stopRecording.
web_start_recording :: proc(r: ^Runner, file: string) -> Err {
	if _, _, ok := call(r.c, []byte{WEB_OP_RECORD, 1}); !ok do return AGENT_LOST
	r.recording = {active = true, file = file}
	return nil
}

web_stop_recording :: proc(r: ^Runner) -> Err {
	body, _, ok := call(r.c, []byte{WEB_OP_RECORD, 0})
	if !ok do return AGENT_LOST
	_ = body
	return "startRecording is not supported on web yet"
}
