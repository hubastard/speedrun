// The device side of a run, then stopped again on exit or Ctrl-C.
// Android: copies the agent (embedded in this binary) to the device, starts it as the shell user
// (or, failing that, as an instrumentation) and forwards its port, all through `adb`.
// iOS (simulators): starts the agent's XCUITest runner, built by build.sh next to this binary,
// with `xcodebuild test-without-building`; a simulator shares the Mac's loopback, so the host
// connects straight to it. App control goes through `xcrun simctl`, as Maestro's does.
package speedrun

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// build.sh builds the APK before this binary.
AGENT_APK :: #load("../agent/android/app/build/outputs/apk/debug/app-debug.apk")
AGENT_APK_CRC :: #load_hash("../agent/android/app/build/outputs/apk/debug/app-debug.apk", "crc32")
AGENT_PACKAGE :: "com.speedrun.agent"
AGENT_NAME :: "speedrun-agent" // the shell agent's process name (app_process --nice-name)
AGENT_START_TIMEOUT :: 10 * time.Second

// Only one UiAutomation client can exist at a time: stop both kinds of agent. pidof matches
// the --nice-name command line (pkill would match comm, which is "main").
STOP_AGENTS :: "am force-stop " + AGENT_PACKAGE + "; pids=$(pidof " + AGENT_NAME + ") && kill $pids"

// Maestro's driver (an instrumentation in this package) holds the UiAutomation slot while it
// runs, and an interrupted Maestro run leaves it running on the device.
MAESTRO_DRIVER :: "dev.mobile.maestro"
STOP_MAESTRO_DRIVER ::
	"if pidof " + MAESTRO_DRIVER + " >/dev/null; then am force-stop " + MAESTRO_DRIVER + ".test; am force-stop " +
	MAESTRO_DRIVER + "; echo stopped-maestro; fi"

Platform :: enum {
	Android,
	IOS,
}

IOS_PORT :: 7778 // default: Android's 7777 is often forwarded to an emulator already
IOS_RUNNER_APP :: "com.speedrun.agent.uitests.xctrunner"
IOS_PRODUCTS :: "agent/ios/build/Build/Products" // next to the speedrun binary
IOS_START_TIMEOUT :: 90 * time.Second

Device :: struct {
	platform:   Platform,
	port:       int,
	udid:       string, // iOS: the simulator
	name:       string, // shown as "Running on <name>"
	instrument: bool, // the agent runs as an instrumentation (UiAutomation injection)
	adb:        os.Process, // the `adb shell` the agent runs under
	running:    bool,
	forwarded:  bool,
	local_apk:  string, // the embedded APK written to a temp file, for `adb push`/`install`
	runner:     os.Process, // iOS: the xcodebuild running the agent's UI test
	started:    bool, // iOS: this run started the runner (else it reused one already serving)
}

// The device adb talks to (--device); empty: adb's default (ANDROID_SERIAL, or the only one).
adb_serial: string

// The device of this run, for the Ctrl-C handler.
@(private = "file")
current: ^Device

// The adb command line for args, on the chosen device.
adb_command :: proc(args: ..string) -> []string {
	cmd := make([dynamic]string, 0, len(args) + 3, context.temp_allocator)
	append(&cmd, "adb")
	if adb_serial != "" do append(&cmd, "-s", adb_serial)
	append(&cmd, ..args)
	return cmd[:]
}

// Runs adb. out is its stdout, plus its stderr when it failed.
adb :: proc(args: ..string) -> (out: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = adb_command(..args)}, context.temp_allocator)
	if err == .Not_Exist do return "adb not found on PATH", false
	if err != nil do return fmt.tprintf("adb: %v", err), false
	if state.exited && state.exit_code == 0 do return string(stdout), true
	return strings.trim_space(strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator)), false
}

