// The device side of a run, then stopped again on exit or Ctrl-C.
// Android: copies the agent (embedded in this binary) to the device, starts it as the shell user
// (or, failing that, as an instrumentation) and forwards its port, all through `adb`.
// iOS (simulators): starts the agent's XCUITest runner, built by build.sh next to this binary,
// with `xcodebuild test-without-building`; a simulator shares the Mac's loopback, so the host
// connects straight to it. Starting it takes seconds, so it outlives the run (in its own
// session, stopping itself after SPEEDRUN_IDLE_S idle seconds) and the next run reuses it if
// it runs this build on the chosen simulator. App control goes through `xcrun simctl`.
package speedrun

import "base:intrinsics"
import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// build.sh builds the APK before this binary, unless SPEEDRUN_NO_ANDROID=1 (an iOS-only
// build, for CI: no JDK, no Gradle), which builds it without one (-define:ANDROID_AGENT=false).
ANDROID_AGENT :: #config(ANDROID_AGENT, true)
when ANDROID_AGENT {
	AGENT_APK :: #load("../agent/android/app/build/outputs/apk/debug/app-debug.apk")
	AGENT_APK_CRC :: #load_hash("../agent/android/app/build/outputs/apk/debug/app-debug.apk", "crc32")
} else {
	AGENT_APK :: []u8{}
	AGENT_APK_CRC :: 0
}
// build.sh embeds the iOS agent when Xcode is installed, with its content's hash
// (-define:IOS_AGENT_ID=...): the test run file and the runner app, packed (tar.gz), which
// ios_products unpacks on first use.
IOS_AGENT_ID :: #config(IOS_AGENT_ID, "")
when IOS_AGENT_ID != "" {
	IOS_AGENT_ARCHIVE :: #load("../agent/ios/build/agent.tar.gz")
} else {
	IOS_AGENT_ARCHIVE :: []u8{}
}
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
	Web, // Chrome (web.odin)
}

// The platform as reports and logs title it.
platform_title :: proc(p: Platform) -> string {
	switch p {
	case .Android: return "Android"
	case .IOS:     return "iOS"
	case .Web:     return "Web"
	}
	return ""
}

// The platform as flows (`when: platform:`), --platform and messages name it.
platform_name :: proc(p: Platform) -> string {
	switch p {
	case .Android: return "android"
	case .IOS:     return "ios"
	case .Web:     return "web"
	}
	return ""
}

IOS_PORT :: 7778 // default: Android's 7777 is often forwarded to an emulator already
IOS_RUNNER_APP :: "com.speedrun.agent.uitests.xctrunner"
AGENT_PING_TIMEOUT :: 5 * time.Second // device_restart: an agent that does not answer by then is started again
// In the test run file's name (SpeedrunAgent_iphonesimulator<SDK>-<archs>.xctestrun), on a
// runner's xcodebuild command line.
IOS_XCTESTRUN_MARK :: "SpeedrunAgent_iphonesimulator"
IOS_AGENT_FOLDER :: "ios-agent-" // + IOS_AGENT_ID, in the user's cache
// A just-booted CI simulator took 37-78 s to start the runner, and over 90 s in 4 of 5 runs
// on a busy day.
IOS_START_TIMEOUT :: 4 * time.Minute

Device :: struct {
	platform:   Platform,
	port:       int,
	udid:       string, // iOS: the simulator
	name:       string, // shown as "Running on <name>"
	instrument: bool, // the agent runs as an instrumentation (UiAutomation injection)
	adb:        os.Process, // the `adb shell` the agent runs under
	running:    bool,
	forwarded:  bool,
	local_port: int, // Android: the port on this machine forwarded to the agent's (agent_port)
	local_apk:  string, // the embedded APK written to a temp file, for `adb push`/`install`
	runner:     os.Process, // iOS: the xcodebuild running the agent's UI test
	started:    bool, // iOS: this run is starting the runner (else it reuses one already serving)
	serving:    bool, // iOS: the runner this run started answered (it stays up for the next run)
	warm:       bool, // iOS: a runner of this build serves this simulator already
	motion:     Maybe(bool), // iOS: Reduce Motion as this run left it (ios_motion_start)
	motion_was: Maybe(bool), // iOS: as it was before this run changed it, restored by device_stop
	motion_writer:  os.Process, // iOS: the `defaults write` setting it, while motion_writing
	motion_writing: bool,
	scales_was:     string, // Android: the three animation scales as found (device_prepare), "" when as wanted
	keys_on:        bool, // Android: this run turned the key service on (key_service_on)
	a11y_was:       string, // Android: accessibility_enabled as found, when the key service changed it
}

// The device adb talks to (--device); empty: adb's default (ANDROID_SERIAL, or the only one).
adb_serial: string

