// speedrun fast-boot (`slim` until v0.2.10, still accepted): turns off the background services
// of an iOS simulator that apps and tests do not use (fast_boot/services.txt), then boots it.
// After a first boot they keep a simulator busy for minutes (~3 cores in the first, on a
// 10-core Mac), when CI runs its first flows.
// launchd_sim keeps the services turned off in a store on the host
// (/private/var/tmp/com.apple.CoreSimulator.SimDevice.<udid>/disabled.plist) that it reads
// when it starts and rewrites on each `launchctl disable`/`enable`; `simctl erase` leaves it.
// Written while the simulator is off, it applies from the next boot, with no reboot to pay:
// a booted simulator is shut down first. iOS 18.5 and later keep it; earlier ones forget it,
// and are booted as they are.
package speedrun

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

FAST_BOOT_SERVICES :: #load("fast_boot/services.txt", string)

FAST_BOOT_USAGE :: `usage: speedrun fast-boot [--device <udid>] [--off]
Boots an iOS simulator with the background services that apps and tests do not use turned
off (Siri and Apple Intelligence, Spotlight's indexing, widgets and wallpapers, iCloud and App
Store syncing, the Health, Fitness, News, Weather and Maps apps' services, diagnostics). It
boots faster, and does not spend its first minutes on them. Push, universal links, the
photo library, contacts, calendars, HealthKit, StoreKit's products, Apple Pay, CloudKit and
the keychain keep working; in-app purchases do not.
  --device <udid>   the simulator, booted or not (default: the one booted)
  --off             boot it with them back on
They stay off, through simctl erase too, until speedrun fast-boot --off. A booted simulator
is restarted. Before iOS 18.5 (which forgets them) it boots the simulator as it is.`

run_fast_boot_cli :: proc(args: []string) -> int {
	device, off := "", false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--device", "--udid":
			if i + 1 == len(args) {
				fmt.eprintln(FAST_BOOT_USAGE)
				return 2
			}
			i += 1
			device = args[i]
		case "--off":
			off = true
		case "-h", "--help":
			fmt.println(FAST_BOOT_USAGE)
			return 0
		case:
			fmt.eprintln(FAST_BOOT_USAGE)
			return 2
		}
	}
	sim, err := fast_boot_simulator(device)
	if err != "" {
		fmt.eprintln(err)
		return 1
	}
	// Where the services cannot be turned off, the simulator is still booted: a CI script
	// needs no fallback to simctl.
	if !(sim.major > 18 || sim.major == 18 && sim.minor >= 5) {
		return fast_boot_as_is(sim, fmt.tprintf("%s forgets turned-off services when it boots (iOS 18.5 or later keeps them)", sim.name))
	}
	labels := fast_boot_labels()
	store, serr := fast_boot_store_read(sim.udid)
	if serr != "" do return fast_boot_as_is(sim, serr)
	pending := 0
	for l in labels do if store[l] == off do pending += 1
	if pending == 0 && sim.state == "Booted" {
		fmt.printf("%s: its background services are already %s.\n", sim.name, "on" if off else "off")
		return 0
	}
	if pending > 0 {
		if sim.state != "Shutdown" {
			fmt.printf("Shutting %s down...\n", sim.name)
			if out, ok := simctl("shutdown", sim.udid); !ok && !strings.contains(out, "current state: Shutdown") {
				fmt.eprintln(out)
				return 1
			}
			if e := fast_boot_wait_shutdown(sim.udid); e != "" {
				fmt.eprintln(e)
				return 1
			}
		}
		for l in labels do store[l] = !off
		if e := fast_boot_store_write(sim.udid, store); e != "" do return fast_boot_as_is(sim, e)
	}
	fmt.printf("Booting %s...\n", sim.name)
	start := time.tick_now()
	if out, ok := simctl("bootstatus", sim.udid, "-b"); !ok {
		fmt.eprintln(out)
		return 1
	}
	booted := time.duration_seconds(time.tick_since(start))
	// launchd reads the store at boot, but it is a private detail: what it did is checked. The
	// simulator is booted either way, so a miss is a warning.
	out, ok := simctl("spawn", sim.udid, "launchctl", "print-disabled", "system")
	if !ok {
		fmt.eprintf("%s: booted in %.1f s, but its services could not be checked: %s\n", sim.name, booted, strings.trim_space(out))
		return 0
	}
	disabled := fast_boot_disabled(out)
	wrong := 0
	for l in labels do if disabled[l] == off do wrong += 1
	if wrong > 0 {
		fmt.eprintf("%s: booted in %.1f s, but %d of the %d services are still %s: this simulator did not take the setting.\n", sim.name, booted, wrong, len(labels), "off" if off else "on")
		return 0
	}
	if off {
		fmt.printf("%s: background services on again, booted in %.1f s.\n", sim.name, booted)
	} else {
		fmt.printf("%s: %d background services off, booted in %.1f s.\n", sim.name, len(labels), booted)
	}
	return 0
}

