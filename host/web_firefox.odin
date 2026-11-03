// Firefox, the web device "firefox": driven over WebDriver BiDi, the W3C protocol Firefox
// speaks since it dropped Chrome's DevTools protocol, on a WebSocket to 127.0.0.1 (Firefox has
// no pipe). The same agent operations and the same page script (web/agent.js) as with Chrome
// (web.odin): this file holds what differs, the connection, the session's events, and the
// commands that have their own names here.
//
// Firefox: SPEEDRUN_FIREFOX when set; else (macOS) the Firefox installed in Applications; else
// the newest Firefox from Mozilla in the user's cache, downloaded on first use.
package speedrun

import "core:c"
import "core:crypto"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

WEB_FIREFOX :: "firefox" // the device that runs web flows in Firefox

// The web device is Firefox (--device firefox).
web_firefox: bool

web_browser_name :: proc(w: ^Web) -> string {
	return "Firefox" if w.firefox else "Chrome"
}

// Preferences for a test run, in the profile's user.js. Firefox's remote agent sets its own
// recommended ones too (no updates, no first-run pages, no background requests). No
// back-forward cache (as Chrome runs): a page it brings back sends no domContentLoaded. Pages
// see a light color scheme, as in Chrome, until a flow sets dark mode (bidi_appearance).
@(private = "file")
FIREFOX_PREFS :: `user_pref("app.update.disabledForTesting", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.startup.page", 0);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.warnOnQuit", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.translations.automaticallyPopup", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("toolkit.startup.max_resumed_crashes", -1);
user_pref("signon.rememberSignons", false);
user_pref("dom.disable_open_during_load", false);
user_pref("dom.max_script_run_time", 0);
user_pref("general.smoothScroll", false);
user_pref("intl.accept_languages", "en-US, en");
user_pref("geo.prompt.testing", true);
user_pref("geo.prompt.testing.allow", true);
user_pref("geo.provider.testing", true);
user_pref("network.captive-portal-service.enabled", false);
user_pref("browser.sessionhistory.max_total_viewers", 0);
user_pref("fission.bfcacheInParent", false);
user_pref("layout.css.prefers-color-scheme.content-override", 1);
`

// The events the driven pages' state follows (bidi_event).
@(private = "file")
BIDI_EVENTS :: `["browsingContext.contextCreated","browsingContext.contextDestroyed","browsingContext.navigationStarted","browsingContext.domContentLoaded","browsingContext.fragmentNavigated","browsingContext.navigationFailed","browsingContext.userPromptOpened"]`

// ---- starting Firefox --------------------------------------------------------------------

