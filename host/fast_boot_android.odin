// speedrun fast-boot on Android: an emulator (an AVD, booted or not) with the preinstalled
// apps that tests do not use turned off (fast_boot/android-apps.txt), with or without its
// window (--headless).
// `pm disable-user` turns an app off at once, with no reboot to pay, until `pm enable`: it is
// stored in the AVD's data, so it holds through reboots.
// Without its window (-no-window), the emulator draws no frames for one: less memory and CPU
// on the computer, as for a CI run or a suite left to run.
package speedrun

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

FAST_BOOT_ANDROID_APPS :: #load("fast_boot/android-apps.txt", string)

// From the emulator's start to the end of its boot: a first boot of a new AVD takes minutes on
// a slow CI machine.
@(private = "file")
EMULATOR_BOOT_TIMEOUT :: 10 * time.Minute

@(private = "file")
Emulator :: struct {
	serial:   string, // emulator-5554; "" while it is not running
	avd:      string, // its AVD's name, as `emulator -list-avds` lists it
	pid:      int, // its qemu process (0: not found)
	headless: bool, // started with -no-window
	args:     []string, // its qemu process's arguments, to start it again as it was
}

run_fast_boot_android :: proc(device: string, headless, off: bool) -> int {
	emu, err := fast_boot_emulator(device)
	if err != "" {
		fmt.eprintln(err)
		return 1
	}
	start := time.tick_now()
	booted := false
	if emu.serial != "" && headless && !emu.headless {
		// Its flags are kept: only the window goes, and Android Studio's (its window hidden in
		// the IDE's, and an exit once the IDE has not called for some minutes).
		args := make([dynamic]string, context.temp_allocator)
		for i := 0; i < len(emu.args); i += 1 {
			switch emu.args[i] {
			case "-qt-hide-window":
			case "-idle-grpc-timeout": i += 1
			case: append(&args, emu.args[i])
			}
		}
		append(&args, "-no-window")
		fmt.printf("Restarting %s without its window...\n", emu.avd)
		if e := emulator_stop(emu); e != "" {
			fmt.eprintln(e)
			return 1
		}
		start = time.tick_now()
		if emu.serial, err = emulator_start(emu.avd, args[:]); err != "" {
			fmt.eprintln(err)
			return 1
		}
		booted = true
	} else if emu.serial == "" {
		fmt.printf("Booting %s%s...\n", emu.avd, ", without a window" if headless else "")
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "-avd", emu.avd, "-no-boot-anim")
		if headless do append(&args, "-no-window")
		if emu.serial, err = emulator_start(emu.avd, args[:]); err != "" {
			fmt.eprintln(err)
			return 1
		}
		booted = true
	}
	if booted {
		if e := emulator_wait_boot(emu.serial, start); e != "" {
			fmt.eprintln(e)
			return 1
		}
	}
	// Once booted: turned off while it boots instead, they cost the same CPU after it. The
	// emulator is up either way, so a failure is a warning.
	changed, total, aerr := fast_boot_apps(emu.serial, off)
	took := fmt.tprintf(", booted in %.1f s", time.duration_seconds(time.tick_since(start))) if booted else ""
	switch {
	case aerr != "":
		fmt.eprintf("%s: its apps could not be turned %s: %s\n", emu.avd, "on" if off else "off", aerr)
		if booted do fmt.printf("%s%s.\n", emu.avd, took)
	case changed == 0 && !booted:
		fmt.printf("%s: its background apps are already %s.\n", emu.avd, "on" if off else "off")
	case off:
		fmt.printf("%s: background apps on again%s.\n", emu.avd, took)
	case:
		fmt.printf("%s: %d background apps off%s.\n", emu.avd, total, took)
	}
	return 0
}

// The packages in fast_boot/android-apps.txt: one per line, # comments.
@(private = "file")
fast_boot_android_apps :: proc() -> []string {
	apps := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(FAST_BOOT_ANDROID_APPS, context.temp_allocator) {
		l := strings.trim_space(line)
		if l != "" && l[0] != '#' do append(&apps, l)
	}
	return apps[:]
}

// Turns the listed apps the device has off (or on again), in one adb call. changed: how many
// were not so already; total: how many it has.
@(private = "file")
fast_boot_apps :: proc(serial: string, on: bool) -> (changed, total: int, err: string) {
	// Names are plain package names (letters, digits, dots, underscores): nothing to quote.
	// `pm list packages -d` lists the disabled ones, a line each.
	script := fmt.tprintf(
		`pm path android > /dev/null || exit 1; d=$(pm list packages -d) || exit 1; for p in %s; do pm path $p > /dev/null 2>&1 || continue; echo has; if echo "$d" | grep -qx "package:$p"; then %s; else %s; fi; done`,
		strings.join(fast_boot_android_apps(), " ", context.temp_allocator),
		"pm enable $p > /dev/null && echo changed" if on else ":",
		":" if on else "pm disable-user --user 0 $p > /dev/null && echo changed",
	)
	out, ok := adb("-s", serial, "shell", script)
	if !ok do return 0, 0, strings.trim_space(out) if strings.trim_space(out) != "" else "the package manager did not answer"
	for line in strings.split_lines(out, context.temp_allocator) {
		switch strings.trim_space(line) {
		case "has": total += 1
		case "changed": changed += 1
		}
	}
	return changed, total, ""
}