// The boot `xcrun simctl bootstatus -b` does, with the services as they are, after saying why.
@(private = "file")
fast_boot_as_is :: proc(sim: Fast_Boot_Simulator, why: string) -> int {
	fmt.eprintf("%s: booting it with its background services as they are.\n", why)
	fmt.printf("Booting %s...\n", sim.name)
	start := time.tick_now()
	if out, ok := simctl("bootstatus", sim.udid, "-b"); !ok {
		fmt.eprintln(out)
		return 1
	}
	fmt.printf("%s: booted in %.1f s.\n", sim.name, time.duration_seconds(time.tick_since(start)))
	return 0
}

Fast_Boot_Simulator :: struct {
	udid, name:   string, // name: "iPhone 17 Pro (iOS 26.2)"
	state:        string, // Shutdown, Booting, Booted, Shutting Down...
	major, minor: int, // its iOS version
}

// The simulator with this UDID (booted or not), else the one booted, from `simctl list devices
// -j`: {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{"udid", "name",
// "state"}...]}}.
@(private = "file")
fast_boot_simulator :: proc(device: string) -> (sim: Fast_Boot_Simulator, err: string) {
	out, ok := simctl("list", "devices", "-j")
	if !ok do return {}, out
	v, jerr := json.parse_string(out, allocator = context.temp_allocator)
	if jerr != nil do return {}, "could not read the simulator list (xcrun simctl list devices -j)"
	root, _ := v.(json.Object)
	runtimes, _ := root["devices"].(json.Object)
	booted := make([dynamic]Fast_Boot_Simulator, context.temp_allocator)
	for runtime, list in runtimes {
		_, _, version := strings.partition(runtime, "SimRuntime.iOS-")
		if version == "" do continue
		parts := strings.split(version, "-", context.temp_allocator)
		major, minor := 0, 0
		if len(parts) > 0 do major, _ = strconv.parse_int(parts[0], 10)
		if len(parts) > 1 do minor, _ = strconv.parse_int(parts[1], 10)
		sims, _ := list.(json.Array)
		for s in sims {
			o, _ := s.(json.Object)
			udid, _ := o["udid"].(json.String)
			name, _ := o["name"].(json.String)
			state, _ := o["state"].(json.String)
			sim := Fast_Boot_Simulator {
				udid   = udid,
				name   = fmt.tprintf("%s (iOS %s)", name, strings.join(parts, ".", context.temp_allocator)),
				state  = state,
				major  = major,
				minor  = minor,
			}
			if device != "" && udid == device do return sim, ""
			if state == "Booted" do append(&booted, sim)
		}
	}
	switch {
	case device != "":
		return {}, fmt.tprintf("No iOS simulator %s (xcrun simctl list devices).", device)
	case len(booted) == 1:
		return booted[0], ""
	case len(booted) == 0:
		return {}, "No booted iOS simulator: name one with --device <udid> (xcrun simctl list devices)."
	}
	names := make([dynamic]string, context.temp_allocator)
	for s in booted do append(&names, fmt.tprintf("%s %s", s.name, s.udid))
	return {}, fmt.tprintf("Several simulators are booted: pick one with --device <udid>:\n  %s", strings.join(names[:], "\n  ", context.temp_allocator))
}