// Starts Firefox with a fresh profile, waits for its WebDriver BiDi port, and connects to it.
firefox_spawn :: proc(w: ^Web, exe: string) -> string {
	web_sweep_profiles()
	profile, perr := os.make_directory_temp("", fmt.tprintf("speedrun-firefox-%d-*", os.get_pid()), w.alloc)
	if perr != nil do return fmt.tprintf("could not create a profile folder: %v", perr)
	w.profile = profile
	prefs := strings.builder_make(context.temp_allocator)
	strings.write_string(&prefs, FIREFOX_PREFS)
	// A headed window on a Retina display draws at 2x: one page pixel per screen pixel, so
	// screenshots are in the page's units, as the hierarchy's bounds.
	if !w.headless do strings.write_string(&prefs, "user_pref(\"layout.css.devPixelsPerPx\", \"1.0\");\n")
	if animations_for(.Web) == .Off do strings.write_string(&prefs, "user_pref(\"ui.prefersReducedMotion\", 1);\n")
	if os.write_entire_file(fmt.tprintf("%s/user.js", profile), transmute([]byte)strings.to_string(prefs)) != nil {
		return fmt.tprintf("could not write %s/user.js", profile)
	}

	args := make([dynamic]string, context.temp_allocator)
	append(&args, exe, "-profile", profile, "-no-remote", "-new-instance", "-remote-debugging-port", "0")
	if w.headless do append(&args, "-headless")
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args do argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	environ, _ := os.environ(context.temp_allocator)
	envs := make([dynamic]cstring, 0, len(environ) + 3, context.temp_allocator)
	for e in environ do append(&envs, strings.clone_to_cstring(e, context.temp_allocator))
	// No crash reporter window, and no safe-mode question after a crash. System access: the
	// browser's own preferences and clear-data service, for setDarkMode and clearState
	// (bidi_appearance, bidi_clear); Firefox takes one session at a time, and Speedrun's starts
	// as soon as the port opens.
	append(&envs, "MOZ_CRASHREPORTER_DISABLE=1", "MOZ_DISABLE_AUTO_SAFE_MODE=1", "MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1", nil)
	cexe := argv[0]

	// Its output goes to a file in the profile: the port it listens on is printed there.
	log_path := fmt.tprintf("%s/speedrun-firefox.log", profile)
	clog := strings.clone_to_cstring(log_path, context.temp_allocator)
	log_fd := posix.open(clog, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if log_fd < 0 do return fmt.tprintf("could not create %s", log_path)
	null := posix.open("/dev/null", {.RDWR})
	pid := posix.fork()
	if pid == 0 {
		// Only async-signal-safe calls until exec.
		posix.dup2(null, 0)
		posix.dup2(log_fd, 1)
		posix.dup2(log_fd, 2)
		posix.setsid() // its own session and process group: stopped as a group (web_stop)
		posix.execve(cexe, raw_data(argv), raw_data(envs))
		posix._exit(127)
	}
	posix.close(log_fd)
	posix.close(null)
	if pid < 0 do return "could not start Firefox (fork failed)"
	w.pid = pid

	// "WebDriver BiDi listening on ws://127.0.0.1:<port>"
	MARK :: "WebDriver BiDi listening on ws://127.0.0.1:"
	start := time.tick_now()
	port := 0
	for port == 0 {
		data, _ := os.read_entire_file(log_path, context.temp_allocator)
		text := string(data)
		if i := strings.index(text, MARK); i >= 0 {
			rest := text[i + len(MARK):]
			end := 0
			for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' do end += 1
			port, _ = strconv.parse_int(rest[:end])
			if port > 0 do break
		}
		status: c.int
		if posix.waitpid(pid, &status, {.NOHANG}) == pid {
			w.pid = 0
			return fmt.tprintf("Firefox exited before it listened:\n%s", strings.trim_space(text))
		}
		if time.tick_since(start) > WEB_START_TIMEOUT do return fmt.tprintf("Firefox did not open its WebDriver BiDi port within %v:\n%s", WEB_START_TIMEOUT, strings.trim_space(text))
		time.sleep(20 * time.Millisecond)
	}
	return ws_connect(w, port)
}

// ---- the WebSocket ------------------------------------------------------------------------

// Opens the session's WebSocket (ws://127.0.0.1:<port>/session): the HTTP upgrade, then frames.
@(private = "file")
ws_connect :: proc(w: ^Web, port: int) -> string {
	sock, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, port})
	if err != nil do return fmt.tprintf("could not connect to Firefox on port %d: %v", port, err)
	_ = net.set_option(sock, .TCP_Nodelay, true)
	key: [16]byte
	crypto.rand_bytes(key[:])
	req := fmt.tprintf("GET /session HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
		port, base64.encode(key[:], allocator = context.temp_allocator))
	if !send_all(sock, transmute([]byte)req) {
		net.close(sock)
		return "could not send the WebSocket upgrade to Firefox"
	}
	fd := posix.FD(sock)
	head := make([dynamic]byte, context.temp_allocator)
	start := time.tick_now()
	for {
		if i := strings.index(string(head[:]), "\r\n\r\n"); i >= 0 {
			status_line, _, _ := strings.partition(string(head[:i]), "\r\n")
			if !strings.contains(status_line, " 101 ") {
				net.close(sock)
				return fmt.tprintf("Firefox refused the WebSocket: %s", status_line)
			}
			append(&w.ws_raw, ..head[i + 4:]) // frames that came with the answer
			break
		}
		if time.tick_since(start) > WEB_START_TIMEOUT {
			net.close(sock)
			return "Firefox did not answer the WebSocket upgrade"
		}
		fds := [1]posix.pollfd{{fd = fd, events = {.IN}}}
		if posix.poll(&fds[0], 1, 200) <= 0 do continue
		buf: [4096]byte
		got := posix.read(fd, &buf[0], len(buf))
		if got <= 0 {
			net.close(sock)
			return "Firefox closed the WebSocket"
		}
		append(&head, ..buf[:got])
	}
	w.to, w.from = fd, fd
	if !ws_decode(w) do return "Firefox closed the WebSocket"
	return ""
}

// A text message (`msg`, JSON) as one masked frame, as a client sends them.
ws_send :: proc(w: ^Web, msg: string) {
	ws_frame(w, 0x1, transmute([]byte)msg)
}

