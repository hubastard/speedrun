// `speedrun test`: one flow file runs with the live view; several flows (files, folders, a
// workspace config), or any report, run as a suite: one line per flow, then a summary.
// Reports (JUnit, HTML) and the debug output folder keep the layout tools reading them
// expect.
package speedrun

import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

Test_Options :: struct {
	inputs:                     [dynamic]string,
	config:                     string,
	env:                        [dynamic]Env_Pair,
	format:                     Report_Format,
	output:                     string,
	test_suite_name:            string,
	debug_output:               string,
	test_output_dir:            string,
	flatten:                    bool,
	include_tags, exclude_tags: [dynamic]string,
	shard_split, shard_all:     int,
	continuous:                 bool,
	platform:                   string,
	devices:                    [dynamic]string, // --device a,b
	// speedrun's own
	plain:                      bool,
	timings:                    string,
	port:                       int,
	port_given:                 bool,
	instrument:                 bool,
	// a shard run by a parent speedrun (--shard-worker <index> --shard-result <file.json>)
	worker_shard:               int,
	worker_result:              string,
}

Report_Format :: enum {
	Noop,
	Junit,
	Html,
	Html_Detailed,
}

TEST_USAGE :: `usage: speedrun test [options] <flow file or folder>...
Options (the same as maestro test's):
  -e, --env KEY=VALUE        --config <file>             --include-tags / --exclude-tags a,b
  --format junit|html|html-detailed|noop               --output <file>
  --test-suite-name <name>   --debug-output <dir>        --flatten-debug-output
  --test-output-dir <dir>    -p, --platform android|ios  --device, --udid <id>[,<id>...]
  --shard-split <n>          --shard-all <n>             -c, --continuous
speedrun's own:
  --plain (or --no-ansi)     --timings <file.json>       --port <n>       --instrument`