// Leaves the device ready for a UiAutomation client: animations off (as for any UI test) and
// no agent of an earlier run left holding the UiAutomation slot. Copies of other agent builds
// are deleted; present reports whether this build's is already there.
device_prepare :: proc() -> (present: bool, err: string) {
	script := strings.concatenate({
		"settings put global window_animation_scale 0; settings put global transition_animation_scale 0; ",
		"settings put global animator_duration_scale 0; ", STOP_AGENTS, "; ", STOP_MAESTRO_DRIVER, "; ",
		"for f in /data/local/tmp/speedrun-agent-*.apk; do ",
		`[ "$f" = `, device_apk(), ` ] && echo present || rm -f "$f"; done`,
	}, context.temp_allocator)
	out, ok := adb("shell", script)
	if !ok && strings.contains(out, "more than one device") {
		return false, strings.concatenate({out, "\nPick one with --device <serial> (see `adb devices`)."}, context.temp_allocator)
	}
	if !ok do return false, out
	if strings.contains(out, "stopped-maestro") {
		fmt.eprintln("Stopped Maestro's driver, left running on the device by an earlier Maestro run: it held the UiAutomation slot.")
	}
	return strings.contains(out, "present"), ""
}

// The agent on the device, named by content so a rebuilt agent is pushed again.
device_apk :: proc() -> string {
	return fmt.tprintf("/data/local/tmp/speedrun-agent-%08x.apk", AGENT_APK_CRC)
}

// Picks the platform and the device. --platform and --device win; otherwise a connected
// Android device, else the one booted simulator.
device_select :: proc(d: ^Device, platform, device: string, port_given: bool) -> (err: string) {
	sims := booted_simulators()
	is_sim :: proc(sims: []Simulator, id: string) -> (Simulator, bool) {
		for s in sims do if s.udid == id do return s, true
		return {}, false
	}
	switch platform {
	case "android":
		d.platform = .Android
	case "ios":
		d.platform = .IOS
	case "":
		if device != "" {
			_, sim := is_sim(sims, device)
			d.platform = .IOS if sim else .Android
		} else if out, ok := adb("devices"); ok && strings.count(out, "\tdevice") > 0 {
			d.platform = .Android
		} else if len(sims) > 0 {
			d.platform = .IOS
		} else {
			return "No device: connect an Android device or emulator (adb devices), or boot an iOS simulator."
		}
	case:
		return fmt.tprintf("--platform takes android or ios, not %s", platform)
	}
	if d.platform == .Android {
		adb_serial = device
		return ""
	}
	if !port_given do d.port = IOS_PORT
	switch {
	case device != "":
		sim, ok := is_sim(sims, device)
		if !ok do return fmt.tprintf("Simulator %s is not booted (xcrun simctl boot %s); real iOS devices are not supported yet.", device, device)
		d.udid, d.name = sim.udid, sim.name
	case len(sims) == 1:
		d.udid, d.name = sims[0].udid, sims[0].name
	case len(sims) == 0:
		return "No booted iOS simulator (xcrun simctl boot <udid>)."
	case:
		names := make([dynamic]string, context.temp_allocator)
		for s in sims do append(&names, fmt.tprintf("%s (%s)", s.name, s.udid))
		return fmt.tprintf("Several simulators are booted: pick one with --device <udid>:\n  %s", strings.join(names[:], "\n  ", context.temp_allocator))
	}
	return ""
}

Simulator :: struct {
	udid, name: string,
}

// Booted simulators, from `xcrun simctl list devices booted` ("    iPhone 17 Pro (UDID) (Booted)").
booted_simulators :: proc() -> []Simulator {
	out, ok := simctl("list", "devices", "booted")
	if !ok do return nil
	sims := make([dynamic]Simulator, context.temp_allocator)
	for line in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(line)
		if !strings.has_suffix(l, "(Booted)") do continue
		l = strings.trim_space(l[:len(l) - len("(Booted)")])
		i := strings.last_index(l, " (")
		if i < 0 || !strings.has_suffix(l, ")") do continue
		append(&sims, Simulator{udid = l[i + 2:len(l) - 1], name = l[:i]})
	}
	return sims[:]
}

// Runs `xcrun simctl args`. out is its stdout, plus its stderr when it failed.
simctl :: proc(args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, 0, len(args) + 2, context.temp_allocator)
	append(&cmd, "xcrun", "simctl")
	append(&cmd, ..args)
	state, stdout, stderr, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil do return fmt.tprintf("xcrun: %v (Xcode command-line tools)", err), false
	if state.exited && state.exit_code == 0 do return string(stdout), true
	return strings.trim_space(strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator)), false
}