// The labels in fast_boot/services.txt: one per line, # comments.
@(private = "file")
fast_boot_labels :: proc() -> []string {
	labels := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(FAST_BOOT_SERVICES, context.temp_allocator) {
		l := strings.trim_space(line)
		if l != "" && l[0] != '#' do append(&labels, l)
	}
	return labels[:]
}

@(private = "file")
fast_boot_store_path :: proc(udid: string) -> string {
	return fmt.tprintf("/private/var/tmp/com.apple.CoreSimulator.SimDevice.%s/disabled.plist", udid)
}

// The store, label -> disabled, as launchd_sim writes it: an XML plist of <key>label</key>
// then <true/> or <false/>. A simulator never booted has none: nothing is turned off.
@(private = "file")
fast_boot_store_read :: proc(udid: string) -> (store: map[string]bool, err: string) {
	store = make(map[string]bool, context.temp_allocator)
	path := fast_boot_store_path(udid)
	if !os.exists(path) do return store, ""
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return store, fmt.tprintf("could not read %s: %v", path, rerr)
	text := string(data)
	if !strings.has_prefix(text, "<?xml") do return store, fmt.tprintf("%s is not the XML plist expected", path)
	for {
		i := strings.index(text, "<key>")
		if i < 0 do break
		text = text[i + len("<key>"):]
		j := strings.index(text, "</key>")
		if j < 0 do break
		label := text[:j]
		text = strings.trim_left_space(text[j + len("</key>"):])
		switch {
		case strings.has_prefix(text, "<true/>"):
			store[label] = true
		case strings.has_prefix(text, "<false/>"):
			store[label] = false
		}
	}
	return store, ""
}

// Writes the store whole, in launchd_sim's own layout, through a rename so launchd_sim never
// reads half a file. Labels are plain names (com.apple.x): nothing to escape.
@(private = "file")
fast_boot_store_write :: proc(udid: string, store: map[string]bool) -> (err: string) {
	labels := make([dynamic]string, 0, len(store), context.temp_allocator)
	for l in store do append(&labels, l)
	slice.sort(labels[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
`)
	for l in labels do fmt.sbprintf(&b, "\t<key>%s</key>\n\t<%s/>\n", l, "true" if store[l] else "false")
	strings.write_string(&b, "</dict>\n</plist>\n")
	path := fast_boot_store_path(udid)
	dir := os.dir(path)
	if e := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); e != nil && e != .Exist {
		return fmt.tprintf("could not create %s: %v", dir, e)
	}
	tmp := fmt.tprintf("%s.speedrun", path)
	if e := os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)); e != nil do return fmt.tprintf("could not write %s: %v", tmp, e)
	if e := os.rename(tmp, path); e != nil do return fmt.tprintf("could not write %s: %v", path, e)
	return ""
}

// `launchctl print-disabled` lines: `"com.apple.x" => disabled` (older: `=> true`).
@(private = "file")
fast_boot_disabled :: proc(out: string) -> map[string]bool {
	disabled := make(map[string]bool, context.temp_allocator)
	for line in strings.split_lines(out, context.temp_allocator) {
		label, _, state := strings.partition(strings.trim_space(line), " => ")
		if len(label) < 2 || label[0] != '"' do continue
		disabled[label[1:len(label) - 1]] = state == "disabled" || state == "true"
	}
	return disabled
}

// Until the simulator is down: launchd_sim, while it runs, may write the store over ours.
@(private = "file")
fast_boot_wait_shutdown :: proc(udid: string) -> (err: string) {
	start := time.tick_now()
	for time.tick_since(start) < 60 * time.Second {
		sim, e := fast_boot_simulator(udid)
		if e != "" do return e
		if sim.state == "Shutdown" do return ""
		time.sleep(250 * time.Millisecond)
	}
	return "the simulator did not shut down within 60 s"
}