// args: what follows `test`; globals: -p/--device given before `test`.
run_test_cli :: proc(args: []string, global_platform, global_device: string) -> int {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	o: Test_Options
	o.worker_shard = -1
	o.platform = global_platform
	if global_device != "" do append_list(&o.devices, global_device)
	legacy_shards := 0
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		name, inline, has_inline := strings.partition(a, "=")
		if !strings.has_prefix(a, "-") || a == "-" {
			append(&o.inputs, a)
			continue
		}
		takes_value :: proc(name: string) -> bool {
			switch name {
			case "-e", "--env", "--config", "--format", "--output", "--test-suite-name", "--debug-output",
			     "--test-output-dir", "--include-tags", "--exclude-tags", "-s", "--shards", "--shard-split",
			     "--shard-all", "-p", "--platform", "--device", "--udid", "--timings", "--port",
			     "--shard-worker", "--shard-result",
			     "--screen-size", "--api-url", "--api-key", "--apple-team-id", "--driver-host-port":
				return true
			}
			return false
		}
		value := ""
		if takes_value(name) {
			if has_inline != "" {
				value = inline
			} else if i + 1 < len(args) {
				value = args[i + 1]
				i += 1
			} else {
				fmt.eprintf("Missing required parameter for option '%s'\n", name)
				return 2
			}
		}
		switch name {
		case "-e", "--env":
			k, eq, v := strings.partition(value, "=")
			if eq == "" {
				fmt.eprintf("Value for option '%s' should be in KEY=VALUE format but was %s\n", name, value)
				return 2
			}
			append(&o.env, Env_Pair{k, v})
		case "--config":
			o.config = value
		case "--format":
			switch strings.to_lower(value) {
			case "junit":         o.format = .Junit
			case "html":          o.format = .Html
			case "html-detailed", "html_detailed": o.format = .Html_Detailed
			case "noop":          o.format = .Noop
			case:
				fmt.eprintf("Invalid format: %s. Valid options are: JUNIT, HTML, HTML-DETAILED, NOOP\n", value)
				return 2
			}
		case "--output":
			o.output = value
		case "--test-suite-name":
			o.test_suite_name = value
		case "--debug-output":
			o.debug_output = value
		case "--test-output-dir":
			o.test_output_dir = value
		case "--flatten-debug-output":
			o.flatten = true
		case "--include-tags":
			append_list(&o.include_tags, value)
		case "--exclude-tags":
			append_list(&o.exclude_tags, value)
		case "-s", "--shards":
			legacy_shards = parse_count(name, value) or_else -1
			if legacy_shards < 0 do return 2
		case "--shard-split":
			o.shard_split = parse_count(name, value) or_else -1
			if o.shard_split < 0 do return 2
		case "--shard-all":
			o.shard_all = parse_count(name, value) or_else -1
			if o.shard_all < 0 do return 2
		case "-c", "--continuous":
			o.continuous = true
		case "-p", "--platform":
			o.platform = value
		case "--device", "--udid":
			append_list(&o.devices, value)
		case "--plain", "--no-ansi":
			o.plain = true
		case "--ansi":
			o.plain = false
		case "--timings":
			o.timings = value
		case "--port", "--driver-host-port":
			p, ok := strconv.parse_int(value)
			if !ok || p <= 0 || p > 65535 {
				fmt.eprintf("%s needs a port number\n", name)
				return 2
			}
			o.port, o.port_given = p, true
		case "--instrument":
			o.instrument = true
		case "--shard-worker":
			o.worker_shard = strconv.parse_int(value) or_else -1
		case "--shard-result":
			o.worker_result = value
		case "--apple-team-id":
			fmt.eprintln("Real iOS devices (--apple-team-id) are not supported yet: speedrun runs on iOS simulators.")
			return 2
		case "--analyze":
			fmt.eprintln("--analyze (AI insights) is not supported: ignored.")
		case "--headless", "--screen-size", "--api-url", "--api-key", "--reinstall-driver", "--no-reinstall-driver", "--verbose":
		// Web, cloud and driver-install options: nothing to do here.
		case "-h", "--help":
			fmt.println(TEST_USAGE)
			return 0
		case:
			fmt.eprintf("Unknown option: '%s'\n%s\n", a, TEST_USAGE)
			return 2
		}
	}
	if len(o.inputs) == 0 {
		fmt.eprintf("Missing required parameter: '<flowFiles>'\n%s\n", TEST_USAGE)
		return 2
	}
	if o.shard_split > 0 && o.shard_all > 0 {
		cli_error("Options --shard-split and --shard-all are mutually exclusive.")
		return 1
	}
	if legacy_shards > 0 {
		cli_warning("--shards is deprecated: use --shard-split or --shard-all instead.")
		o.shard_split = legacy_shards
	}
	if o.config != "" && !os.exists(o.config) {
		cli_error(fmt.tprintf("The config file %s does not exist.", absolute(o.config)))
		return 1
	}
	return run_test(&o)
}

@(private = "file")
append_list :: proc(list: ^[dynamic]string, value: string) {
	for part in strings.split(value, ",") {
		if p := strings.trim_space(part); p != "" do append(list, p)
	}
}

@(private = "file")
parse_count :: proc(name, value: string) -> (int, bool) {
	n, ok := strconv.parse_int(value)
	if !ok || n < 1 {
		fmt.eprintf("Invalid value for option '%s': '%s' is not a positive number\n", name, value)
		return 0, false
	}
	return n, true
}