// Starts the agent (and on Android forwards its port); the caller then connects. Prints why
// when the Android shell agent cannot start and the instrumentation takes over.
device_start :: proc(d: ^Device, verbose := false) -> (err: string) {
	current = d
	posix.signal(.SIGINT, on_signal)
	posix.signal(.SIGTERM, on_signal)
	if d.platform == .IOS do return ios_start(d)

	present, perr := device_prepare()
	if perr != "" do return perr
	if !d.instrument {
		if !present {
			if e := write_local_apk(d); e != "" do return e
			if out, ok := adb("push", d.local_apk, device_apk()); !ok do return out
		}
		log, ok := start_shell_agent(d)
		if verbose && ok {
			for l in strings.split_lines(strings.trim_space(log), context.temp_allocator) do fmt.printf("  agent: %s\n", l)
		}
		// Another client holds the device's only UiAutomation slot: the instrumentation would
		// hit the same wall, so say who to stop instead of falling back.
		if !ok && strings.contains(log, "already registered") {
			stop_agent(d)
			return "Another UiAutomation client is running on the device (a test tool, uiautomator, an instrumentation); only one can run at a time. Stop it and retry."
		}
		if !ok {
			fmt.eprintln("The shell agent did not start. Its output, then the end of logcat:")
			fmt.eprintln(indent(log))
			lc, _ := adb("logcat", "-d", "-t", "8", "-s", "SpeedrunAgent:*", "AndroidRuntime:E", "appproc:*")
			fmt.eprintln(indent(lc))
			fmt.eprintln("Falling back to the instrumentation agent (~60 ms slower per action).")
			stop_agent(d)
			d.instrument = true
		}
	}
	if d.instrument {
		if e := write_local_apk(d); e != "" do return e
		if out, ok := adb("install", "-r", d.local_apk); !ok do return out
		cmd := fmt.tprintf("am instrument -w --no-hidden-api-checks -e port %d %s/.AgentInstrumentation", d.port, AGENT_PACKAGE)
		p, err := os.process_start({command = adb_command("shell", cmd)})
		if err != nil do return fmt.tprintf("could not run adb: %v", err)
		d.adb, d.running = p, true
	}
	port := fmt.tprintf("tcp:%d", d.port)
	if out, ok := adb("forward", port, port); !ok do return out
	d.forwarded = true
	return ""
}

// Stops the agent, removes the port forward and the temp APK. Safe to call twice.
device_stop :: proc(d: ^Device) {
	if d.platform == .IOS {
		ios_stop(d)
		current = nil
		return
	}
	stop_agent(d)
	if d.forwarded {
		adb("forward", "--remove", fmt.tprintf("tcp:%d", d.port))
		d.forwarded = false
	}
	if d.local_apk != "" {
		os.remove(d.local_apk)
		d.local_apk = ""
	}
	current = nil
}

@(private = "file")
stop_agent :: proc(d: ^Device) {
	if d.running {
		_ = os.process_kill(d.adb)
		_, _ = os.process_wait(d.adb)
		d.running = false
	}
	adb("shell", STOP_AGENTS)
}

// Waits for the shell agent's "listening" line. Its output goes to a temp file, polled, so
// a start that hangs cannot block the run.
@(private = "file")
start_shell_agent :: proc(d: ^Device) -> (log: string, ok: bool) {
	f, ferr := os.create_temp_file("", "speedrun-agent-*.log")
	if ferr != nil do return fmt.tprintf("could not create a temp file: %v", ferr), false
	path := strings.clone(os.name(f), context.temp_allocator)
	defer {
		os.close(f)
		os.remove(path)
	}
	cmd := fmt.tprintf(
		"CLASSPATH=%s exec app_process / --nice-name=%s %s.ShellMain %d",
		device_apk(), AGENT_NAME, AGENT_PACKAGE, d.port,
	)
	p, err := os.process_start({command = adb_command("shell", cmd), stdout = f, stderr = f})
	if err != nil do return fmt.tprintf("could not run adb: %v", err), false
	d.adb, d.running = p, true

	start := time.tick_now()
	for {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		log = string(data)
		if strings.has_prefix(log, "listening") || strings.contains(log, "\nlistening") do return log, true
		if state, werr := os.process_wait(p, 0); werr == nil && state.exited {
			d.running = false // process_wait has released it
			return log, false
		}
		if time.tick_since(start) > AGENT_START_TIMEOUT do return log, false
		time.sleep(20 * time.Millisecond)
	}
}

@(private = "file")
write_local_apk :: proc(d: ^Device) -> string {
	if d.local_apk != "" do return ""
	f, err := os.create_temp_file("", "speedrun-agent-*.apk")
	if err != nil do return fmt.tprintf("could not create a temp file: %v", err)
	defer os.close(f)
	d.local_apk = strings.clone(os.name(f))
	if _, werr := os.write(f, AGENT_APK); werr != nil do return fmt.tprintf("could not write %s: %v", d.local_apk, werr)
	return ""
}