// The emulator to boot or change: --device names a running one (its serial) or an AVD
// (running or not); without it, the one running.
@(private = "file")
fast_boot_emulator :: proc(device: string) -> (emu: Emulator, err: string) {
	running := running_emulators()
	if device != "" {
		for e in running do if e.serial == device || e.avd == device do return e, ""
		if strings.has_prefix(device, "emulator-") do return {}, fmt.tprintf("No emulator %s is running (adb devices).", device)
		avds, aerr := list_avds()
		if aerr != "" do return {}, aerr
		for a in avds do if a == device do return {avd = a}, ""
		if out, ok := adb("-s", device, "get-state"); ok && strings.trim_space(out) == "device" {
			return {}, fmt.tprintf("%s is a phone or tablet, not an emulator: fast-boot turns apps off on emulators only.", device)
		}
		return {}, fmt.tprintf("No emulator or AVD named %s. AVDs: %s (emulator -list-avds).", device, strings.join(avds, ", ", context.temp_allocator) if len(avds) > 0 else "none")
	}
	switch len(running) {
	case 1:
		return running[0], ""
	case 0:
		avds, _ := list_avds()
		if len(avds) == 0 do return {}, "No Android emulator is running: name an AVD to boot with --device <name> (emulator -list-avds)."
		return {}, fmt.tprintf("No Android emulator is running: name an AVD to boot with --device <name>: %s.", strings.join(avds, ", ", context.temp_allocator))
	}
	names := make([dynamic]string, context.temp_allocator)
	for e in running do append(&names, fmt.tprintf("%s %s", e.avd, e.serial))
	return {}, fmt.tprintf("Several emulators are running: pick one with --device <serial or AVD>:\n  %s", strings.join(names[:], "\n  ", context.temp_allocator))
}

fast_boot_emulators_running :: proc() -> bool {
	return len(running_emulators()) > 0
}

// The emulators adb sees, each with its AVD and, from `ps`, its process and flags.
@(private = "file")
running_emulators :: proc() -> []Emulator {
	out, ok := adb("devices")
	if !ok do return nil
	// ps is setuid root on macOS: waiting on it fails (Permission_Denied), so sh waits, on a pipe
	// (sh -c would exec a lone command).
	ps := ""
	if state, stdout, _, err := os.process_exec({command = {"sh", "-c", "ps -Ao pid=,args= | cat"}}, context.temp_allocator); err == nil && state.exit_code == 0 {
		ps = string(stdout)
	}

	emus := make([dynamic]Emulator, context.temp_allocator)
	for line in strings.split_lines(out, context.temp_allocator) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) < 2 || !strings.has_prefix(fields[0], "emulator-") do continue
		e := Emulator{serial = fields[0]}
		if name, nok := adb("-s", e.serial, "emu", "avd", "name"); nok {
			// The console's answer: the name, then OK.
			e.avd = strings.trim_space(strings.split_lines(name, context.temp_allocator)[0])
		}
		if e.avd == "" do continue
		for p in strings.split_lines(ps, context.temp_allocator) {
			args := strings.fields(p, context.temp_allocator)
			if len(args) < 2 || !strings.contains(args[1], "qemu-system") do continue
			for a, i in args do if a == "-avd" && i + 1 < len(args) && args[i + 1] == e.avd {
				e.pid = parse_int_or_zero(args[0])
				e.args = args[2:]
				e.headless = strings.has_suffix(args[1], "-headless")
				for x in e.args do if x == "-no-window" do e.headless = true
			}
		}
		append(&emus, e)
	}
	return emus[:]
}

@(private = "file")
parse_int_or_zero :: proc(s: string) -> int {
	n := 0
	for c in s {
		if c < '0' || c > '9' do return 0
		n = n * 10 + int(c - '0')
	}
	return n
}

// `emulator -list-avds`: a name a line (after INFO lines on some versions).
@(private = "file")
list_avds :: proc() -> (avds: []string, err: string) {
	exe := emulator_exe()
	if exe == "" do return nil, "The Android emulator was not found: set ANDROID_HOME to your Android SDK."
	state, stdout, stderr, perr := os.process_exec({command = {exe, "-list-avds"}}, context.temp_allocator)
	if perr != nil || state.exit_code != 0 do return nil, fmt.tprintf("%s -list-avds failed: %s", exe, strings.trim_space(string(stderr)))
	list := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		l := strings.trim_space(line)
		if l != "" && !strings.contains(l, "|") && !strings.contains(l, " ") do append(&list, l)
	}
	return list[:], ""
}