// --animations: how the device runs animations during a run or a session. Each platform has
// its default: Android's off, iOS apps' 10x faster, the web's as pages run them.
//   off:    Android's animation scales at 0; iOS: Reduce Motion on, and 10x faster; the web:
//           prefers-reduced-motion, and the page's animations 100x faster.
//   fast:   Android's scales at 0.1; iOS apps 10x faster; the web's animations 10x faster.
//   normal: Android's scales at 1; iOS apps at UIKit's own speed; the web as pages run it.
// Android's scales and iOS's Reduce Motion are put back as they were found at the end.
// default: each platform's default, as without --animations.
Animations :: enum u8 {
	Default,
	Off,
	Fast,
	Normal,
}

animations: Animations

ANIMATIONS_USAGE :: "--animations takes off, fast, normal or default"

parse_animations :: proc(s: string) -> (a: Animations, ok: bool) {
	switch s {
	case "off":    return .Off, true
	case "fast":   return .Fast, true
	case "normal": return .Normal, true
	case "default": return .Default, true
	}
	return .Default, false
}

animations_name :: proc(a: Animations) -> string {
	switch a {
	case .Off:     return "off"
	case .Fast:    return "fast"
	case .Normal:  return "normal"
	case .Default:
	}
	return "default"
}

// The animations a platform runs with: --animations, else its default.
animations_for :: proc(p: Platform) -> Animations {
	if animations != .Default do return animations
	switch p {
	case .Android: return .Off
	case .IOS:     return .Fast
	case .Web:     return .Normal
	}
	return .Normal
}

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

// The animation scales speedrun turns off for a run and puts back afterwards (device_stop).
@(private = "file")
ANIMATION_SCALES :: [3]string{"window_animation_scale", "transition_animation_scale", "animator_duration_scale"}

