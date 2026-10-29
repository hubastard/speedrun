// JavaScript in flows: `${...}` in
// command fields, evalScript, runScript, assertTrue and `true:` conditions. The engine is
// QuickJS-ng (js/engine.c, js/prelude.js), one per flow, started on the first script; env
// variables reach it as globals, kept in step with the runner's scopes.
package speedrun

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// build.sh compiles it.
when ODIN_OS == .Linux {
	foreign import js_lib {"js/build/libspeedrunjs.a", "system:m", "system:pthread"}
} else {
	foreign import js_lib "js/build/libspeedrunjs.a"
}

Js :: struct {}

@(private = "file")
Js_Log :: #type proc "c" (user: rawptr, msg: [^]u8, len: c.size_t)
@(private = "file")
Js_Http :: #type proc "c" (user: rawptr, request: [^]u8, len: c.size_t) -> [^]u8

@(default_calling_convention = "c", private = "file")
foreign js_lib {
	sr_js_new :: proc(prelude: [^]u8, prelude_len: c.size_t, platform: cstring, log: Js_Log, http: Js_Http, user: rawptr, err: ^[^]u8) -> ^Js ---
	sr_js_free :: proc(e: ^Js) ---
	sr_js_call :: proc(e: ^Js, method: cstring, arg: [^]u8, arg_len: c.size_t, out: ^[^]u8, out_len: ^c.size_t) -> c.int ---
	sr_js_free_text :: proc(s: [^]u8) ---
}

@(private = "file")
PRELUDE :: #load("js/prelude.js", string)
// Datafaker's English word lists, for `faker` and inputRandom* (Apache-2.0, js/datafaker/LICENSE).
@(private = "file")
FAKER_DATA :: #load("js/datafaker/data.json", string)

// Runs `script` in the flow's engine: its value as `${...}` takes it (a string as it is,
// anything else in its display form), or the message of what it threw.
js_run :: proc(r: ^Runner, script: string) -> (value: string, err: Err) {
	js_start(r) or_return
	if r.js_env_gen != r.env_gen {
		// Innermost scope wins, as in the runner's lookups.
		flat := make(map[string]string, 16, context.temp_allocator)
		for scope in r.env do for k, v in scope do flat[k] = v
		data, merr := json.marshal(flat, allocator = context.temp_allocator)
		if merr != nil do return "", "cannot pass the env to the JavaScript engine"
		js_call(r, "setEnv", string(data)) or_return
		r.js_env_gen = r.env_gen
	}
	return js_call(r, "run", script)
}

// InputRandomCommand.genRandomString: a random value of that kind, from `faker`.
js_random :: proc(r: ^Runner, kind: Random_Kind, length: int) -> (value: string, err: Err) {
	js_start(r) or_return
	return js_call(r, "random", fmt.tprintf("%v:%d", kind, length))
}

@(private = "file")
js_start :: proc(r: ^Runner) -> Err {
	if r.js == nil {
		msg: [^]u8
		platform: cstring = "ios" if r.dev.platform == .IOS else "android"
		r.js = sr_js_new(raw_data(PRELUDE), len(PRELUDE), platform, js_log, js_http, r, &msg)
		if r.js == nil {
			e := strings.clone(string(cstring(msg)), r.alloc) if msg != nil else "out of memory"
			sr_js_free_text(msg)
			return fmt.aprintf("cannot start the JavaScript engine: %s", e, allocator = r.alloc)
		}
		_ = js_call(r, "setFakerData", FAKER_DATA) or_return
		if t, ok := r.copied_text.?; ok do _ = js_call(r, "setCopiedText", t) or_return
	}
	return nil
}

js_stop :: proc(r: ^Runner) {
	if r.js != nil do sr_js_free(r.js)
	r.js = nil
}

// The scripts' maestro.copiedText, for copyTextFrom and setClipboard.
set_copied_text :: proc(r: ^Runner, text: string) -> Err {
	r.copied_text = text
	if r.js != nil do js_call(r, "setCopiedText", text) or_return
	return nil
}

@(private = "file")
js_call :: proc(r: ^Runner, method: cstring, arg: string) -> (out: string, err: Err) {
	text: [^]u8
	n: c.size_t
	empty := u8(0)
	failed := sr_js_call(r.js, method, raw_data(arg) if len(arg) > 0 else &empty, len(arg), &text, &n)
	if text == nil do return "", "JavaScript: out of memory"
	out = strings.clone(string(text[:n]), r.alloc)
	sr_js_free_text(text)
	if failed != 0 do return "", out
	return out, nil
}

// console.log: the line goes with the command running (shown under it, and in logs/speedrun.log).
@(private = "file")
js_log :: proc "c" (user: rawptr, msg: [^]u8, n: c.size_t) {
	context = runtime.default_context()
	r := (^Runner)(user)
	context.allocator = r.alloc
	line := strings.clone(string(msg[:n]))
	if r.log_rec >= 0 && r.log_rec < len(r.records) do append(&r.records[r.log_rec].logs, line)
	if r.log_node != nil do append(&r.log_node.logs, line)
}

// ---- http, through curl -----------------------------------------------------------------

@(private = "file")
Http_Part :: struct {
	name, value, file: string,
	media:             string `json:"type"`,
}

@(private = "file")
Http_Request :: struct {
	method, url: string,
	headers:     [][2]string,
	has_body:    bool,
	body:        string,
	form:        bool,
	parts:       []Http_Part,
}