run_test :: proc(o: ^Test_Options) -> int {
	plan, perr := workspace_plan(o.inputs[:], o.include_tags[:], o.exclude_tags[:], o.config, context.allocator)
	if e, bad := perr.?; bad {
		cli_error(e)
		return 1
	}
	debug_dir := debug_output_path(o, &plan)
	single := len(o.inputs) == 1 && os.is_file(o.inputs[0])

	shards := max(o.shard_split, o.shard_all, 1)
	if shards > 1 && o.worker_result == "" {
		if len(plan.sequence) > 0 {
			cli_error("Cannot run sharded tests with sequential execution")
			return 1
		}
		return run_shards(o, &plan, shards, debug_dir)
	}

	dev := Device {
		port       = o.port if o.port_given else 7777,
		instrument = o.instrument,
	}
	device := o.devices[0] if len(o.devices) > 0 else ""
	if err := device_select(&dev, o.platform, device, o.port_given); err != "" {
		cli_error(err)
		return 1
	}
	if err := device_start(&dev); err != "" {
		device_stop(&dev)
		cli_error(err)
		return 1
	}
	defer device_stop(&dev)
	c, ok := connect(dev.port)
	if !ok {
		cli_error(fmt.tprintf("could not reach the agent on port %d", dev.port))
		return 1
	}
	defer net.close(c.sock)
	device_id := dev.udid if dev.platform == .IOS else adb_serial

	if o.worker_result != "" {
		suite := run_suite(&c, &dev, &plan, o, device_id, debug_dir, max(o.worker_shard, 0))
		data, _ := json.marshal(suite, {}, context.allocator)
		if os.write_entire_file(o.worker_result, data) != nil do cli_error(fmt.tprintf("could not write %s", o.worker_result))
		return 0 if suite.passed else 1
	}
	if single && o.format == .Noop {
		if o.continuous do return run_continuous(&c, &dev, plan.flows[0], o, device_id)
		res := run_flow(&c, &dev, plan.flows[0], Run_Options {
			env = o.env[:], device_id = device_id, timings_path = o.timings, plain = o.plain,
			flow_dir = flow_dir(debug_dir, flow_file_name(plan.flows[0]), -1),
		}, context.allocator)
		if !res.passed {
			fmt.println()
			fmt.println("==== Debug output (logs & screenshots) ====")
			cli_message(debug_dir)
		}
		return 0 if res.passed else 1
	}
	if o.continuous {
		inputs := strings.join(o.inputs[:], ", ")
		fmt.eprintf("Continuous mode is not supported when running multiple flows. (%s)\n", inputs)
		return 2
	}
	suite := run_suite(&c, &dev, &plan, o, device_id, debug_dir, -1)
	save_report(o, []Suite_Result{suite})
	return 0 if suite.passed else 1
}

Suite_Result :: struct {
	passed:        bool,
	flows:         [dynamic]Flow_Result,
	duration_ms:   f64,
	start_unix_ms: i64,
	device:        string,
}

// A suite: the sequence first (stopping at a failure unless
// continueOnFailure), then the other flows; a line per flow, then the summary.
run_suite :: proc(c: ^Conn, dev: ^Device, plan: ^Plan, o: ^Test_Options, device_id, debug_dir: string, shard: int) -> (s: Suite_Result) {
	prefix := fmt.tprintf("[shard %d] ", shard + 1) if shard >= 0 else ""
	cli_message(fmt.tprintf("%sWaiting for flows to complete...", prefix))
	s.passed = true
	s.device = dev.name if dev.name != "" else device_id
	s.start_unix_ms = time.to_unix_nanoseconds(time.now()) / 1_000_000
	start := time.tick_now()
	run_one :: proc(c: ^Conn, dev: ^Device, path: string, o: ^Test_Options, device_id, debug_dir, prefix: string, shard: int) -> Flow_Result {
		res := run_flow(c, dev, path, Run_Options {
			env = o.env[:], device_id = device_id, shard_index = max(shard, 0), silent = true,
			flow_dir = flow_dir(debug_dir, flow_file_name(path), shard),
		}, context.allocator)
		print_flow_line(prefix, &res)
		return res
	}
	for path in plan.sequence {
		res := run_one(c, dev, path, o, device_id, debug_dir, prefix, shard)
		append(&s.flows, res)
		if !res.passed {
			s.passed = false
			if !plan.continue_on_failure {
				cli_message(fmt.tprintf("%sFlow %s failed and continueOnFailure is set to false, aborting running sequential Flows", prefix, res.name))
				fmt.println()
				break
			}
		}
	}
	for path in plan.flows {
		res := run_one(c, dev, path, o, device_id, debug_dir, prefix, shard)
		append(&s.flows, res)
		if !res.passed do s.passed = false
	}
	s.duration_ms = f64(time.duration_milliseconds(time.tick_since(start)))

	failed := 0
	for f in s.flows do if !f.passed do failed += 1
	word :: proc(n: int) -> string { return "Flow" if n == 1 else "Flows" }
	if failed > 0 {
		fmt.printf("\n\x1b[31m\x1b[1m%s%d/%d %s Failed\x1b[0m\n", prefix, failed, len(s.flows), word(failed))
	} else {
		fmt.printf("\n\x1b[92m\x1b[1m%s%d/%d %s Passed in %s\x1b[0m\n", prefix, len(s.flows), len(s.flows), word(len(s.flows)), display_duration(s.duration_ms))
	}
	fmt.println()
	return s
}