// Leaves the device ready for a UiAutomation client: the animation scales --animations wants
// (off by default, as for any UI test; as they were found kept in d.scales_was) and no agent
// of an earlier run left holding the UiAutomation slot. Copies of other agent builds are
// deleted; present reports whether this build's is already there.
device_prepare :: proc(d: ^Device) -> (present: bool, err: string) {
	if !ANDROID_AGENT {
		return false, "This speedrun was built for iOS only (SPEEDRUN_NO_ANDROID=1), without its Android agent: build it with ./build.sh."
	}
	scale := android_scale()
	script := strings.concatenate({
		"echo serialno $(getprop ro.boot.serialno); ",
		"echo scales $(settings get global window_animation_scale) $(settings get global transition_animation_scale) ",
		"$(settings get global animator_duration_scale); ",
		"settings put global window_animation_scale ", scale, "; settings put global transition_animation_scale ", scale,
		"; settings put global animator_duration_scale ", scale, "; ",
		STOP_AGENTS, "; ", STOP_MAESTRO_DRIVER, "; ",
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
	for line in strings.split_lines(out, context.temp_allocator) {
		if !strings.has_prefix(line, "serialno ") do continue
		if v, old := leaky_emulator(strings.trim_space(line[len("serialno "):])); old && !warned_emulator {
			warned_emulator = true
			fmt.eprintfln("\x1b[33mWarning: this Android emulator (%s) leaks memory on the computer each time an app's process ends, about 40 MB a time. A test run restarts the app often: the emulator grows by gigabytes, then the computer stalls (minutes-long freezes, \"isn't responding\" dialogs, failed flows). Emulator 37.2.13 fixes it (https://issuetracker.google.com/568480829): update it (sdkmanager --install emulator, or Android Studio's SDK Manager) and restart the emulator.\x1b[0m", v)
		}
	}
	// "scales 1 1 1" ("null" for one never set, which Android reads as 1). Already as wanted:
	// nothing to put back. A run that prepares twice (bench) keeps what the first found.
	for line in strings.split_lines(out, context.temp_allocator) {
		if !strings.has_prefix(line, "scales ") do continue
		scales := strings.trim_space(line[len("scales "):])
		want := strconv.parse_f64(scale) or_else 0
		as_wanted := true
		for v in strings.fields(scales, context.temp_allocator) {
			f, ok := strconv.parse_f64(v)
			if v == "null" do f, ok = 1, true
			if !ok || f != want do as_wanted = false
		}
		if d.scales_was == "" && !as_wanted do d.scales_was = strings.clone(scales)
	}
	return strings.contains(out, "present"), ""
}

// Emulators before 37.2.13 leak host memory each time a guest process exits (graphics
// contexts, surfaces and frame buffers left allocated: issue 568480829). Measured on 37.2.12:
// ~40 MB a killed app (launchApp stops the app, clearState kills it), the emulator at 11 GB
// after a day of suites on a 16 GB Mac, then macOS compressing it, and minutes-long freezes.
// An emulator's serial number carries its version: EMULATOR37X2X12X0.
@(private = "file")
warned_emulator := false

@(private = "file")
leaky_emulator :: proc(serial: string) -> (version: string, old: bool) {
	if !strings.has_prefix(serial, "EMULATOR") do return "", false
	parts := strings.split(serial[len("EMULATOR"):], "X", context.temp_allocator)
	if len(parts) < 3 do return "", false
	v: [3]int
	for i in 0 ..< 3 {
		n, ok := strconv.parse_int(parts[i])
		if !ok do return "", false
		v[i] = n
	}
	version = fmt.tprintf("%d.%d.%d", v[0], v[1], v[2])
	fixed := [3]int{37, 2, 13}
	for i in 0 ..< 3 do if v[i] != fixed[i] do return version, v[i] < fixed[i]
	return version, false
}

// Android's animation scale for --animations.
@(private = "file")
android_scale :: proc() -> string {
	#partial switch animations_for(.Android) {
	case .Fast:   return "0.1"
	case .Normal: return "1"
	}
	return "0"
}

// The shell commands that put the animation scales back as device_prepare found them.
@(private = "file")
restore_scales :: proc(d: ^Device) -> string {
	if d.scales_was == "" do return ""
	b := strings.builder_make(context.temp_allocator)
	keys := ANIMATION_SCALES
	for v, i in strings.fields(d.scales_was, context.temp_allocator) {
		if i >= len(keys) do break
		key := keys[i]
		// Each value is a number or "null" from settings get: nothing else goes into the shell.
		if v == "null" {
			fmt.sbprintf(&b, "settings delete global %s > /dev/null; ", key)
		} else if _, ok := strconv.parse_f64(v); ok {
			fmt.sbprintf(&b, "settings put global %s %s; ", key, v)
		}
	}
	delete(d.scales_was)
	d.scales_was = ""
	return strings.to_string(b)
}

// The agent's key service (KeyService.kt), which sends Backspace through the focused field's
// input connection, as a keyboard does: on Android 13 and later, the APK is installed (once a
// build) and the service turned on for the run, and off again by device_stop. Where it cannot
// be, keys are injected as before, so a failure is only logged.
KEY_SERVICE :: AGENT_PACKAGE + "/.KeyService"

@(private = "file")
key_service_on :: proc(d: ^Device, verbose: bool) {
	// Right after an install, the system can drop the service from the list (it read the list
	// before it knew the package's service): until it is bound, it is put back. It can also
	// skip one still listed ("disallowed by AppOps", the package not known there yet), and
	// one skipped while the agent was replaced stayed unbound for a whole run, once in ~10
	// (the setting unchanged, nothing reads it again): every 0.5 s unbound, it is taken out
	// of the list and put back. Concatenated, not formatted: fmt reads the shell's braces.
	apk := device_apk()
	script := strings.concatenate({
		`[ "$(getprop ro.build.version.sdk)" -ge 33 ] || exit 0; new=0; `,
		`i=$(cmd package path `, AGENT_PACKAGE, ` 2>/dev/null | head -n 1); i=${i#package:}; `,
		`if [ -z "$i" ] || ! cmp -s "$i" `, apk, `; then cmd package install -r -t `, apk, ` > /dev/null || exit 1; new=1; fi; `,
		`on() { s=$(cmd settings get secure enabled_accessibility_services); case ":$s:" in *:`, KEY_SERVICE, `:*) return;; esac; `,
		`if [ -z "$s" ] || [ "$s" = null ]; then s=`, KEY_SERVICE, `; else s="$s:`, KEY_SERVICE, `"; fi; `,
		`cmd settings put secure enabled_accessibility_services "$s"; }; `,
		`off() { s=$(cmd settings get secure enabled_accessibility_services | tr ':' '\n' | grep -vx '`, KEY_SERVICE, `' | paste -s -d : -); `,
		`if [ -z "$s" ] || [ "$s" = null ]; then cmd settings delete secure enabled_accessibility_services > /dev/null; `,
		`else cmd settings put secure enabled_accessibility_services "$s"; fi; }; `,
		`echo "a11y $(cmd settings get secure accessibility_enabled)"; on; cmd settings put secure accessibility_enabled 1; `,
		`n=0; while [ $new = 1 ] && [ $n -lt 30 ] && ! dumpsys accessibility | grep -q 'Speedrun keys'; do sleep 0.1; `,
		`if [ $((n % 5)) = 4 ]; then off; fi; on; n=$((n + 1)); done`,
	}, context.temp_allocator)
	out, ok := adb("shell", script)
	if !ok {
		if verbose do fmt.printf("  the key service could not be turned on: %s\n", strings.trim_space(out))
		return
	}
	for line in strings.split_lines(out, context.temp_allocator) {
		if !strings.has_prefix(line, "a11y ") do continue
		d.keys_on = true
		if was := strings.trim_space(line[len("a11y "):]); was != "1" do d.a11y_was = strings.clone(was)
	}
}

// The shell commands that turn the key service off again, as key_service_on found things.
@(private = "file")
key_service_off :: proc(d: ^Device) -> string {
	if !d.keys_on do return ""
	d.keys_on = false
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b,
		`s=$(cmd settings get secure enabled_accessibility_services | tr ':' '\n' | grep -vx '%s' | paste -s -d : -); ` +
		`if [ -z "$s" ] || [ "$s" = null ]; then cmd settings delete secure enabled_accessibility_services > /dev/null; ` +
		`else cmd settings put secure enabled_accessibility_services "$s"; fi; `,
		KEY_SERVICE,
	)
	switch d.a11y_was {
	case "":
	case "null": strings.write_string(&b, "cmd settings delete secure accessibility_enabled > /dev/null; ")
	case "0":    strings.write_string(&b, "cmd settings put secure accessibility_enabled 0; ")
	}
	if d.a11y_was != "" do delete(d.a11y_was)
	d.a11y_was = ""
	return strings.to_string(b)
}