// The runner of an earlier run may still be serving (on Ctrl-C of an xcodebuild, for one):
// reuse it. Otherwise start one and wait until it answers.
@(private = "file")
ios_start :: proc(d: ^Device) -> string {
	if answers_ping(d.port) do return ""
	products := ios_products()
	xctestrun := ""
	if entries, err := os.read_all_directory_by_path(products, context.temp_allocator); err == nil {
		for e in entries do if strings.has_suffix(e.name, ".xctestrun") do xctestrun = e.fullpath
	}
	if xctestrun == "" do return fmt.tprintf("The iOS agent is not built (%s): run ./build.sh (it needs Xcode).", products)

	f, ferr := os.create_temp_file("", "speedrun-ios-runner-*.log")
	if ferr != nil do return fmt.tprintf("could not create a temp file: %v", ferr)
	log := strings.clone(os.name(f), context.temp_allocator)
	defer {
		os.close(f)
		os.remove(log)
	}
	environ, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(environ) + 1, context.temp_allocator)
	append(&env, ..environ)
	append(&env, fmt.tprintf("TEST_RUNNER_SPEEDRUN_PORT=%d", d.port)) // reaches the runner as SPEEDRUN_PORT
	p, err := os.process_start({
		command = {"xcodebuild", "test-without-building", "-xctestrun", xctestrun, "-destination", fmt.tprintf("id=%s", d.udid)},
		env = env[:], stdout = f, stderr = f,
	})
	if err != nil do return fmt.tprintf("could not run xcodebuild: %v", err)
	d.runner, d.started = p, true

	start := time.tick_now()
	for time.tick_since(start) < IOS_START_TIMEOUT {
		if answers_ping(d.port) do return ""
		if state, werr := os.process_wait(p, 0); werr == nil && state.exited {
			d.started = false
			data, _ := os.read_entire_file(log, context.temp_allocator)
			return fmt.tprintf("The iOS agent did not start. The end of xcodebuild's output:\n%s", indent(tail(string(data), 15)))
		}
		time.sleep(100 * time.Millisecond)
	}
	ios_stop(d)
	return fmt.tprintf("The iOS agent did not answer within %v.", IOS_START_TIMEOUT)
}

// Ends the test run this process started; a runner it reused keeps serving.
@(private = "file")
ios_stop :: proc(d: ^Device) {
	if !d.started do return
	_ = os.process_terminate(d.runner)
	for _ in 0 ..< 30 {
		if state, err := os.process_wait(d.runner, 0); err == nil && state.exited do break
		time.sleep(100 * time.Millisecond)
	}
	_ = os.process_kill(d.runner)
	_, _ = os.process_wait(d.runner, 0)
	simctl("terminate", d.udid, IOS_RUNNER_APP)
	d.started = false
}

// Where build.sh puts the runner: agent/ios/build next to the speedrun binary.
@(private = "file")
ios_products :: proc() -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do dir = "."
	return strings.concatenate({dir, "/", IOS_PRODUCTS}, context.temp_allocator)
}

// An agent serving on 127.0.0.1:port (it answers PING).
@(private = "file")
answers_ping :: proc(port: int) -> bool {
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil do return false
	defer net.close(sock)
	c := Conn{sock = sock}
	defer delete(c.buf)
	_, ok := op_ping(&c)
	return ok
}

@(private = "file")
tail :: proc(s: string, n: int) -> string {
	lines := strings.split_lines(strings.trim_space(s), context.temp_allocator)
	return strings.join(lines[max(len(lines) - n, 0):], "\n", context.temp_allocator)
}

@(private = "file")
indent :: proc(s: string) -> string {
	lines := strings.split_lines(strings.trim_space(s), context.temp_allocator)
	for &l in lines do l = strings.concatenate({"    ", l}, context.temp_allocator)
	return strings.join(lines, "\n", context.temp_allocator)
}

// Ctrl-C: leave the device as it was found (no agent holding the UiAutomation slot, which
// would block the next tool), then exit.
@(private = "file")
on_signal :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	os.write_string(os.stdout, "\x1b[0m\n")
	if current != nil do device_stop(current)
	os.exit(130)
}