// "[Passed] name (12s)" / "[Failed] name (3s) (error)", as TestSuiteStatusView prints them.
print_flow_line :: proc(prefix: string, r: ^Flow_Result) {
	if prefix != "" do fmt.printf("\x1b[36m%s\x1b[39m", prefix)
	if r.passed {
		fmt.printf("\x1b[92m[Passed]\x1b[39m %s (%s)\n", r.name, display_duration(r.duration_ms))
		return
	}
	first, _, _ := strings.partition(r.error, "\n")
	fmt.printf("\x1b[91m[Failed]\x1b[39m %s (%s)", r.name, display_duration(r.duration_ms))
	if first != "" do fmt.printf("\x1b[31m (%s)\x1b[39m", first)
	fmt.println()
}

// TimeUtils.forDisplay then Kotlin's Duration.toString: under a second as is ("850ms"), else
// rounded to seconds ("12s", "1m 5s", "1h 0m 5s").
display_duration :: proc(ms: f64) -> string {
	if ms < 1000 do return fmt.tprintf("%dms", int(ms))
	total := int(ms / 1000 + 0.5)
	h, m, sec := total / 3600, total % 3600 / 60, total % 60
	switch {
	case h > 0:
		if sec > 0 do return fmt.tprintf("%dh %dm %ds", h, m, sec)
		if m > 0 do return fmt.tprintf("%dh %dm", h, m)
		return fmt.tprintf("%dh", h)
	case m > 0:
		if sec > 0 do return fmt.tprintf("%dm %ds", m, sec)
		return fmt.tprintf("%dm", m)
	}
	return fmt.tprintf("%ds", sec)
}

// TestDebugReporter: flattened, the debug output (or the home folder) itself; otherwise a
// timestamped folder under --test-output-dir / the config's testOutputDir, under
// <debug-output>/.maestro/tests, or under ~/.maestro/tests ($XDG_STATE_HOME/maestro/tests).
debug_output_path :: proc(o: ^Test_Options, plan: ^Plan) -> string {
	home := os.get_env("HOME", context.allocator)
	if o.flatten do return absolute(o.debug_output if o.debug_output != "" else home)
	y, mon, d, hh, mm, ss := local_time(time.to_unix_nanoseconds(time.now()) / 1_000_000)
	folder := fmt.tprintf("%04d-%02d-%02d_%02d%02d%02d", y, mon, d, hh, mm, ss)
	out_dir := o.test_output_dir if o.test_output_dir != "" else plan.config.test_output_dir
	switch {
	case out_dir != "":
		return fmt.aprintf("%s/%s", absolute(out_dir), folder)
	case o.debug_output != "":
		return fmt.aprintf("%s/.maestro/tests/%s", absolute(o.debug_output), folder)
	}
	if xdg := os.get_env("XDG_STATE_HOME", context.allocator); xdg != "" do return fmt.aprintf("%s/maestro/tests/%s", xdg, folder)
	return fmt.aprintf("%s/.maestro/tests/%s", home, folder)
}

// The local date and time of a Unix time in milliseconds.
local_time :: proc(unix_ms: i64) -> (year, month, day, hour, minute, second: int) {
	t := libc.time_t(unix_ms / 1000)
	tm := libc.localtime(&t)
	if tm == nil do return
	return int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday), int(tm.tm_hour), int(tm.tm_min), int(tm.tm_sec)
}

// A flow's own folder in the debug output (TestDebugReporter.createFlowDir): its name, with
// -shard-N when sharded and -N on a name collision.
flow_dir :: proc(debug_dir, name: string, shard: int) -> string {
	if debug_dir == "" do return ""
	base := strings.concatenate({debug_dir, "/", name}) if shard < 0 else fmt.aprintf("%s/%s-shard-%d", debug_dir, name, shard + 1)
	candidate := base
	for n := 2; os.exists(candidate); n += 1 do candidate = fmt.aprintf("%s-%d", base, n)
	return candidate
}