// The agent on the device, named by content so a rebuilt agent is pushed again.
device_apk :: proc() -> string {
	return fmt.tprintf("/data/local/tmp/speedrun-agent-%08x.apk", AGENT_APK_CRC)
}

// Picks the platform and the device. --platform and --device win; otherwise a connected
// Android device, else the one booted simulator.
device_select :: proc(d: ^Device, platform, device: string, port_given: bool) -> (err: string) {
	ios_port := d.port if port_given else IOS_PORT
	is_sim :: proc(sims: []Simulator, id: string) -> (Simulator, bool) {
		for s in sims do if s.udid == id do return s, true
		return {}, false
	}
	switch platform {
	case "android":
		d.platform = .Android
	case "ios":
		d.platform = .IOS
	case "web":
		d.platform = .Web
	case "":
		if device == WEB_DEVICE || device == WEB_FIREFOX {
			d.platform = .Web
		} else if device != "" {
			udid, _, _, warm := ios_info(ios_port)
			sim := warm && udid == device
			if !sim do _, sim = is_sim(booted_simulators(), device)
			d.platform = .IOS if sim else .Android
		} else if !ANDROID_AGENT {
			d.platform = .IOS // an iOS-only build
		} else if out, ok := adb("devices"); ok && strings.count(out, "\tdevice") > 0 {
			d.platform = .Android
		} else if answers_ping(ios_port) || len(booted_simulators()) > 0 {
			d.platform = .IOS
		} else {
			return "No device: connect an Android device or emulator (adb devices), or boot an iOS simulator."
		}
	case:
		return fmt.tprintf("--platform takes android, ios or web, not %s", platform)
	}
	if d.platform == .Web {
		web_firefox = device == WEB_FIREFOX
		if device != "" && device != WEB_DEVICE && device != WEB_FIREFOX {
			return fmt.tprintf("The web runs in chromium (Chrome) or firefox, not %s.", device)
		}
		return ""
	}
	if d.platform == .Android {
		adb_serial = device
		return ""
	}
	if !port_given do d.port = IOS_PORT
	// A runner kept from an earlier run: reuse it when it runs this build on this simulator
	// (then the simulator list is not even needed), else stop it.
	if udid, name, build, ok := ios_info(d.port); ok {
		if (device == "" || device == udid) && build == ios_build_id() {
			// Heap copies: a session outlives the temp allocator its requests free.
			d.udid, d.name, d.warm = strings.clone(udid), strings.clone(name), true // name: the description, from INFO
			return ""
		}
		ios_quit(d.port)
		time.sleep(500 * time.Millisecond) // let it release the port
	}
	sims := booted_simulators()
	switch {
	case device != "":
		sim, ok := is_sim(sims, device)
		if !ok do return fmt.tprintf("Simulator %s is not booted (xcrun simctl boot %s); real iOS devices are not supported yet.", device, device)
		d.udid, d.name = strings.clone(sim.udid), strings.clone(sim.name)
	case len(sims) == 1:
		d.udid, d.name = strings.clone(sims[0].udid), strings.clone(sims[0].name)
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
	udid, name: string, // name: "<model> - <runtime> - <udid>", as "Running on" shows it
}

// Booted simulators, from `xcrun simctl list devices booted`: "-- iOS 26.2 --" headers, then
// "    iPhone 17 Pro (UDID) (Booted)".
booted_simulators :: proc() -> []Simulator {
	out, ok := simctl("list", "devices", "booted")
	if !ok do return nil
	sims := make([dynamic]Simulator, context.temp_allocator)
	runtime := ""
	for line in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "-- ") && strings.has_suffix(l, " --") {
			runtime = l[3:len(l) - 3]
			continue
		}
		if !strings.has_suffix(l, "(Booted)") do continue
		l = strings.trim_space(l[:len(l) - len("(Booted)")])
		i := strings.last_index(l, " (")
		if i < 0 || !strings.has_suffix(l, ")") do continue
		udid := l[i + 2:len(l) - 1]
		append(&sims, Simulator{udid = udid, name = simulator_description(l[:i], runtime, udid)})
	}
	return sims[:]
}