@(private = "file")
Http_Reply :: struct {
	status:  int `json:"status"`,
	body:    string `json:"body"`,
	headers: map[string]string `json:"headers"`,
	error:   string `json:"error,omitempty"`,
}

@(private = "file")
js_http :: proc "c" (user: rawptr, request: [^]u8, n: c.size_t) -> [^]u8 {
	context = runtime.default_context()
	r := (^Runner)(user)
	context.allocator = r.alloc
	reply := http_request(r, string(request[:n]))
	data, err := json.marshal(reply)
	if err != nil do data = transmute([]byte)string(`{"error":"http: cannot encode the reply"}`)
	out := ([^]u8)(libc.malloc(c.size_t(len(data) + 1)))
	if out == nil do return nil
	copy(out[:len(data)], data)
	out[len(data)] = 0
	return out
}

// One request as okhttp sends it: redirects followed, gzip decoded, a string
// body without a Content-Type unless given, 5 minutes at most. The reply's headers are
// lowercased, repeated ones joined with ",".
// A new file in the temp folder, made here (exclusively: a name already taken, such as a
// link another user left in a shared /tmp, is not used) and readable by the user alone. ""
// when it cannot be made.
private_temp_file :: proc(pattern: string, allocator := context.temp_allocator) -> string {
	f, err := os.create_temp_file("", pattern)
	if err != nil do return ""
	name := strings.clone(os.name(f), allocator)
	os.close(f)
	_ = os.change_mode(name, {.Read_User, .Write_User})
	return name
}

@(private = "file")
http_request :: proc(r: ^Runner, text: string) -> (reply: Http_Reply) {
	req: Http_Request
	if json.unmarshal_string(text, &req) != nil do return {error = "http: malformed request"}

	body_in, body_out, headers_out := private_temp_file("speedrun-http-*.request"), private_temp_file("speedrun-http-*.body"), private_temp_file("speedrun-http-*.headers")
	if body_in == "" || body_out == "" || headers_out == "" do return {error = "http: cannot create temp files"}
	defer {
		os.remove(body_in)
		os.remove(body_out)
		os.remove(headers_out)
	}

	cmd := make([dynamic]string, 0, 32, context.temp_allocator)
	// http and https only, redirects too, as Maestro's OkHttp: no file://, no other protocol.
	append(&cmd, "curl", "-sS", "-L", "--proto", "=http,https", "--proto-redir", "=http,https", "--compressed", "--max-time", "300", "-o", body_out, "-D", headers_out, "-w", "%{http_code}")
	has_body := req.has_body || req.form
	switch {
	case req.method == "HEAD":                 append(&cmd, "-I")
	case req.method == "GET" && !has_body:     // curl's default
	case req.method == "POST" && has_body:     // implied by the body
	case:                                      append(&cmd, "-X", req.method)
	}
	content_type := false
	for h in req.headers {
		append(&cmd, "-H", fmt.tprintf("%s: %s", h[0], h[1]))
		if strings.equal_fold(h[0], "content-type") do content_type = true
	}
	if req.has_body {
		if os.write_entire_file(body_in, transmute([]byte)req.body) != nil do return {error = "http: cannot write the request body"}
		append(&cmd, "--data-binary", strings.concatenate({"@", body_in}))
		if !content_type do append(&cmd, "-H", "Content-Type:")
	}
	for p in req.parts {
		if p.file == "" {
			append(&cmd, "--form-string", fmt.tprintf("%s=%s", p.name, p.value))
			continue
		}
		path := p.file
		if !filepath.is_abs(path) do path, _ = filepath.join({r.script_dir if r.script_dir != "" else ".", path}, context.temp_allocator)
		spec := fmt.tprintf("%s=@\"%s\"", p.name, path)
		if p.media != "" do spec = fmt.tprintf("%s;type=%s", spec, p.media)
		append(&cmd, "-F", spec)
	}
	append(&cmd, "--url", req.url)

	state, stdout, stderr, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil do return {error = "http requests need curl on PATH"}
	if !state.exited || state.exit_code != 0 {
		msg := strings.trim_space(string(stderr))
		return {error = msg if msg != "" else fmt.aprintf("curl failed (exit %d)", state.exit_code)}
	}
	status, ok := strconv.parse_int(strings.trim_space(string(stdout)))
	if !ok do return {error = fmt.aprintf("http: unexpected curl output %q", string(stdout))}
	reply.status = status

	// -L keeps every response's headers: the last block is the final response's.
	raw, _ := os.read_entire_file(headers_out, context.temp_allocator)
	block := ""
	for b in strings.split(string(raw), "\r\n\r\n", context.temp_allocator) {
		if strings.has_prefix(b, "HTTP/") do block = b
	}
	reply.headers = make(map[string]string)
	for line, k in strings.split_lines(block, context.temp_allocator) {
		if k == 0 do continue // status line
		name, colon, value := strings.partition(strings.trim_right(line, "\r"), ":")
		if colon == "" do continue
		key := strings.to_lower(strings.trim_space(name))
		value = strings.trim_space(value)
		reply.headers[key] = fmt.aprintf("%s,%s", reply.headers[key], value) if key in reply.headers else strings.clone(value)
	}
	if req.method != "HEAD" {
		body, _ := os.read_entire_file(body_out, context.allocator)
		reply.body = string(body)
	}
	return
}