cli_message :: proc(msg: string) {
	fmt.printf("\x1b[36m\n%s\x1b[0m\n", msg)
}

cli_error :: proc(msg: string) {
	fmt.eprintf("\n\x1b[31m%s\x1b[0m\n", msg)
}

cli_warning :: proc(msg: string) {
	fmt.printf("\n\x1b[33m%s\x1b[0m\n", msg)
}

// Continuous mode (`-c`, TestRunner.runContinuous): run the flow, then again whenever the
// flow file or a file it runs changes, or on Enter; until Ctrl-C.
run_continuous :: proc(c: ^Conn, dev: ^Device, path: string, o: ^Test_Options, device_id: string) -> int {
	tty := os.is_tty(os.stdout)
	for {
		if tty do fmt.print("\x1b[H\x1b[2J") // each run from the top
		fmt.println("> Press [ENTER] to restart the Flow\n")
		run_flow(c, dev, path, Run_Options{env = o.env[:], device_id = device_id, plain = o.plain}, context.allocator)
		watched := watch_files(path)
		before := make([]time.Time, len(watched))
		for f, k in watched do before[k] = modified(f)
		wait: for {
			pfd := posix.pollfd{fd = posix.STDIN_FILENO, events = {.IN}}
			if posix.poll(&pfd, 1, 300) > 0 {
				line: [256]u8
				if posix.read(posix.STDIN_FILENO, raw_data(line[:]), len(line)) <= 0 do return 0 // stdin closed
				break wait
			}
			for f, k in watched do if modified(f) != before[k] do break wait
		}
	}

	watch_files :: proc(path: string) -> []string {
		flow, _ := load_flow(path, context.allocator)
		if len(flow.files) == 0 {
			out := make([]string, 1)
			out[0] = path
			return out
		}
		return flow.files[:]
	}
	modified :: proc(path: string) -> time.Time {
		info, err := os.stat(path, context.temp_allocator)
		return info.modification_time if err == nil else {}
	}
}

Shard_Device :: struct {
	id, platform: string,
}

// Connected Android devices (adb) and booted iOS simulators, of the platform when given.
connected_devices :: proc(platform: string) -> (out: [dynamic]Shard_Device) {
	if platform == "" || platform == "android" {
		if text, ok := adb("devices"); ok {
			for line in strings.split_lines(text) {
				serial, _, state := strings.partition(line, "\t")
				if strings.trim_space(state) == "device" do append(&out, Shard_Device{serial, "android"})
			}
		}
	}
	if platform == "" || platform == "ios" {
		for sim in booted_simulators() do append(&out, Shard_Device{strings.clone(sim.udid), "ios"})
	}
	return
}