simulator_description :: proc(model, runtime, udid: string) -> string {
	if runtime == "" do return fmt.tprintf("%s - %s", model, udid)
	return fmt.tprintf("%s - %s - %s", model, runtime, udid)
}

// Runs `xcrun simctl args`. out is its stdout, plus its stderr when it failed.
simctl :: proc(args: ..string) -> (out: string, ok: bool) {
	return simctl_env(nil, ..args)
}

// simctl with this environment (nil: ours).
simctl_env :: proc(env: []string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, 0, len(args) + 2, context.temp_allocator)
	append(&cmd, "xcrun", "simctl")
	append(&cmd, ..args)
	state, stdout, stderr, err := os.process_exec({command = cmd[:], env = env}, context.temp_allocator)
	if err != nil do return fmt.tprintf("xcrun: %v (Xcode command-line tools)", err), false
	if state.exited && state.exit_code == 0 do return string(stdout), true
	return strings.trim_space(strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator)), false
}

// Starts the agent (and on Android forwards its port); the caller then connects. Prints why
// when the Android shell agent cannot start and the instrumentation takes over.
device_start :: proc(d: ^Device, verbose := false) -> (err: string) {
	if e := session_conflict(d); e != "" do return e
	current = d
	// Not blocked while its handler runs: a second Ctrl-C ends a cleanup that hangs.
	act := posix.sigaction_t{sa_handler = on_signal, sa_flags = {.RESTART, .SA_NODEFER}}
	posix.sigaction(.SIGINT, &act, nil)
	posix.sigaction(.SIGTERM, &act, nil)
	if d.platform == .IOS do return ios_start(d)
	if d.platform == .Web do return web_start(d)

	present, perr := device_prepare(d)
	if perr != "" do return perr
	if !d.instrument {
		if !present {
			if e := write_local_apk(d); e != "" do return e
			if out, ok := adb("push", d.local_apk, device_apk()); !ok do return out
		}
		key_service_on(d, verbose)
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
		cmd := fmt.tprintf("am instrument -w --no-hidden-api-checks -e port %d -e token %s %s/.AgentInstrumentation", d.port, new_agent_token(d.port), AGENT_PACKAGE)
		p, err := os.process_start({command = adb_command("shell", cmd)})
		if err != nil do return fmt.tprintf("could not run adb: %v", err)
		d.adb, d.running = p, true
	}
	// A free port on this machine, picked by adb: runs driving other devices in parallel each
	// get their own forward, and removing it at exit leaves theirs alone.
	out, ok := adb("forward", "tcp:0", fmt.tprintf("tcp:%d", d.port))
	if !ok do return out
	local, parsed := strconv.parse_int(strings.trim_space(out))
	if !parsed || local <= 0 do return fmt.tprintf("adb forward named no port: %s", strings.trim_space(out))
	d.local_port, d.forwarded = local, true
	if token, known := agent_tokens[d.port]; known do agent_tokens[local] = token // agent_dial's key
	return ""
}

// The port on this machine that reaches the agent: on Android, adb's forward to the device
// (device_start); on iOS, the agent's own (it listens on the Mac's loopback).
agent_port :: proc(d: ^Device) -> int {
	return d.local_port if d.platform == .Android && d.local_port > 0 else d.port
}

// Stops the agent, removes the port forward and the temp APK. Safe to call twice.
device_stop :: proc(d: ^Device) {
	if d.platform == .Web {
		web_stop()
		current = nil
		return
	}
	if d.platform == .IOS {
		ios_restore_motion(d)
		ios_stop(d)
		current = nil
		return
	}
	stop_agent(d, strings.concatenate({restore_scales(d), key_service_off(d)}, context.temp_allocator))
	if d.forwarded {
		adb("forward", "--remove", fmt.tprintf("tcp:%d", d.local_port))
		d.forwarded, d.local_port = false, 0
	}
	if d.local_apk != "" {
		os.remove(d.local_apk)
		d.local_apk = ""
	}
	current = nil
}