@(private = "file")
ws_frame :: proc(w: ^Web, opcode: u8, payload: []byte) {
	n := len(payload)
	out := make([dynamic]byte, 0, n + 14, context.temp_allocator)
	append(&out, 0x80 | opcode)
	switch {
	case n < 126:
		append(&out, 0x80 | u8(n))
	case n < 65536:
		append(&out, 0x80 | 126, u8(n >> 8), u8(n))
	case:
		append(&out, 0x80 | 127)
		for shift := 56; shift >= 0; shift -= 8 do append(&out, u8(u64(n) >> uint(shift)))
	}
	mask: [4]byte
	crypto.rand_bytes(mask[:])
	append(&out, ..mask[:])
	start := len(out)
	append(&out, ..payload)
	for i in 0 ..< n do out[start + i] ~= mask[i & 3]
	data := out[:]
	for len(data) > 0 && w.dead == "" {
		written := posix.write(w.to, raw_data(data), c.size_t(len(data)))
		if written <= 0 {
			if posix.errno() == .EINTR do continue
			w.dead = "its WebSocket closed"
			break
		}
		data = data[written:]
	}
}

// Turns the whole frames read so far into messages in the inbox, each ended with a NUL as
// Chrome's pipe ends them (JSON never holds a raw NUL), so web_next reads either. Answers
// pings. False once Firefox closed the connection.
ws_decode :: proc(w: ^Web) -> bool {
	for {
		raw := w.ws_raw[:]
		if len(raw) < 2 do return true
		fin := raw[0] & 0x80 != 0
		opcode := raw[0] & 0x0F
		masked := raw[1] & 0x80 != 0
		n := u64(raw[1] & 0x7F)
		at := 2
		switch n {
		case 126:
			if len(raw) < 4 do return true
			n = u64(raw[2]) << 8 | u64(raw[3])
			at = 4
		case 127:
			if len(raw) < 10 do return true
			n = 0
			for k in 2 ..< 10 do n = n << 8 | u64(raw[k])
			at = 10
		}
		mask: [4]byte
		if masked {
			if len(raw) < at + 4 do return true
			copy(mask[:], raw[at:at + 4])
			at += 4
		}
		if u64(len(raw) - at) < n do return true
		payload := raw[at:at + int(n)]
		if masked do for i in 0 ..< len(payload) do payload[i] ~= mask[i & 3]
		switch opcode {
		case 0x0, 0x1: // a continuation, a text message
			append(&w.ws_message, ..payload)
			if fin {
				append(&w.inbox, ..w.ws_message[:])
				append(&w.inbox, 0)
				clear(&w.ws_message)
			}
		case 0x8:
			w.dead = "it closed its WebSocket"
			return false
		case 0x9:
			ws_frame(w, 0xA, payload) // pong
		}
		remove_range(&w.ws_raw, 0, at + int(n))
	}
}

// ---- the session -------------------------------------------------------------------------

// The session: started, its events subscribed to, the page script set up for every document
// to come, and a tab of Speedrun's own (bidi_fresh_tab).
bidi_open :: proc(w: ^Web) -> string {
	r, err := web_call(w, "session.new", `{"capabilities":{"alwaysMatch":{"unhandledPromptBehavior":{"default":"accept"}}}}`, "", WEB_START_TIMEOUT)
	if err != "" do return fmt.tprintf("Firefox did not start a session: %s", err)
	caps, _ := r["capabilities"].(json.Object)
	version, _ := caps["browserVersion"].(json.String)
	w.product = strings.clone(fmt.tprintf("Firefox/%s", version), w.alloc)
	if _, e := web_call(w, "session.subscribe", fmt.tprintf(`{{"events":%s}}`, BIDI_EVENTS)); e != "" do return e
	if rate := bidi_rate_script(); rate != "" {
		if _, e := web_call(w, "script.addPreloadScript", fmt.tprintf(`{{"functionDeclaration":%s}}`, jq(fmt.tprintf("() => {{ %s }}", rate)))); e != "" do return e
	}
	if _, e := web_call(w, "script.addPreloadScript", fmt.tprintf(`{{"functionDeclaration":%s}}`, jq(fmt.tprintf("() => {{\n%s\n}}", WEB_AGENT_JS)))); e != "" do return e
	if !bidi_fresh_tab(w) do return "Firefox opened no tab"
	return ""
}