// --shard-split / --shard-all: one speedrun per device, each
// running its share of the flows as a suite; then their results merged into one report.
run_shards :: proc(o: ^Test_Options, plan: ^Plan, requested: int, debug_dir: string) -> int {
	all := connected_devices(o.platform)
	devices: [dynamic]Shard_Device
	if len(o.devices) > 0 {
		for id in o.devices {
			found := false
			for d in all do if d.id == id {
				append(&devices, d)
				found = true
			}
			if !found {
				cli_error(fmt.tprintf("Device %s was requested, but it is not connected.", id))
				return 1
			}
		}
	} else {
		devices = all
	}
	if missing := requested - len(devices); missing > 0 {
		cli_warning(fmt.tprintf("You have %d devices connected, which is not enough to run %d shards. Missing %d device(s).", len(devices), requested, missing))
		cli_error(fmt.tprintf("Not enough devices connected (%d) to run the requested number of shards (%d).", len(devices), requested))
		return 1
	}
	flows := plan.flows[:]
	effective := min(requested, len(devices)) if o.shard_all > 0 else min(requested, len(flows))
	if o.shard_all == 0 && requested > len(flows) {
		cli_warning(fmt.tprintf("Requested %d shards, but it cannot be higher than the number of flows (%d). Will use %d shards instead.", requested, len(flows), effective))
	}
	chunks := make([][dynamic]string, effective)
	for f, k in flows {
		if o.shard_all > 0 {
			for &chunk in chunks do append(&chunk, f)
		} else {
			append(&chunks[k % effective], f)
		}
	}
	if o.shard_all > 0 {
		fmt.printf("Will run %d shards, with all %d flows in each shard\n", effective, len(flows))
	} else {
		approx := "approx. " if len(flows) % effective != 0 else ""
		fmt.printf("Will split %d flows across %d shards (%s%d flows per shard)\n", len(flows), effective, approx, int(f64(len(flows)) / f64(effective) + 0.5))
	}

	exe, _ := os.get_executable_path(context.allocator)
	tmp, _ := os.temp_directory(context.allocator)
	children := make([]os.Process, effective)
	results := make([]string, effective)
	for k in 0 ..< effective {
		d := devices[k]
		results[k] = fmt.aprintf("%s/speedrun-shard-%d-%d.json", strings.trim_right(tmp, "/"), os.get_pid(), k)
		base_port := o.port if o.port_given else (IOS_PORT if d.platform == "ios" else 7777)
		args: [dynamic]string
		append(&args, exe, "test", "--shard-worker", fmt.aprintf("%d", k), "--shard-result", results[k],
			"--device", d.id, "-p", d.platform, "--port", fmt.aprintf("%d", base_port + 2 * k),
			"--debug-output", debug_dir, "--flatten-debug-output")
		if o.plain do append(&args, "--plain")
		if o.instrument do append(&args, "--instrument")
		for e in o.env do append(&args, "-e", fmt.aprintf("%s=%s", e.key, e.value))
		append(&args, ..chunks[k][:])
		p, err := os.process_start({command = args[:], stdout = os.stdout, stderr = os.stderr})
		if err != nil {
			cli_error(fmt.tprintf("could not start shard %d: %v", k + 1, err))
			return 1
		}
		children[k] = p
	}
	suites: [dynamic]Suite_Result
	passed, total := 0, 0
	for k in 0 ..< effective {
		_, _ = os.process_wait(children[k])
		data, err := os.read_entire_file(results[k], context.allocator)
		os.remove(results[k])
		suite: Suite_Result
		if err != nil || json.unmarshal(data, &suite) != nil {
			cli_error(fmt.tprintf("shard %d did not report its results", k + 1))
			suite.device = devices[k].id
		}
		append(&suites, suite)
		total += len(suite.flows)
		for f in suite.flows do if f.passed do passed += 1
	}
	save_report(o, suites[:])
	if effective > 1 {
		lines: [dynamic]string
		append(&lines, fmt.aprintf("Passed: %d/%d", passed, total))
		for s in suites {
			n := 0
			for f in s.flows do if f.passed do n += 1
			append(&lines, fmt.aprintf("[ %s ] - %d/%d", s.device, n, len(s.flows)))
		}
		cli_message(magenta_box(lines[:]))
	}
	return 0 if passed == total && total > 0 else 1
}

// A box: magenta rounded borders, 3 columns and 1 line of padding.
@(private = "file")
magenta_box :: proc(lines: []string) -> string {
	width := 0
	for l in lines do width = max(width, strings.rune_count(l))
	inner := width + 6
	m :: proc(s: string) -> string { return fmt.tprintf("\x1b[35m%s\x1b[36m", s) }
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s%s%s\n", m("╭"), m(strings.repeat("─", inner)), m("╮"))
	fmt.sbprintf(&b, "%s%s%s\n", m("│"), strings.repeat(" ", inner), m("│"))
	for l in lines do fmt.sbprintf(&b, "%s   %s%s   %s\n", m("│"), l, strings.repeat(" ", width - strings.rune_count(l)), m("│"))
	fmt.sbprintf(&b, "%s%s%s\n", m("│"), strings.repeat(" ", inner), m("│"))
	fmt.sbprintf(&b, "%s%s%s", m("╰"), m(strings.repeat("─", inner)), m("╯"))
	return strings.to_string(b)
}

// --format junit / html: report.xml / report.html, or --output.
save_report :: proc(o: ^Test_Options, suites: []Suite_Result) {
	ext := ""
	data := ""
	switch o.format {
	case .Noop:
		return
	case .Junit:
		ext, data = ".xml", junit_report(o.test_suite_name, suites)
	case .Html, .Html_Detailed:
		ext, data = ".html", html_report(suites, o.format == .Html_Detailed)
	}
	path := o.output if o.output != "" else strings.concatenate({"report", ext})
	if os.write_entire_file(path, transmute([]byte)data) != nil do cli_error(fmt.tprintf("could not write %s", path))
}

