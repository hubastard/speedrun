// speedrun mcp: a Model Context Protocol server over stdio (JSON-RPC 2.0, a message per
// line), for AI agents that take tools from MCP servers. Its tools are a session's verbs
// (session.odin): start one, look at the screen, run flow commands, save the flow. JSON is
// built by concatenation: fmt reads a { as the start of an argument index.
package speedrun

import "core:bufio"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

MCP_PROTOCOL :: "2025-06-18"

MCP_INSTRUCTIONS :: "Drives a mobile app on an Android emulator or iOS simulator, a command at a time. Start a session for the app, look at the screen (a line per element, each with a ref like @7), run flow commands (Maestro's YAML) using those refs, and save the commands that worked as a flow file for CI (run with `speedrun test <file>`)."

// Descriptions are short: a client sends them to the model with every request.
MCP_TOOLS :: `[
{"name":"session_start","description":"Connect to the device for an app (once; the session stays connected). platform: android or ios when both are up; device: an adb serial or simulator UDID.","inputSchema":{"type":"object","properties":{"app":{"type":"string","description":"The app id (package or bundle id)"},"platform":{"type":"string","enum":["android","ios"]},"device":{"type":"string"}},"required":["app"]}},
{"name":"look","description":"The screen: a line per element a user sees or acts on (kind, \"text\", #id, state), each with a ref (@7) for run. screenshot: also a small screenshot (only when the text is not enough). all: also every node of the accessibility tree (long; when the listing misses something).","inputSchema":{"type":"object","properties":{"screenshot":{"type":"boolean"},"all":{"type":"boolean"}}}},
{"name":"run","description":"Run flow commands, written as in a Maestro flow file: one command (tapOn: \"Sign in\") or a list (- tapOn: @7\n- inputText: \"hi\"). A ref @7 stands for that element's selector. Answers a line per command, then what changed on screen: + new, ~ changed, - gone.","inputSchema":{"type":"object","properties":{"commands":{"type":"string"}},"required":["commands"]}},
{"name":"save_flow","description":"Write the commands that passed so far as a flow file (YAML), for CI.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"e.g. flows/sign-in.yaml"}},"required":["path"]}},
{"name":"session_log","description":"The commands that passed so far, numbered.","inputSchema":{"type":"object","properties":{}}},
{"name":"session_clear","description":"Forget the commands recorded so far (the next save_flow starts from here).","inputSchema":{"type":"object","properties":{}}},
{"name":"session_stop","description":"Disconnect from the device.","inputSchema":{"type":"object","properties":{}}}
]`

run_mcp_cli :: proc(args: []string) -> int {
	if len(args) > 0 {
		fmt.eprintln(`usage: speedrun mcp   (a Model Context Protocol server on stdin/stdout)
  claude mcp add speedrun -- speedrun mcp`)
		return 0 if args[0] == "-h" || args[0] == "--help" else 2
	}
	r: bufio.Reader
	bufio.reader_init(&r, os.to_stream(os.stdin), 1 << 16)
	defer bufio.reader_destroy(&r)
	for {
		line, err := bufio.reader_read_string(&r, '\n', context.temp_allocator)
		if strings.trim_space(line) != "" do mcp_message(strings.trim_space(line))
		free_all(context.temp_allocator)
		if err != nil do break // the client closed the channel
	}
	return 0
}

@(private = "file")
mcp_message :: proc(line: string) {
	v, perr := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
	if perr != nil {
		mcp_send(`null`, "", mcp_error(-32700, "parse error"))
		return
	}
	msg, is_obj := v.(json.Object)
	if !is_obj {
		mcp_send(`null`, "", mcp_error(-32600, "invalid request"))
		return
	}
	id_value, has_id := msg["id"]
	if !has_id do return // a notification (notifications/initialized): no answer
	id := json_text(id_value)
	method, _ := msg["method"].(json.String)
	params, _ := msg["params"].(json.Object)
	switch method {
	case "initialize":
		version := MCP_PROTOCOL
		if p, ok := params["protocolVersion"].(json.String); ok do version = p
		mcp_send(id, strings.concatenate({
			`{"protocolVersion":`, json_string(version),
			`,"capabilities":{"tools":{}},"serverInfo":{"name":"speedrun","version":`, json_string(VERSION),
			`},"instructions":`, json_string(MCP_INSTRUCTIONS), `}`,
		}, context.temp_allocator), "")
	case "ping":
		mcp_send(id, `{}`, "")
	case "tools/list":
		// One line: a message per line (the list's line breaks are between its entries).
		tools, _ := strings.replace_all(MCP_TOOLS, "\n", "", context.temp_allocator)
		mcp_send(id, strings.concatenate({`{"tools":`, tools, `}`}, context.temp_allocator), "")
	case "tools/call":
		mcp_send(id, mcp_call(params), "")
	case:
		mcp_send(id, "", mcp_error(-32601, fmt.tprintf("method not found: %s", method)))
	}
}