// `before`: shell commands to run in the same adb call (device_stop puts the animations back).
@(private = "file")
stop_agent :: proc(d: ^Device, before := "") {
	if d.running {
		_ = os.process_kill(d.adb)
		_, _ = os.process_wait(d.adb)
		d.running = false
	}
	adb("shell", strings.concatenate({before, STOP_AGENTS}, context.temp_allocator))
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
		"CLASSPATH=%s exec app_process / --nice-name=%s %s.ShellMain %d %s",
		device_apk(), AGENT_NAME, AGENT_PACKAGE, d.port, new_agent_token(d.port),
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

// Starts the runner unless device_select found one to reuse, and waits until it answers.
// It runs in its own session (perl's setsid), so it outlives this process and a Ctrl-C.
@(private = "file")
ios_start :: proc(d: ^Device) -> string {
	if d.warm do return ""
	products, perr := ios_products()
	if perr != "" do return perr
	xctestrun := ""
	if entries, err := os.read_all_directory_by_path(products, context.temp_allocator); err == nil {
		for e in entries do if strings.has_suffix(e.name, ".xctestrun") do xctestrun = e.fullpath
	}
	if xctestrun == "" do return fmt.tprintf("The iOS agent in %s has no test run file: delete the folder, then run again.", products)
	ios_end_runners(d.udid)

	log := ios_runner_log(d.port)
	// The previous runner's log is kept: after a lost agent (reconnect), its end says why.
	if info, serr := os.stat(log, context.temp_allocator); serr == nil && info.size > 0 {
		_ = os.rename(log, ios_runner_prev_log(d.port))
	}
	f, ferr := os.open(log, {.Write, .Create, .Trunc})
	if ferr != nil do return fmt.tprintf("could not create %s: %v", log, ferr)
	defer os.close(f)
	environ, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(environ) + 4, context.temp_allocator)
	append(&env, ..environ)
	// TEST_RUNNER_X reaches the runner as X.
	append(&env, fmt.tprintf("TEST_RUNNER_SPEEDRUN_PORT=%d", d.port))
	token := new_agent_token(d.port)
	if e := ios_save_token(d.port, token); e != "" do return e
	append(&env, fmt.tprintf("TEST_RUNNER_SPEEDRUN_TOKEN=%s", token))
	append(&env, fmt.tprintf("TEST_RUNNER_SPEEDRUN_BUILD=%s", ios_build_id()))
	if idle := os.get_env("SPEEDRUN_IDLE_S", context.temp_allocator); idle != "" {
		append(&env, fmt.tprintf("TEST_RUNNER_SPEEDRUN_IDLE_S=%s", idle))
	}
	p, err := os.process_start({
		command = {
			"perl", "-MPOSIX=setsid", "-e", "setsid(); exec @ARGV",
			"xcodebuild", "test-without-building", "-xctestrun", xctestrun, "-destination", fmt.tprintf("id=%s", d.udid),
		},
		env = env[:], stdout = f, stderr = f,
	})
	if err != nil do return fmt.tprintf("could not run xcodebuild: %v", err)
	d.runner, d.started = p, true

	start := time.tick_now()
	for time.tick_since(start) < IOS_START_TIMEOUT {
		if answers_ping(d.port) {
			d.serving = true
			return ""
		}
		if state, werr := os.process_wait(p, 0); werr == nil && state.exited {
			d.started = false
			data, _ := os.read_entire_file(log, context.temp_allocator)
			return fmt.tprintf("The iOS agent did not start. The end of xcodebuild's output:\n%s", indent(tail(string(data), 15)))
		}
		time.sleep(100 * time.Millisecond)
	}
	ios_stop(d)
	data, _ := os.read_entire_file(log, context.temp_allocator)
	return fmt.tprintf("The iOS agent did not answer within %v. The end of xcodebuild's output:\n%s", IOS_START_TIMEOUT, indent(tail(string(data), 15)))
}

// xcodebuild's output for the runner serving on port (the agent's log lines included).
ios_runner_log :: proc(port: int) -> string {
	tmp, _ := os.temp_directory(context.temp_allocator)
	return fmt.tprintf("%s/speedrun-ios-runner-%d.log", strings.trim_right(tmp, "/"), port)
}

// The runner's log before the last start (ios_start).
ios_runner_prev_log :: proc(port: int) -> string {
	tmp, _ := os.temp_directory(context.temp_allocator)
	return fmt.tprintf("%s/speedrun-ios-runner-%d.prev.log", strings.trim_right(tmp, "/"), port)
}

// After the agent's connection was lost: nothing to do if the agent answers a new one (it
// closed the old one on an error), else the agent is started again (it crashed or was
// killed). The caller connects again.
device_restart :: proc(d: ^Device) -> string {
	if answers_ping(agent_port(d), AGENT_PING_TIMEOUT) do return ""
	if d.platform == .IOS {
		simctl("terminate", d.udid, IOS_RUNNER_APP)
		d.started, d.serving, d.warm = false, false, false
		return ios_start(d) // it ends the runner's xcodebuild
	}
	device_stop(d)
	return device_start(d)
}