// The SDK's emulator: $ANDROID_HOME, $ANDROID_SDK_ROOT, the SDK adb comes from, then the
// default places of Android Studio's SDK.
@(private = "file")
emulator_exe :: proc() -> string {
	sdks := make([dynamic]string, context.temp_allocator)
	for v in ([]string{"ANDROID_HOME", "ANDROID_SDK_ROOT"}) {
		if s := os.get_env(v, context.temp_allocator); s != "" do append(&sdks, s)
	}
	if state, stdout, _, err := os.process_exec({command = {"sh", "-c", "command -v adb"}}, context.temp_allocator); err == nil && state.exit_code == 0 {
		adb_path := strings.trim_space(string(stdout))
		if strings.has_suffix(adb_path, "/platform-tools/adb") do append(&sdks, adb_path[:len(adb_path) - len("/platform-tools/adb")])
	}
	home := os.get_env("HOME", context.temp_allocator)
	append(&sdks, fmt.tprintf("%s/Library/Android/sdk", home), fmt.tprintf("%s/Android/Sdk", home))
	for sdk in sdks {
		exe := fmt.tprintf("%s/emulator/emulator", sdk)
		if os.exists(exe) do return exe
	}
	return ""
}

// Starts the emulator in its own session (perl's setsid), so it outlives this process and a
// Ctrl-C, and returns its serial once adb sees it. Its output goes to a log in the temp
// folder, whose end is shown if it stops.
@(private = "file")
emulator_start :: proc(avd: string, args: []string) -> (serial: string, err: string) {
	exe := emulator_exe()
	if exe == "" do return "", "The Android emulator was not found: set ANDROID_HOME to your Android SDK."
	before := make(map[string]bool, context.temp_allocator)
	for e in running_emulators() do before[e.serial] = true
	tmp, _ := os.temp_directory(context.temp_allocator)
	log := fmt.tprintf("%s/speedrun-emulator-%s.log", strings.trim_right(tmp, "/"), avd)
	f, ferr := os.open(log, {.Write, .Create, .Trunc})
	if ferr != nil do return "", fmt.tprintf("could not create %s: %v", log, ferr)
	defer os.close(f)
	null, nerr := os.open("/dev/null", {.Read})
	if nerr != nil do return "", "could not open /dev/null"
	defer os.close(null)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "perl", "-MPOSIX=setsid", "-e", "setsid(); exec @ARGV", exe)
	append(&cmd, ..args)
	p, perr := os.process_start({command = cmd[:], stdin = null, stdout = f, stderr = f})
	if perr != nil do return "", fmt.tprintf("could not run %s: %v", exe, perr)
	start := time.tick_now()
	for time.tick_since(start) < EMULATOR_BOOT_TIMEOUT {
		if state, werr := os.process_wait(p, 0); werr == nil && state.exited {
			data, _ := os.read_entire_file(log, context.temp_allocator)
			return "", fmt.tprintf("The emulator stopped. The end of its output (%s):\n%s", log, indent(tail(string(data), 15)))
		}
		for e in running_emulators() do if !before[e.serial] && e.avd == avd do return strings.clone(e.serial), ""
		time.sleep(500 * time.Millisecond)
	}
	return "", fmt.tprintf("%s did not show up in adb devices within %v (its output: %s).", avd, EMULATOR_BOOT_TIMEOUT, log)
}

// Until Android says it has booted (sys.boot_completed).
@(private = "file")
emulator_wait_boot :: proc(serial: string, start: time.Tick) -> (err: string) {
	for time.tick_since(start) < EMULATOR_BOOT_TIMEOUT {
		if out, ok := adb("-s", serial, "shell", "getprop sys.boot_completed"); ok && strings.trim_space(out) == "1" do return ""
		time.sleep(500 * time.Millisecond)
	}
	return fmt.tprintf("%s did not finish booting within %v.", serial, EMULATOR_BOOT_TIMEOUT)
}

// `adb emu kill`, then until its process has ended (it saves its quick-boot snapshot first,
// unless started with -no-snapshot-save).
@(private = "file")
emulator_stop :: proc(emu: Emulator) -> (err: string) {
	if out, ok := adb("-s", emu.serial, "emu", "kill"); !ok do return fmt.tprintf("could not stop %s: %s", emu.serial, out)
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Minute {
		gone := true
		for e in running_emulators() do if e.serial == emu.serial do gone = false
		if gone && (emu.pid == 0 || !process_alive(emu.pid)) do return ""
		time.sleep(500 * time.Millisecond)
	}
	return fmt.tprintf("%s did not stop within 2 minutes.", emu.avd)
}

@(private = "file")
process_alive :: proc(pid: int) -> bool {
	state, _, _, err := os.process_exec({command = {"kill", "-0", fmt.tprint(pid)}}, context.temp_allocator)
	return err == nil && state.exit_code == 0
}