// --animations on the web: Firefox has no playback rate of its own to set, so the page script
// speeds up each animation as it starts (agent.js's __speedrunAnimationRate). "" at 1x.
@(private = "file")
bidi_rate_script :: proc() -> string {
	#partial switch animations_for(.Web) {
	case .Fast: return "window.__speedrunAnimationRate = 10"
	case .Off:  return "window.__speedrunAnimationRate = 100"
	}
	return ""
}

// A tab's first document (about:blank) predates the preload scripts: they run in it by hand.
@(private = "file")
bidi_setup_blank :: proc(w: ^Web) {
	if rate := bidi_rate_script(); rate != "" do _, _ = web_eval(w, rate, false)
	if w.globals != "" do _, _ = web_eval(w, w.globals, false)
	_, _ = web_eval(w, WEB_AGENT_JS, false)
	w.navigating = false
}

// A top-level browsing context: a tab or a pop-up. It becomes the driven page, as Maestro
// switches to a new window, with the settings flows changed.
@(private = "file")
bidi_page_created :: proc(w: ^Web, ctx: string) {
	for p in w.pages do if p.target == ctx do return
	id := strings.clone(ctx, w.alloc)
	append(&w.pages, Web_Page{"", id})
	if w.headless || web_size != {} {
		size := web_size if web_size != {} else WEB_DEFAULT_SIZE
		web_send(w, "browsingContext.setViewport", fmt.tprintf(`{{"context":%s,"viewport":{{"width":%d,"height":%d}},"devicePixelRatio":1}}`, jq(id), size[0], size[1]))
	}
	if _, set := w.geo.?; set do bidi_geo(w, id)
	w.navigating = false
}

@(private = "file")
bidi_page_gone :: proc(w: ^Web, ctx: string) {
	for p, i in w.pages do if p.target == ctx {
		ordered_remove(&w.pages, i)
		return
	}
}

bidi_event :: proc(w: ^Web, msg: json.Object) {
	method, _ := msg["method"].(json.String)
	params, _ := msg["params"].(json.Object)
	ctx, _ := params["context"].(json.String)
	page := web_page(w)
	switch method {
	case "browsingContext.contextCreated":
		if _, child := params["parent"].(json.String); child do return // a frame
		bidi_page_created(w, ctx)
	case "browsingContext.contextDestroyed":
		bidi_page_gone(w, ctx)
	case "browsingContext.navigationStarted":
		if ctx == page.target do w.navigating = true
	case "browsingContext.domContentLoaded":
		if ctx == page.target {
			w.navigating = false
			w.documents += 1
			w.nav_events += 1
		}
	case "browsingContext.fragmentNavigated", "browsingContext.navigationFailed":
		if ctx == page.target {
			w.navigating = false
			w.nav_events += 1
		}
	case "browsingContext.userPromptOpened":
		// Accepted, as a user would: flows have no command for browser dialogs.
		web_send(w, "browsingContext.handleUserPrompt", fmt.tprintf(`{{"context":%s,"accept":true}}`, jq(ctx)))
	}
}

// ---- the page ----------------------------------------------------------------------------

// web_eval for Firefox: script.evaluate in the driven page's own realm.
bidi_eval :: proc(w: ^Web, expr: string, await: bool, timeout := WEB_CALL_TIMEOUT) -> (value: json.Value, err: string) {
	params := fmt.tprintf(`{{"expression":%s,"target":{{"context":%s}},"awaitPromise":%v,"resultOwnership":"none"}}`, jq(expr), jq(web_page(w).target), await)
	r, e := web_call(w, "script.evaluate", params, "", timeout)
	if e != "" do return nil, e
	if t, _ := r["type"].(json.String); t == "exception" {
		details, _ := r["exceptionDetails"].(json.Object)
		text, _ := details["text"].(json.String)
		return nil, text if text != "" else "exception"
	}
	return bidi_value(r["result"]), ""
}

// A WebDriver BiDi remote value as plain JSON: strings, numbers, booleans, arrays and objects.
@(private = "file")
bidi_value :: proc(v: json.Value) -> json.Value {
	o, ok := v.(json.Object)
	if !ok do return nil
	t, _ := o["type"].(json.String)
	switch t {
	case "string", "boolean":
		return o["value"]
	case "number":
		if _, special := o["value"].(json.String); special do return json.Float(0) // NaN, Infinity, -0
		return o["value"]
	case "array":
		list, _ := o["value"].(json.Array)
		out := make(json.Array, len(list), context.temp_allocator)
		for e, i in list do out[i] = bidi_value(e)
		return out
	case "object":
		pairs, _ := o["value"].(json.Array)
		out := make(json.Object, len(pairs), context.temp_allocator)
		for p in pairs {
			kv, _ := p.(json.Array)
			if len(kv) != 2 do continue
			if k, is := kv[0].(json.String); is do out[k] = bidi_value(kv[1])
		}
		return out
	}
	return nil
}