// Ends the xcodebuild processes that ran speedrun's runner on this simulator (ios_start's
// command line), none of them answering: xcodebuild restarts a runner that died but runs no
// test in it (testServe ran), and exits ~40 s later; meanwhile its restart takes the
// simulator's only runner from a new one.
@(private = "file")
ios_end_runners :: proc(udid: string) {
	pids := ios_runner_pids(udid)
	for pid in pids do posix.kill(posix.pid_t(pid), .SIGTERM)
	start := time.tick_now()
	for pid in pids {
		for posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK && time.tick_since(start) < 5 * time.Second {
			time.sleep(100 * time.Millisecond)
		}
	}
}

@(private = "file")
ios_runner_pids :: proc(udid: string) -> []int {
	pids := make([dynamic]int, context.temp_allocator)
	// pgrep, not ps: ps is setuid root, and process_exec's wait for it fails.
	_, out, _, err := os.process_exec({command = {"pgrep", "-lf", "xcodebuild test-without-building"}}, context.temp_allocator)
	if err != nil do return nil
	dest := fmt.tprintf("id=%s", udid)
	for line in strings.split_lines(string(out), context.temp_allocator) {
		l := strings.trim_space(line)
		if !strings.contains(l, "xcodebuild test-without-building") || !strings.contains(l, IOS_XCTESTRUN_MARK) || !strings.contains(l, dest) do continue
		sp := strings.index_byte(l, ' ')
		if sp < 0 do continue
		if pid, ok := strconv.parse_int(l[:sp]); ok do append(&pids, pid)
	}
	return pids[:]
}

// The runner stays up for the next run (it stops itself when idle). Only one that never came
// up is ended here. No ping to tell: the runner serves one client at a time, and a Ctrl-C
// comes while this run's connection is still open (the ping waited forever).
@(private = "file")
ios_stop :: proc(d: ^Device) {
	if !d.started || d.serving do return
	_ = os.process_kill(d.runner)
	_, _ = os.process_wait(d.runner, 0)
	simctl("terminate", d.udid, IOS_RUNNER_APP)
	d.started = false
}

// The agents' tokens: a connection to an agent starts with the token it was started with,
// else the agent closes it. 127.0.0.1 is shared: any app on an Android device could otherwise
// connect to its agent and run shell commands as the shell user, and any process on the Mac,
// other users' included, drive the iOS simulator. A new one each time an agent starts; the
// iOS runner outlives a run, so its token is kept in a file only its user can read.
AGENT_TOKEN_LENGTH :: 32 // the agents' TOKEN_LENGTH
agent_tokens: map[int]string // by the port this machine dials (Android: the forward's)

new_agent_token :: proc(port: int) -> string {
	key: [AGENT_TOKEN_LENGTH / 2]byte
	crypto.rand_bytes(key[:])
	token := string(hex.encode(key[:]))
	agent_tokens[port] = token
	return token
}

// ~/.speedrun/agents/ios-<port>.token, the folder and the file the user's alone.
@(private = "file")
ios_token_path :: proc(port: int) -> string {
	return fmt.tprintf("%s/.speedrun/agents/ios-%d.token", os.get_env("HOME", context.temp_allocator), port)
}

@(private = "file")
ios_save_token :: proc(port: int, token: string) -> string {
	path := ios_token_path(port)
	dir := path[:strings.last_index_byte(path, '/')]
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && err != .Exist {
		return fmt.tprintf("could not create %s: %v", dir, err)
	}
	_ = os.change_mode(dir, {.Read_User, .Write_User, .Execute_User})
	if err := os.write_entire_file(path, token, {.Read_User, .Write_User}); err != nil {
		return fmt.tprintf("could not write %s: %v", path, err)
	}
	return ""
}

// A connection to the agent on port, its token sent; false when it cannot be made. The iOS
// runner's token is read from its file when this run did not start it.
agent_dial :: proc(port: int) -> (sock: net.TCP_Socket, ok: bool) {
	token, known := agent_tokens[port]
	if !known {
		data, err := os.read_entire_file(ios_token_path(port), context.allocator)
		if err != nil || len(data) != AGENT_TOKEN_LENGTH do return
		token = string(data)
		agent_tokens[port] = token
	}
	s, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil do return
	if n, serr := net.send_tcp(s, transmute([]u8)token); serr != nil || n != len(token) {
		net.close(s)
		return
	}
	return s, true
}

// Asks the runner serving on port to stop; false when none answers.
ios_quit :: proc(port: int) -> bool {
	sock, ok := agent_dial(port)
	if !ok do return false
	defer net.close(sock)
	c := Conn{sock = sock}
	defer delete(c.buf)
	return op_quit(&c)
}

// The simulator and build of the runner serving on port; ok is false when none answers.
@(private = "file")
ios_info :: proc(port: int) -> (udid, name, build: string, ok: bool) {
	sock, dialed := agent_dial(port)
	if !dialed do return
	defer net.close(sock)
	c := Conn{sock = sock}
	defer delete(c.buf)
	return op_info(&c, context.temp_allocator)
}