// A tool call's result: the answer as text (and an image for a look with a screenshot);
// isError when a command failed or the session could not be reached.
@(private = "file")
mcp_call :: proc(params: json.Object) -> string {
	name, _ := params["name"].(json.String)
	args, _ := params["arguments"].(json.Object)
	arg :: proc(args: json.Object, key: string) -> string {
		v, _ := args[key].(json.String)
		return v
	}
	code := 0
	text := ""
	image := ""
	switch name {
	case "session_start":
		code, text = start_session(arg(args, "app"), arg(args, "platform"), arg(args, "device"), nil)
	case "look":
		shot, _ := args["screenshot"].(json.Boolean)
		all, _ := args["all"].(json.Boolean)
		code, text, _ = session_request("look", strings.concatenate({"--shot " if shot else "", "--all" if all else ""}, context.temp_allocator))
		// The screenshot inline, its path line left out.
		if before, found, path := strings.partition(text, "screenshot: "); shot && found != "" {
			path = strings.trim_space(path)
			if png, err := os.read_entire_file(path, context.temp_allocator); err == nil {
				image = base64.encode(png, allocator = context.temp_allocator)
				text = before
			}
		}
	case "run":
		commands := arg(args, "commands")
		if strings.trim_space(commands) == "" {
			code, text = 2, "No command given: commands takes flow commands, as in a flow file."
		} else {
			code, text, _ = session_request("do", commands)
		}
	case "save_flow":
		code, text, _ = session_request("save", arg(args, "path"))
	case "session_log":
		code, text, _ = session_request("log", "")
	case "session_clear":
		code, text, _ = session_request("clear", "")
	case "session_stop":
		if _, running := session_running(); !running {
			text = "No session running."
		} else {
			code, text, _ = session_request("stop", "")
		}
	case:
		code, text = 2, fmt.tprintf("unknown tool: %s", name)
	}
	content := strings.concatenate({`[{"type":"text","text":`, json_string(strings.trim_right(text, "\n")), `}`}, context.temp_allocator)
	if image != "" {
		content = strings.concatenate({content, `,{"type":"image","data":"`, image, `","mimeType":"image/png"}`}, context.temp_allocator)
	}
	return strings.concatenate({`{"content":`, content, `],"isError":`, "true" if code != 0 else "false", `}`}, context.temp_allocator)
}

@(private = "file")
mcp_error :: proc(code: int, message: string) -> string {
	return strings.concatenate({`{"code":`, fmt.tprint(code), `,"message":`, json_string(message), `}`}, context.temp_allocator)
}

// One message: a result, else an error.
@(private = "file")
mcp_send :: proc(id, result, error: string) {
	msg := strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"result":`, result, `}`}, context.temp_allocator) if error == "" else strings.concatenate({`{"jsonrpc":"2.0","id":`, id, `,"error":`, error, `}`}, context.temp_allocator)
	os.write_string(os.stdout, msg)
	os.write_string(os.stdout, "\n")
	os.flush(os.stdout)
}

@(private = "file")
json_string :: proc(s: string) -> string {
	data, _ := json.marshal(s, allocator = context.temp_allocator)
	return string(data)
}

@(private = "file")
json_text :: proc(v: json.Value) -> string {
	data, err := json.marshal(v, allocator = context.temp_allocator)
	if err != nil do return `null`
	return string(data)
}