// ---- input -------------------------------------------------------------------------------

// `count` clicks at x, y, `interval` ms apart, each held `hold` ms: one input.performActions,
// the pointer moved there first.
bidi_click :: proc(w: ^Web, x, y: i32, count: int, hold: i32, interval: i32) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"context":%s,"actions":[{{"type":"pointer","id":"mouse","parameters":{{"pointerType":"mouse"}},"actions":[`, jq(web_page(w).target))
	fmt.sbprintf(&b, `{{"type":"pointerMove","x":%d,"y":%d}}`, x, y)
	for k in 1 ..= count {
		if k > 1 && interval > 0 do fmt.sbprintf(&b, `,{{"type":"pause","duration":%d}}`, interval)
		strings.write_string(&b, `,{"type":"pointerDown","button":0}`)
		if hold > 0 do fmt.sbprintf(&b, `,{{"type":"pause","duration":%d}}`, hold)
		strings.write_string(&b, `,{"type":"pointerUp","button":0}`)
	}
	strings.write_string(&b, `]}]}`)
	web_call(w, "input.performActions", strings.to_string(b))
}

// A key as WebDriver names it: a character, or one of its codes for keys that type none.
bidi_key_value :: proc(k: Web_Key) -> string {
	switch k.key {
	case "Enter":      return "\uE007"
	case "Backspace":  return "\uE003"
	case "Delete":     return "\uE017"
	case "Tab":        return "\uE004"
	case "Escape":     return "\uE00C"
	case "ArrowUp":    return "\uE013"
	case "ArrowDown":  return "\uE015"
	case "ArrowLeft":  return "\uE012"
	case "ArrowRight": return "\uE014"
	case "Home":       return "\uE011"
	case "End":        return "\uE010"
	case "PageUp":     return "\uE00E"
	case "PageDown":   return "\uE00F"
	}
	return k.text if k.text != "" else k.key
}

// Each key pressed and released, in one input.performActions; the request's id.
bidi_keys :: proc(w: ^Web, values: []string) -> int {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"context":%s,"actions":[{{"type":"key","id":"keyboard","actions":[`, jq(web_page(w).target))
	for v, i in values {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"type":"keyDown","value":%s}},{{"type":"keyUp","value":%s}}`, jq(v), jq(v))
	}
	strings.write_string(&b, `]}]}`)
	return web_send(w, "input.performActions", strings.to_string(b))
}

// inputText: a key per character, a line break as Enter and a tab as Tab.
bidi_type :: proc(w: ^Web, text: string) {
	keys := make([dynamic]string, context.temp_allocator)
	for r in text {
		switch r {
		case '\n': append(&keys, bidi_key_value({key = "Enter"}))
		case '\t': append(&keys, bidi_key_value({key = "Tab"}))
		case:      append(&keys, fmt.tprintf("%c", r))
		}
	}
	web_wait(w, bidi_keys(w, keys[:]))
}

// A mouse wheel at x, y.
bidi_wheel :: proc(w: ^Web, x, y, dx, dy: i32) {
	web_call(w, "input.performActions", fmt.tprintf(`{{"context":%s,"actions":[{{"type":"wheel","id":"wheel","actions":[{{"type":"scroll","x":%d,"y":%d,"deltaX":%d,"deltaY":%d}}]}}]}}`,
		jq(web_page(w).target), x, y, dx, dy))
}

// ---- navigating and the page's settings --------------------------------------------------

// Opens `url` in the driven page; returns once the navigation started. Its document's events
// (bidi_event) tell when it has loaded; one that already came, or a move within the document,
// leaves nothing to wait for.
bidi_navigate :: proc(w: ^Web, url: string) -> string {
	before := w.nav_events
	_, err := web_call(w, "browsingContext.navigate", fmt.tprintf(`{{"context":%s,"url":%s,"wait":"none"}}`, jq(web_page(w).target), jq(url)), "", WEB_LOAD_TIMEOUT)
	if err != "" do return fmt.tprintf("could not open %s: %s", url, err)
	if w.nav_events == before do w.navigating = true
	return ""
}

// clearState: the data the browser keeps for the url's origin (cookies, storage, caches,
// service workers), as Chrome's clearDataForOrigin: WebDriver BiDi has no such command, so
// Firefox's own clear-data service, from the browser's window (system access).
bidi_clear :: proc(w: ^Web, origin: string) -> bool {
	window := bidi_window(w)
	if window == "" do return false
	clear := fmt.tprintf(`new Promise((resolve) => Services.clearData.deleteDataFromPrincipal(Services.scriptSecurityManager.createContentPrincipalFromOrigin(%s), true, Ci.nsIClearDataService.CLEAR_ALL, () => resolve(true)))`, jq(origin))
	_, err := web_call(w, "script.evaluate", fmt.tprintf(`{{"expression":%s,"target":{{"context":%s}},"awaitPromise":true,"resultOwnership":"none"}}`, jq(clear), jq(window)))
	return err == ""
}

// The browser window's own context (its chrome), where scripts have system access.
@(private = "file")
bidi_window :: proc(w: ^Web) -> string {
	tree, err := web_call(w, "browsingContext.getTree", `{"maxDepth":0,"moz:scope":"chrome"}`)
	if err != "" do return ""
	contexts, _ := tree["contexts"].(json.Array)
	if len(contexts) == 0 do return ""
	o, _ := contexts[0].(json.Object)
	id, _ := o["context"].(json.String)
	return id
}

// A tab of Speedrun's own, the only one: Firefox's first tab closed (a blank page of the
// browser's own that page scripts cannot run in). It has the focus, which a page's `:focus`
// needs, and its blank document is set up by hand.
@(private = "file")
bidi_fresh_tab :: proc(w: ^Web) -> bool {
	created, cerr := web_call(w, "browsingContext.create", `{"type":"tab"}`)
	if cerr != "" do return false
	ctx, _ := created["context"].(json.String)
	ctx = strings.clone(ctx, context.temp_allocator)
	bidi_page_created(w, ctx)
	tree, _ := web_call(w, "browsingContext.getTree", `{"maxDepth":0}`)
	contexts, _ := tree["contexts"].(json.Array)
	for c in contexts {
		o, _ := c.(json.Object)
		id, _ := o["context"].(json.String)
		if id == "" || id == ctx do continue
		web_call(w, "browsingContext.close", fmt.tprintf(`{{"context":%s}}`, jq(id)))
		bidi_page_gone(w, id)
	}
	web_call(w, "browsingContext.activate", fmt.tprintf(`{{"context":%s}}`, jq(ctx)))
	bidi_setup_blank(w)
	return true
}

// launchApp's arguments: a preload script for every document from now on, replacing the last.
bidi_globals :: proc(w: ^Web, src: string) {
	if w.globals_id != "" {
		web_call(w, "script.removePreloadScript", fmt.tprintf(`{{"script":%s}}`, jq(w.globals_id)))
		w.globals_id = ""
	}
	if w.globals != "" do delete(w.globals, w.alloc)
	w.globals = strings.clone(src, w.alloc)
	if src == "" do return
	r, err := web_call(w, "script.addPreloadScript", fmt.tprintf(`{{"functionDeclaration":%s}}`, jq(fmt.tprintf("() => {{\n%s\n}}", src))))
	if err == "" {
		id, _ := r["script"].(json.String)
		w.globals_id = strings.clone(id, w.alloc)
	}
	_, _ = web_eval(w, src, false)
}

// setLocation: the context's geolocation (allowed without asking: the profile's prefs).
bidi_geo :: proc(w: ^Web, ctx: string) {
	geo, set := w.geo.?
	if !set do return
	web_send(w, "emulation.setGeolocationOverride", fmt.tprintf(`{{"coordinates":{{"latitude":%f,"longitude":%f,"accuracy":1}},"contexts":[%s]}}`, geo[0], geo[1], jq(ctx)))
}

// setDarkMode: WebDriver BiDi has no prefers-color-scheme override yet, so the browser's own
// preference for it (its value 0 is dark, 1 light), set from the browser's window (system
// access), then a wait of up to 500 ms for the page to see it.
bidi_appearance :: proc(w: ^Web) {
	dark, set := w.dark.?
	if !set do return
	window := bidi_window(w)
	if window == "" do return
	pref := fmt.tprintf(`Services.prefs.setIntPref("layout.css.prefers-color-scheme.content-override", %d)`, 0 if dark else 1)
	web_call(w, "script.evaluate", fmt.tprintf(`{{"expression":%s,"target":{{"context":%s}},"awaitPromise":false,"resultOwnership":"none"}}`, jq(pref), jq(window)))
	wait := fmt.tprintf(`new Promise((r) => {{ const m = matchMedia('(prefers-color-scheme: dark)'); if (m.matches === %v) return r(); m.addEventListener('change', r, {{ once: true }}); setTimeout(r, 500) }})`, dark)
	_, _ = web_eval(w, wait, true)
}

// ---- finding Firefox ---------------------------------------------------------------------

// The Firefox to run: SPEEDRUN_FIREFOX, else (macOS) the installed one, else the newest in the
// cache, else one downloaded into it.
firefox_executable :: proc() -> (path: string, err: string) {
	if p := os.get_env("SPEEDRUN_FIREFOX", context.temp_allocator); p != "" {
		if !os.exists(p) do return "", fmt.tprintf("SPEEDRUN_FIREFOX: %s does not exist", p)
		return p, ""
	}
	when ODIN_OS == .Darwin {
		home := os.get_env("HOME", context.temp_allocator)
		for p in ([]string{"/Applications/Firefox.app/Contents/MacOS/firefox", fmt.tprintf("%s/Applications/Firefox.app/Contents/MacOS/firefox", home)}) {
			if os.exists(p) do return p, ""
		}
	}
	// On Linux the cache's: a distribution's Firefox is often a snap, confined away from the
	// profile in the temporary folder.
	if p, version := firefox_cached(); p != "" do return firefox_refresh(p, version), ""
	return firefox_download()
}

// The cached Firefox kept current, as Chrome for Testing's (web_refresh): once a day, Mozilla's
// latest release, downloaded when it is newer; the cached one otherwise.
@(private = "file")
firefox_refresh :: proc(exe, version: string) -> string {
	if !browser_check_due(firefox_cache_dir(), "firefox") do return exe
	latest, err := firefox_latest()
	if err != "" || !version_newer(latest, version) do return exe
	fresh, ferr := firefox_fetch(latest, version)
	if ferr != "" {
		fmt.eprintf("%s: running Firefox %s\n", ferr, version)
		return exe
	}
	browser_prune(firefox_cache_dir(), "firefox")
	return fresh
}

@(private = "file")
firefox_cache_dir :: proc() -> string {
	return fmt.tprintf("%s/firefox", strings.trim_suffix(web_cache_dir(), "/chrome"))
}

@(private = "file")
firefox_in :: proc(dir: string) -> string {
	when ODIN_OS == .Darwin {
		return fmt.tprintf("%s/Firefox.app/Contents/MacOS/firefox", dir)
	} else {
		return fmt.tprintf("%s/firefox/firefox", dir)
	}
}

// The newest Firefox in the cache (folders `firefox-<version>`) and its version, "" for none.
@(private = "file")
firefox_cached :: proc() -> (exe, version: string) {
	entries, err := os.read_all_directory_by_path(firefox_cache_dir(), context.temp_allocator)
	if err != nil do return
	for e in entries {
		v := strings.trim_prefix(e.name, "firefox-")
		if v == e.name || v == "" || v[0] < '0' || v[0] > '9' do continue
		x := firefox_in(e.fullpath)
		if !os.exists(x) do continue
		if exe == "" || version_newer(v, version) do exe, version = x, v
	}
	return
}

// Downloads Mozilla's current Firefox release into the cache.
@(private = "file")
firefox_download :: proc() -> (exe: string, err: string) {
	when ODIN_OS != .Darwin && !(ODIN_OS == .Linux && ODIN_ARCH == .amd64) {
		return "", "No Firefox on this machine: set SPEEDRUN_FIREFOX to a Firefox executable."
	}
	version, lerr := firefox_latest()
	if lerr != "" do return "", lerr
	return firefox_fetch(version, "")
}

// Mozilla's latest Firefox release.
@(private = "file")
firefox_latest :: proc() -> (version: string, err: string) {
	VERSIONS :: "https://product-details.mozilla.org/1.0/firefox_versions.json"
	state, out, stderr, perr := os.process_exec({command = {"curl", "-fsSL", "--max-time", "60", VERSIONS}}, context.temp_allocator)
	if perr != nil || !state.success {
		return "", fmt.tprintf("No Firefox on this machine, and Mozilla's list of releases could not be fetched (%s). Install Firefox, or set SPEEDRUN_FIREFOX to a Firefox executable.", strings.trim_space(string(stderr)))
	}
	v, jerr := json.parse(out, allocator = context.temp_allocator)
	if jerr != nil do return "", "could not read Mozilla's list of Firefox releases"
	root, _ := v.(json.Object)
	version, _ = root["LATEST_FIREFOX_VERSION"].(json.String)
	if version == "" do return "", "Mozilla's list of releases names no Firefox version"
	return version, ""
}

// Downloads Firefox `version` into the cache: the macOS disk image (mounted with hdiutil, its
// app copied) or the Linux archive (tar), with curl. `replacing`: the cached version it is
// newer than ("" for none).
@(private = "file")
firefox_fetch :: proc(version, replacing: string) -> (exe: string, err: string) {
	state: os.Process_State
	stderr: []byte
	perr: os.Error
	cache := firefox_cache_dir()
	if e := os.make_directory_all(cache); e != nil && e != .Exist do return "", fmt.tprintf("could not create %s: %v", cache, e)
	tmp, terr := os.make_directory_temp(cache, "download-*", context.temp_allocator)
	if terr != nil do return "", fmt.tprintf("could not create a folder in %s: %v", cache, terr)
	defer os.remove_all(tmp)
	final := fmt.tprintf("%s/firefox-%s", cache, version)
	unpacked := fmt.tprintf("%s/unpacked", tmp)
	if e := os.make_directory(unpacked); e != nil do return "", fmt.tprintf("could not create %s: %v", unpacked, e)
	if replacing != "" do fmt.eprintf("Downloading Firefox %s (newer than the cached %s) into %s...\n", version, replacing, cache)
	else do fmt.eprintf("Downloading Firefox %s into %s...\n", version, cache)
	when ODIN_OS == .Darwin {
		url := fmt.tprintf("https://archive.mozilla.org/pub/firefox/releases/%s/mac/en-US/Firefox%%20%s.dmg", version, version)
		dmg := fmt.tprintf("%s/firefox.dmg", tmp)
		state, _, stderr, perr = os.process_exec({command = {"curl", "-fL", "--max-time", "600", "-o", dmg, url}}, context.temp_allocator)
		if perr != nil || !state.success do return "", fmt.tprintf("could not download %s: %s", url, strings.trim_space(string(stderr)))
		mount := fmt.tprintf("%s/mount", tmp)
		state, _, stderr, perr = os.process_exec({command = {"hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount, dmg}}, context.temp_allocator)
		if perr != nil || !state.success do return "", fmt.tprintf("could not open %s (hdiutil): %s", dmg, strings.trim_space(string(stderr)))
		state, _, stderr, perr = os.process_exec({command = {"cp", "-R", fmt.tprintf("%s/Firefox.app", mount), unpacked}}, context.temp_allocator)
		_, _, _, _ = os.process_exec({command = {"hdiutil", "detach", "-quiet", mount}}, context.temp_allocator)
		if perr != nil || !state.success do return "", fmt.tprintf("could not copy Firefox out of %s: %s", dmg, strings.trim_space(string(stderr)))
	} else {
		url := fmt.tprintf("https://archive.mozilla.org/pub/firefox/releases/%s/linux-x86_64/en-US/firefox-%s.tar.xz", version, version)
		archive := fmt.tprintf("%s/firefox.tar.xz", tmp)
		state, _, stderr, perr = os.process_exec({command = {"curl", "-fL", "--max-time", "600", "-o", archive, url}}, context.temp_allocator)
		if perr != nil || !state.success do return "", fmt.tprintf("could not download %s: %s", url, strings.trim_space(string(stderr)))
		state, _, stderr, perr = os.process_exec({command = {"tar", "-xJf", archive, "-C", unpacked}}, context.temp_allocator)
		if perr != nil || !state.success do return "", fmt.tprintf("could not unpack %s (tar): %s", archive, strings.trim_space(string(stderr)))
	}
	if e := os.rename(unpacked, final); e != nil && !os.exists(firefox_in(final)) {
		return "", fmt.tprintf("could not move Firefox to %s: %v", final, e)
	}
	exe = firefox_in(final)
	if !os.exists(exe) do return "", fmt.tprintf("the download has no %s", exe)
	return strings.clone(exe), ""
}