// JUnitTestSuiteReporter's XML (Jackson's pretty printer, null attributes left out).
junit_report :: proc(suite_name: string, suites: []Suite_Result) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "<?xml version='1.0' encoding='UTF-8'?>\n<testsuites>\n")
	for &s in suites {
		failures := 0
		for f in s.flows do if !f.passed do failures += 1
		fmt.sbprintf(&b, "  <testsuite name=\"%s\"", xml_escape(suite_name if suite_name != "" else "Test Suite"))
		if s.device != "" do fmt.sbprintf(&b, " device=\"%s\"", xml_escape(s.device))
		fmt.sbprintf(&b, " tests=\"%d\" failures=\"%d\" time=\"%s\" timestamp=\"%s\">\n",
			len(s.flows), failures, java_double(s.duration_ms / 1000), local_date_time(s.start_unix_ms))
		for &f in s.flows {
			junit_id, classname := f.name, f.name
			for p in f.properties {
				if p.key == "junitId" do junit_id = p.value
				if p.key == "junitClassname" do classname = p.value
			}
			fmt.sbprintf(&b, "    <testcase id=\"%s\" name=\"%s\" classname=\"%s\" file=\"%s\" time=\"%s\" timestamp=\"%s\" status=\"%s\"",
				xml_escape(junit_id), xml_escape(f.name), xml_escape(classname), xml_escape(relative_to_cwd(f.file_path)),
				java_double(f.duration_ms / 1000), local_date_time(f.start_unix_ms), "SUCCESS" if f.passed else "ERROR")
			props: [dynamic]Env_Pair
			for p in f.properties do if p.key != "junitId" && p.key != "junitClassname" do append(&props, p)
			if len(f.tags) > 0 do append(&props, Env_Pair{"tags", strings.join(f.tags, ", ")})
			if len(props) == 0 && f.passed {
				strings.write_string(&b, "/>\n")
				continue
			}
			strings.write_string(&b, ">\n")
			if len(props) > 0 {
				strings.write_string(&b, "      <properties>\n")
				for p in props do fmt.sbprintf(&b, "        <property name=\"%s\" value=\"%s\"/>\n", xml_escape(p.key), xml_escape(p.value))
				strings.write_string(&b, "      </properties>\n")
			}
			if !f.passed do fmt.sbprintf(&b, "      <failure>%s</failure>\n", xml_escape(f.error if f.error != "" else "Unknown error", attribute = false))
			strings.write_string(&b, "    </testcase>\n")
		}
		strings.write_string(&b, "  </testsuite>\n")
	}
	strings.write_string(&b, "</testsuites>\n")
	return strings.to_string(b)
}

// As Jackson writes XML: quotes are escaped in attributes only.
xml_escape :: proc(s: string, attribute := true) -> string {
	b := strings.builder_make()
	for c in s {
		switch c {
		case '&': strings.write_string(&b, "&amp;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '"':
			if attribute do strings.write_string(&b, "&quot;")
			else do strings.write_rune(&b, c)
		case:     strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)
}

// Java's Double.toString for seconds: "5.0", "12.345".
@(private = "file")
java_double :: proc(v: f64) -> string {
	s := fmt.tprintf("%.3f", v)
	s = strings.trim_right(s, "0")
	if strings.has_suffix(s, ".") do s = strings.concatenate({s, "0"}, context.temp_allocator)
	return s
}

// ISO_LOCAL_DATE_TIME in the local zone, truncated to seconds.
@(private = "file")
local_date_time :: proc(unix_ms: i64) -> string {
	y, mon, d, hh, mm, ss := local_time(unix_ms)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d", y, mon, d, hh, mm, ss)
}

@(private = "file")
relative_to_cwd :: proc(path: string) -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	if strings.has_prefix(path, strings.concatenate({cwd, "/"}, context.temp_allocator)) do return path[len(cwd) + 1:]
	return path
}