// The build id a running runner must match: the embedded agent's content hash.
@(private = "file")
ios_build_id :: proc() -> string {
	return IOS_AGENT_ID
}

// The iOS agent, unpacked from this binary into the user's cache on first use, a folder per
// build (~/Library/Caches/speedrun/ios-agent-<id>), so the binary needs nothing next to it.
// Unpacking one deletes the other builds' folders, except one a runner was started from.
@(private = "file")
ios_products :: proc() -> (dir: string, err: string) {
	if IOS_AGENT_ID == "" do return "", "This speedrun was built without its iOS agent (Xcode was not installed): build it on a Mac with Xcode (./build.sh)."
	cache := fmt.tprintf("%s/Library/Caches/speedrun", os.get_env("HOME", context.temp_allocator))
	dir = fmt.tprintf("%s/%s%s", cache, IOS_AGENT_FOLDER, IOS_AGENT_ID)
	if os.exists(dir) do return dir, ""
	if e := os.make_directory_all(cache, {.Read_User, .Write_User, .Execute_User}); e != nil && e != .Exist {
		return "", fmt.tprintf("could not create %s: %v", cache, e)
	}
	// Unpacked next to it, then renamed: the folder is there whole or not at all.
	tmp, terr := os.make_directory_temp(cache, "unpacking-*", context.temp_allocator)
	if terr != nil do return "", fmt.tprintf("could not create a folder in %s: %v", cache, terr)
	archive := strings.concatenate({tmp, ".tar.gz"}, context.temp_allocator)
	defer os.remove(archive)
	if e := os.write_entire_file(archive, IOS_AGENT_ARCHIVE); e != nil {
		os.remove_all(tmp)
		return "", fmt.tprintf("could not write %s: %v", archive, e)
	}
	state, _, stderr, xerr := os.process_exec({command = {"tar", "-xzf", archive, "-C", tmp}}, context.temp_allocator)
	if xerr != nil || !state.success {
		os.remove_all(tmp)
		return "", fmt.tprintf("could not unpack the iOS agent into %s: %s", cache, strings.trim_space(string(stderr)))
	}
	if e := os.rename(tmp, dir); e != nil {
		os.remove_all(tmp)
		// Another speedrun unpacked it first.
		if !os.exists(dir) do return "", fmt.tprintf("could not move the iOS agent to %s: %v", dir, e)
	}
	entries, _ := os.read_all_directory_by_path(cache, context.temp_allocator)
	_, running, _, _ := os.process_exec({command = {"pgrep", "-lf", "xcodebuild test-without-building"}}, context.temp_allocator)
	for e in entries {
		if !strings.has_prefix(e.name, IOS_AGENT_FOLDER) || e.name == fmt.tprintf("%s%s", IOS_AGENT_FOLDER, IOS_AGENT_ID) do continue
		if strings.contains(string(running), e.fullpath) do continue
		os.remove_all(e.fullpath)
	}
	return dir, ""
}

// An agent serving on 127.0.0.1:port (it answers PING). With a timeout, an agent busy with
// another client (the iOS runner serves one at a time) counts as not answering.
@(private = "file")
answers_ping :: proc(port: int, timeout: time.Duration = 0) -> bool {
	sock, dialed := agent_dial(port)
	if !dialed do return false
	defer net.close(sock)
	if timeout > 0 && net.set_option(sock, .Receive_Timeout, timeout) != nil do return false
	c := Conn{sock = sock}
	defer delete(c.buf)
	_, ok := op_ping(&c)
	return ok
}

tail :: proc(s: string, n: int) -> string {
	lines := strings.split_lines(strings.trim_space(s), context.temp_allocator)
	return strings.join(lines[max(len(lines) - n, 0):], "\n", context.temp_allocator)
}

indent :: proc(s: string) -> string {
	lines := strings.split_lines(strings.trim_space(s), context.temp_allocator)
	for &l in lines do l = strings.concatenate({"    ", l}, context.temp_allocator)
	return strings.join(lines, "\n", context.temp_allocator)
}

// Ctrl-C: leave the device as it was found (no agent holding the UiAutomation slot, which
// would block the next tool), then exit. A second Ctrl-C while that runs exits at once (the
// cleanup runs adb, and the signal can come while the run holds a lock it needs).
@(private = "file")
interrupted: i32

@(private = "file")
on_signal :: proc "c" (sig: posix.Signal) {
	if intrinsics.atomic_exchange(&interrupted, 1) != 0 do posix._exit(130)
	context = runtime.default_context()
	os.write_string(os.stdout, "\x1b[0m\n")
	if current != nil do device_stop(current)
	os.exit(130)
}
