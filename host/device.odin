// The device side of a run: copies the agent (embedded in this binary) to the device, starts
// it as the shell user (or, failing that, as an instrumentation), forwards its port, and stops
// it again on exit or Ctrl-C. Everything goes through the `adb` binary.
package speedrun

import "base:runtime"
import "core:fmt"
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

Device :: struct {
	port:       int,
	instrument: bool, // the agent runs as an instrumentation (UiAutomation injection)
	adb:        os.Process, // the `adb shell` the agent runs under
	running:    bool,
	forwarded:  bool,
	local_apk:  string, // the embedded APK written to a temp file, for `adb push`/`install`
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

// Starts the agent and forwards its port; the caller then connects. Prints why when the shell
// agent cannot start and the instrumentation takes over.
device_start :: proc(d: ^Device, verbose := false) -> (err: string) {
	current = d
	posix.signal(.SIGINT, on_signal)
	posix.signal(.SIGTERM, on_signal)

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
