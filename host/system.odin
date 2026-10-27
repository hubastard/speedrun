// Commands that change the device rather than tap the app: permissions, launch arguments,
// orientation, dark and airplane mode. Done with adb/simctl and, on iOS, the simulator's TCC
// database (what applesimutils writes).
package speedrun

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

// launchApp without `permissions:` grants everything, for testing convenience.
DEFAULT_PERMISSIONS :: []Env_Pair{{"all", "allow"}}

// setPermissions and launchApp's permissions: `all` first, then each named one, which wins.
set_permissions :: proc(r: ^Runner, app: string, perms: []Env_Pair) -> Err {
	values := make([]Env_Pair, len(perms), context.temp_allocator)
	for p, i in perms do values[i] = {p.key, eval(r, p.value) or_return}
	if r.dev.platform == .IOS {
		// The runner keeps the last permissions it was given (XCTestIOSDevice.setPermissions):
		// `notifications`, else `all`, is how it answers the notification alert.
		r.notifications = ""
		for p in values do if p.key == "all" do r.notifications = p.value
		for p in values do if p.key == "notifications" do r.notifications = p.value
		if r.notifications != "allow" && r.notifications != "deny" do r.notifications = ""
		r.notifications = strings.clone(r.notifications, r.alloc)
		return ios_set_permissions(r, app, values)
	}
	for p in values do if p.key == "all" do android_set_all_permissions(r, app, p.value)
	for p in values {
		if p.key == "all" do continue
		for name in android_permission_names(p.key) do android_set_permission(r, app, name, p.value)
	}
	return nil
}

// ---- Android ----------------------------------------------------------------------------

// `all`: every permission the app's manifest asks for. Only runtime permissions can change,
// so only those not in the wanted state yet are set, plus MANAGE_EXTERNAL_STORAGE through
// appops.
@(private = "file")
android_set_all_permissions :: proc(r: ^Runner, app, value: string) {
	grant := value == "allow"
	// From the agent (~5 ms): only what is not in the wanted state yet costs a shell call.
	if perms, ok := op_perms(r.c, app, context.temp_allocator); ok {
		for p in perms {
			if p.name == "android.permission.MANAGE_EXTERNAL_STORAGE" {
				want: u8 = 0 if grant else 2 if value == "deny" else 3
				if p.app_op_mode != want do android_set_permission(r, app, p.name, value)
			} else if p.runtime && p.granted != grant {
				_ = shell(r, "pm %s %s %s", "grant" if grant else "revoke", app, p.name)
			}
		}
		return
	}
	out := shell(r, "dumpsys package %s", app)
	runtime := false
	for line in strings.split_lines(out, context.temp_allocator) {
		l := strings.trim_space(line)
		if strings.has_suffix(l, "permissions:") {
			runtime = l == "runtime permissions:"
			continue
		}
		if l == "android.permission.MANAGE_EXTERNAL_STORAGE" { // under "requested permissions:"
			android_set_permission(r, app, l, value)
			continue
		}
		perm, _, state := strings.partition(l, ": granted=")
		if state == "" do continue
		granted := strings.has_prefix(state, "true")
		if grant && !granted {
			_ = shell(r, "pm grant %s %s", app, perm)
		} else if !grant && granted && runtime {
			_ = shell(r, "pm revoke %s %s", app, perm)
		}
	}
}

@(private = "file")
android_set_permission :: proc(r: ^Runner, app, permission, value: string) {
	if permission == "android.permission.MANAGE_EXTERNAL_STORAGE" {
		mode := value if value == "allow" || value == "deny" else "default"
		_ = shell(r, "appops set --uid %s MANAGE_EXTERNAL_STORAGE %s", app, mode)
		return
	}
	_ = shell(r, "pm %s %s %s", "grant" if value == "allow" else "revoke", app, permission)
}

// A flow's permission name as Android's.
@(private = "file")
ANDROID_PERMISSION_GROUPS :: []struct {
	name:  string,
	perms: []string,
}{
	{"bluetooth", {"android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH_SCAN"}},
	{"calendar", {"android.permission.WRITE_CALENDAR", "android.permission.READ_CALENDAR"}},
	{"camera", {"android.permission.CAMERA"}},
	{"contacts", {"android.permission.READ_CONTACTS", "android.permission.WRITE_CONTACTS"}},
	{"location", {"android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"}},
	{"medialibrary", {
		"android.permission.WRITE_EXTERNAL_STORAGE", "android.permission.READ_EXTERNAL_STORAGE",
		"android.permission.READ_MEDIA_AUDIO", "android.permission.READ_MEDIA_IMAGES",
		"android.permission.READ_MEDIA_VIDEO",
	}},
	{"microphone", {"android.permission.RECORD_AUDIO"}},
	{"notifications", {"android.permission.POST_NOTIFICATIONS"}},
	{"phone", {"android.permission.CALL_PHONE", "android.permission.ANSWER_PHONE_CALLS"}},
	{"sms", {"android.permission.READ_SMS", "android.permission.RECEIVE_SMS", "android.permission.SEND_SMS"}},
	{"storage", {"android.permission.WRITE_EXTERNAL_STORAGE", "android.permission.READ_EXTERNAL_STORAGE"}},
}

@(private = "file")
android_permission_names :: proc(name: string) -> []string {
	for g in ANDROID_PERMISSION_GROUPS do if g.name == name do return g.perms
	// Any other name as given, minus characters a permission cannot have.
	b := strings.builder_make(context.temp_allocator)
	for c in name {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' {
			strings.write_rune(&b, c)
		}
	}
	out := make([]string, 1, context.temp_allocator)
	out[0] = strings.to_string(b)
	return out
}

// launchApp: the launcher activity, with `arguments:` as typed intent extras on the launch
// intent.
android_launch :: proc(r: ^Runner, comp: string, args: []Launch_Arg) -> Err {
	START :: "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "
	if len(args) == 0 {
		out := shell(r, "%s%s", START, comp)
		if strings.contains(out, "Error") do return strings.trim_space(out)
		return nil
	}
	// Values can hold spaces: through adb's shell, which quotes, not the agent's.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, START)
	strings.write_string(&b, comp)
	for a in args {
		flag: string
		switch a.kind {
		case .String: flag = "--es"
		case .Bool:   flag = "--ez"
		case .Int:    flag = "--ei"
		case .Long:   flag = "--el"
		case .Double: flag = "--ed"
		}
		fmt.sbprintf(&b, " %s %s %s", flag, sh_quote(a.key), sh_quote(a.value))
	}
	out, ok := adb("shell", strings.to_string(b))
	if !ok || strings.contains(out, "Error") do return strings.clone(strings.trim_space(out), r.alloc)
	return nil
}

@(private = "file")
sh_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", q, "'"}, context.temp_allocator)
}

// launchApp's arguments with their ${...} run (LaunchAppCommand.evaluateScriptsIncludingKeys).
eval_launch_arguments :: proc(r: ^Runner, args: []Launch_Arg) -> (out: []Launch_Arg, err: Err) {
	out = make([]Launch_Arg, len(args), context.temp_allocator)
	for a, i in args {
		out[i] = a
		out[i].key = eval(r, a.key) or_return
		if a.kind == .String do out[i].value = eval(r, a.value) or_return
	}
	return out, nil
}

// IOSLaunchArguments: `-key value` pairs (the app reads them as user defaults); a boolean's
// key is passed as written.
ios_launch_arguments :: proc(args: []Launch_Arg) -> []string {
	out := make([dynamic]string, 0, 2 * len(args), context.temp_allocator)
	for a in args {
		key := a.key
		if a.kind != .Bool && !strings.has_prefix(key, "-") do key = strings.concatenate({"-", key}, context.temp_allocator)
		append(&out, key, a.value)
	}
	return out[:]
}

// iOS apps run their animations 10x faster, as Android's are turned off (device.odin):
// UIKit's UIAnimationDragCoefficient, which the simulator's "Slow Animations" sets to 10.
// UIKit reads it from the app's defaults (this launch argument, unless the flow passes its
// own) once the UIKit/UIPreferences feature flag is on (ios_launch_env).
@(rodata)
ios_animation_args := [2]string{"-UIAnimationDragCoefficient", "0.1"}

ios_animation_arguments :: proc(args: []Launch_Arg) -> []string {
	for a in args do if strings.trim_left(a.key, "-") == "UIAnimationDragCoefficient" do return nil
	return ios_animation_args[:]
}

// `simctl launch`'s environment: ours, with the feature flag added to the app's
// (SIMCTL_CHILD_X reaches it as X; flags are separated by colons).
ios_launch_env :: proc() -> []string {
	KEY :: "SIMCTL_CHILD_FEATUREFLAGS_ENABLED"
	FLAG :: "UIKit/UIPreferences"
	environ, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(environ) + 1, context.temp_allocator)
	flags := FLAG
	for e in environ {
		if !strings.has_prefix(e, KEY + "=") {
			append(&env, e)
			continue
		}
		old := e[len(KEY) + 1:]
		if old != "" do flags = old if strings.contains(old, FLAG) else strings.concatenate({old, ":", FLAG}, context.temp_allocator)
	}
	append(&env, strings.concatenate({KEY, "=", flags}, context.temp_allocator))
	return env[:]
}

// The Android API level (cached).
@(private = "file")
api_level :: proc(r: ^Runner) -> int {
	if r.api_level == 0 {
		v, ok := strconv.parse_int(strings.trim_space(shell(r, "getprop ro.build.version.sdk")))
		r.api_level = v if ok else 1
	}
	return r.api_level
}

// ---- iOS ----------------------------------------------------------------------------------

// The permissions a flow can set on iOS (applesimutils' names), with their TCC services.
@(private = "file")
IOS_TCC_SERVICES :: [][2]string {
	{"calendar", "kTCCServiceCalendar"}, {"camera", "kTCCServiceCamera"},
	{"contacts", "kTCCServiceAddressBook"}, {"faceid", "kTCCServiceFaceID"},
	{"homekit", "kTCCServiceWillow"}, {"medialibrary", "kTCCServiceMediaLibrary"},
	{"microphone", "kTCCServiceMicrophone"}, {"motion", "kTCCServiceMotion"},
	{"photos", "kTCCServicePhotos"}, {"reminders", "kTCCServiceReminders"},
	{"siri", "kTCCServiceSiri"}, {"speech", "kTCCServiceSpeechRecognition"},
	{"userTracking", "kTCCServiceUserTracking"},
}

// Location permission applied per "udid app" in this process: `simctl privacy` takes ~0.3 s
// and launchApp applies `all: allow` each time. ios_clear_state forgets an app. On the heap:
// it outlives each flow's arena (a suite's next flow read a freed map).
ios_location_set: map[string]string

// iOS permissions, through the TCC database as applesimutils does, and simctl for location.
// Notifications have no setting there: their alert is answered when a read shows it
// (answer_notification_alert).
@(private = "file")
ios_set_permissions :: proc(r: ^Runner, app: string, perms: []Env_Pair) -> Err {
	tcc := make(map[string]string, 16, context.temp_allocator) // service -> allow/deny/unset/limited
	location := ""
	for p in perms {
		if p.key != "all" do continue
		if p.value != "allow" && p.value != "deny" && p.value != "unset" {
			return fmt.aprintf("Permission 'all' can be set to 'allow', 'deny' or 'unset', not '%s'", p.value, allocator = r.alloc)
		}
		for s in IOS_TCC_SERVICES do tcc[s[1]] = p.value
		location = p.value == "allow" ? "always" : p.value == "deny" ? "never" : "unset"
	}
	for p in perms {
		if p.key == "location" do location = p.value
		for s in IOS_TCC_SERVICES do if s[0] == p.key do tcc[s[1]] = p.value
	}

	if len(tcc) > 0 {
		home := os.get_env("HOME", context.temp_allocator)
		db := fmt.tprintf("%s/Library/Developer/CoreSimulator/Devices/%s/data/Library/TCC/TCC.db", home, r.dev.udid)
		client := sql_quote(app)
		sql := strings.builder_make(context.temp_allocator)
		strings.write_string(&sql, "BEGIN;")
		for service, value in tcc {
			auth := -1
			switch value {
			case "allow":   auth = 2
			case "deny":    auth = 0
			case "limited": auth = 3
			case "unset":
			case:           continue // applesimutils rejects it: skipped
			}
			fmt.sbprintf(&sql, "DELETE FROM access WHERE service = '%s' AND client = %s AND client_type = 0;", service, client)
			if auth >= 0 {
				fmt.sbprintf(&sql,
					"INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags) VALUES ('%s', %s, 0, %d, 2, 1, 0);",
					service, client, auth)
			}
		}
		strings.write_string(&sql, "COMMIT;")
		// tccd can hold the database for a while after the simulator boots: wait for its lock.
		state, _, stderr, err := os.process_exec({command = {"sqlite3", "-cmd", ".timeout 5000", db, strings.to_string(sql)}}, context.temp_allocator)
		if err != nil do return "setting iOS permissions needs sqlite3 on PATH"
		if !state.exited || state.exit_code != 0 {
			return fmt.aprintf("could not set permissions in %s: %s", db, strings.trim_space(string(stderr)), allocator = r.alloc)
		}
	}

	if location != "" {
		key := fmt.tprintf("%s %s", r.dev.udid, app)
		if ios_location_set[key] == location do return nil
		action, service: string
		switch location {
		case "always": action, service = "grant", "location-always"
		case "inuse":  action, service = "grant", "location"
		case "never":  action, service = "revoke", "location-always"
		case "unset":  action, service = "reset", "location-always"
		case:
			return fmt.aprintf("wrong argument value '%s' was provided for 'location' permission", location, allocator = r.alloc)
		}
		if out, ok := simctl("privacy", r.dev.udid, action, service, app); !ok do return strings.clone(out, r.alloc)
		if ios_location_set == nil do ios_location_set = make(map[string]string, 8, runtime.heap_allocator())
		ios_location_set[strings.clone(key, runtime.heap_allocator())] = location
	}
	return nil
}

// When the screen holds "… Would Like to Send You Notifications", tap its button for
// r.notifications. allow: "Allow" or "Continue", else the second button; deny: "Don't Allow"
// (straight apostrophe) or "Cancel", else the first. Buttons in the foreground app's tree only.
answer_notification_alert :: proc(r: ^Runner) -> (tapped: bool, ok: bool) {
	if len(r.h.roots) == 0 do return false, true
	root := r.h.roots[0]
	end := r.h.roots[1] if len(r.h.roots) > 1 else len(r.h.nodes)
	alert := false
	buttons := make([dynamic]int, 0, 4, context.temp_allocator)
	for i in root ..< end {
		n := r.h.nodes[i]
		if strings.contains(strings.to_lower(n.desc, context.temp_allocator), "would like to send you notifications") do alert = true
		if n.class == "Button" do append(&buttons, i)
	}
	if !alert || len(buttons) == 0 do return false, true
	pick := -1
	for b in buttons {
		label := strings.to_lower(r.h.nodes[b].desc, context.temp_allocator)
		if r.notifications == "allow" && (label == "allow" || label == "continue") ||
		   r.notifications == "deny" && (strings.contains(label, "don't allow") || label == "cancel") {
			pick = b
			break
		}
	}
	if pick < 0 do pick = buttons[1] if r.notifications == "allow" && len(buttons) > 1 else buttons[0]
	n := r.h.nodes[pick]
	if r.debug do fmt.printf("      [notification alert: tapping %q]\n", n.desc)
	// A system alert's button: held a display frame (IOS_FRAME_TAP_MS).
	if _, tok := op_press(r.c, n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2, IOS_FRAME_TAP_MS); !tok do return false, false
	return true, true
}

@(private = "file")
sql_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", "''", context.temp_allocator)
	return strings.concatenate({"'", q, "'"}, context.temp_allocator)
}

// ---- orientation, dark and airplane mode -----------------------------------------------------

// setOrientation. Android: fixed rotation (auto-rotate off); iOS: the
// runner turns the device. Then the screen settles (the next read has the new display size).
set_orientation :: proc(r: ^Runner, name: string) -> Err {
	o, known := orientation_by_name(name)
	if !known do return unknown_orientation(name, r.alloc)
	if !op_mark(r.c) do return "agent connection lost"
	if r.dev.platform == .IOS {
		device: i32 = 1 // UIDeviceOrientation
		switch o {
		case "UPSIDE_DOWN":     device = 2
		case "LANDSCAPE_LEFT":  device = 3
		case "LANDSCAPE_RIGHT": device = 4
		}
		if !op_orientation(r.c, device) do return "agent connection lost"
	} else {
		rotation := 0
		switch o {
		case "LANDSCAPE_LEFT":  rotation = 1
		case "UPSIDE_DOWN":     rotation = 2
		case "LANDSCAPE_RIGHT": rotation = 3
		}
		_ = shell(r, "settings put system accelerometer_rotation 0")
		_ = shell(r, "settings put system user_rotation %d", rotation)
		settle(r) or_return
		// The rotation recreates the activity, and the settle can end while no app window is
		// active yet (only the status bar on screen): the next command then waited for the
		// app (~1 s), and a screenshot caught the half-done rotation. Wait for the active
		// window, in the new orientation.
		if active_window_rotated(r, rotation % 2 == 1) {
			if !op_mark(r.c) do return "agent connection lost"
			return settle(r)
		}
		return nil
	}
	return settle(r)
}

// Android: waits for an app-sized active window, landscape or not as asked. Up to
// SETTLE_TIMEOUT_MS without one; with one in the other orientation, only 1 s (an app locked
// to portrait never turns).
@(private = "file")
active_window_rotated :: proc(r: ^Runner, landscape: bool) -> (waited: bool) {
	nodes: Tree
	nodes.allocator = context.temp_allocator
	start := time.tick_now()
	for {
		if _, ok := op_tree(r.c, &nodes, context.temp_allocator); !ok do return waited
		if r.debug && len(nodes) > 0 do fmt.printf("      [active window %d nodes, %v %v %v %v, %q]\n", len(nodes), nodes[0].left, nodes[0].top, nodes[0].right, nodes[0].bottom, nodes[0].text)
		if r.debug && len(nodes) == 0 do fmt.println("      [no active window]")
		limit := time.Duration(SETTLE_TIMEOUT_MS) * time.Millisecond
		// While the app is gone the status bar can be the active window: not that one.
		if len(nodes) > 0 && 2 * min(nodes[0].right - nodes[0].left, nodes[0].bottom - nodes[0].top) >= min(r.w, r.h_px) {
			w, h := nodes[0].right - nodes[0].left, nodes[0].bottom - nodes[0].top
			if (w > h) == landscape do return waited
			limit = time.Second
		}
		if time.tick_since(start) > limit do return waited
		waited = true
		time.sleep(10 * time.Millisecond)
	}
}

device_mode :: proc(r: ^Runner, op: Device_Mode_Op) -> (mutating: bool, err: Err) {
	switch op {
	case .Airplane_On, .Airplane_Off, .Airplane_Toggle:
		// Airplane mode is not available on iOS simulators: a no-op.
		if r.dev.platform == .IOS do return true, nil
		on := op == .Airplane_On
		if op == .Airplane_Toggle do on = !(airplane_enabled(r) or_return)
		if api_level(r) < 28 {
			_ = shell(r, "settings put global airplane_mode_on %d", 1 if on else 0)
			_ = shell(r, "am broadcast -a android.intent.action.AIRPLANE_MODE --ez state %v", on)
		} else {
			_ = shell(r, "cmd connectivity airplane-mode %s", "enable" if on else "disable")
		}
		return true, nil
	case .Dark_On, .Dark_Off, .Dark_Toggle:
		on := op == .Dark_On
		if op == .Dark_Toggle do on = !(dark_enabled(r) or_return)
		if r.dev.platform == .IOS {
			// XCUIDevice.appearance. The app redraws in place: no wait (the next lookup
			// sees the new screen).
			if _, ok := op_appearance(r.c, 2 if on else 1); !ok do return true, "agent connection lost"
			return true, nil
		}
		// Android restarts the visible activities: the next command that needs the screen
		// waits for that (exec); mode switches and asserts on them run meanwhile.
		if !op_mark(r.c) do return true, "agent connection lost"
		_ = shell(r, "cmd uimode night %s", "yes" if on else "no")
		r.settle_due = true
		return true, nil
	case .Assert_Dark, .Assert_Light:
		want := op == .Assert_Dark
		have := dark_enabled(r) or_return
		if have != want {
			return false, fmt.aprintf(
				"Assertion failed: expected dark mode to be %s, but it was %s", "enabled" if want else "disabled",
				"enabled" if have else "disabled", allocator = r.alloc)
		}
		return false, nil
	}
	return false, nil
}

@(private = "file")
airplane_enabled :: proc(r: ^Runner) -> (on: bool, err: Err) {
	switch out := strings.trim_space(shell(r, "cmd connectivity airplane-mode")); out {
	case "enabled":  return true, nil
	case "disabled": return false, nil
	case "", "No shell command implementation.":
		switch v := strings.trim_space(shell(r, "settings get global airplane_mode_on")); v {
		case "1": return true, nil
		case "0": return false, nil
		case:     return false, fmt.aprintf("Received invalid response from while trying to read airplane mode state: %s", v, allocator = r.alloc)
		}
	case:
		return false, fmt.aprintf("Received invalid response while trying to read airplane mode state: %s", out, allocator = r.alloc)
	}
}

@(private = "file")
dark_enabled :: proc(r: ^Runner) -> (on: bool, err: Err) {
	if r.dev.platform == .IOS {
		appearance, ok := op_appearance(r.c, 0)
		if !ok do return false, "agent connection lost"
		return appearance == 2, nil
	}
	switch out := strings.trim_space(shell(r, "cmd uimode night")); out {
	case "Night mode: yes": return true, nil
	case "Night mode: no":  return false, nil
	case:                   return false, fmt.aprintf("Received invalid response while trying to read dark mode state: %s", out, allocator = r.alloc)
	}
}

// ---- screenshots ----------------------------------------------------------------------------

// Creates `path` and the folders above it; true if it exists afterwards (make_directory_all
// reports .Exist for a folder already there: a second screenshot in the same folder).
make_dirs :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	return err == nil || err == .Exist
}

// Where takeScreenshot and startRecording write (ArtifactCollector.allocateCommandOutput):
// `<path><ext>` in the flow's debug output, under a folder named after the command, which
// the path must stay inside; with no debug output, relative to the current directory.
command_output :: proc(r: ^Runner, command, path, ext: string) -> (file: string, err: Err) {
	invalid :: proc(r: ^Runner, path, command, reason: string) -> Err {
		return fmt.aprintf("Invalid path \"%s\" for %s: %s. If the path comes from a variable, check what it expands to.", path, command, reason, allocator = r.alloc)
	}
	if strings.trim_space(path) == "" do return "", invalid(r, path, command, "the path is empty")
	last := path[max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\')) + 1:]
	switch strings.trim_space(last) {
	case "", ".", "..":
		return "", invalid(r, path, command, "it names a directory, so there is no file name to write to")
	}
	name := strings.concatenate({path, ext}, context.temp_allocator)
	if r.flow_dir == "" do return strings.clone(name, r.alloc), nil
	folder, _ := filepath.join({r.flow_dir, command}, context.temp_allocator)
	file, _ = filepath.join({folder, name}, r.alloc)
	if filepath.is_abs(name) || !strings.has_prefix(file, strings.concatenate({folder, "/"}, context.temp_allocator)) {
		return "", invalid(r, path, command, fmt.tprintf("it resolves outside this run's %s output folder", command))
	}
	if !make_dirs(filepath.dir(file)) {
		return "", fmt.aprintf("cannot create %s", filepath.dir(file), allocator = r.alloc)
	}
	return file, nil
}

// A PNG of the screen, or of the element cropOn picks (found first).
screenshot :: proc(r: ^Runner, crop_on: ^Selector, optional: bool) -> (png: []byte, err: Err) {
	if crop_on == nil {
		ok: bool
		png, ok = op_screenshot(r.c, r.alloc)
		if !ok do return nil, "agent connection lost"
		return png, nil
	}
	el := find_element(r, crop_on, optional, -1) or_return
	n := r.h.nodes[el]
	if n.right - n.left <= 0 || n.bottom - n.top <= 0 {
		return nil, fmt.aprintf(
			"Cannot crop screenshot: element '%s' has invalid dimensions (width: %d, height: %d). The element must have positive width and height to crop the screenshot.",
			selector_description(crop_on), n.right - n.left, n.bottom - n.top, allocator = r.alloc)
	}
	full, ok := op_screenshot(r.c, context.temp_allocator)
	if !ok do return nil, "agent connection lost"
	img, decoded := image_decode(full)
	if !decoded do return nil, "could not decode the screenshot"
	defer image_free(img)
	cropped := image_crop(img, n.left, n.top, n.right, n.bottom, r.h_px) or_return
	defer image_free(cropped)
	png, ok = image_png(cropped, r.alloc)
	if !ok do return nil, "could not encode the screenshot"
	return png, nil
}

// assertScreenshot: the screen (or cropOn's element)
// against a reference image next to the flow; on a mismatch, <name>_diff.png beside it shows
// the differing pixels.
assert_screenshot :: proc(r: ^Runner, c: ^Cmd, d: Assert_Screenshot) -> Err {
	threshold_text := eval(r, d.threshold) or_return
	threshold, number := strconv.parse_f64(strings.trim_space(threshold_text))
	if !number {
		return fmt.aprintf("Invalid thresholdPercentage for assertScreenshot: \"%s\". Expected a number.", threshold_text, allocator = r.alloc)
	}
	path := eval(r, d.path) or_return
	has_ext := false
	for ext in ([]string{".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tiff", ".wbmp", ".heic", ".heif"}) {
		if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ext) do has_ext = true
	}
	if !has_ext do path = fmt.tprintf("%s.png", path)
	// Next to the flow, then among this run's takeScreenshot outputs.
	candidates := make([dynamic]string, context.temp_allocator)
	if filepath.is_abs(path) {
		append(&candidates, path)
	} else {
		f, _ := filepath.join({d.dir, path}, context.temp_allocator)
		append(&candidates, f)
	}
	if r.flow_dir != "" && !filepath.is_abs(path) {
		f, _ := filepath.join({r.flow_dir, "takeScreenshot", path}, context.temp_allocator)
		append(&candidates, f)
	}
	file := ""
	for f in candidates do if file == "" && os.exists(f) do file = f
	if file == "" {
		b := strings.builder_make(context.temp_allocator)
		for f in candidates {
			abs_f, _ := filepath.abs(f, context.temp_allocator)
			fmt.sbprintf(&b, "\n  - %s", abs_f)
		}
		return fmt.aprintf("Screenshot file not found: %s. Searched in:%s", path, strings.to_string(b), allocator = r.alloc)
	}

	actual_png := screenshot(r, d.crop_on, c.optional) or_return
	actual, ok := image_decode(actual_png)
	if !ok do return "could not decode the screenshot"
	defer image_free(actual)
	data, rerr := os.read_entire_file(file, context.temp_allocator)
	expected, eok := image_decode(data)
	if rerr != nil || !eok {
		return fmt.aprintf("Failed to read image file: %s. Unsupported image format or file could not be read.", file, allocator = r.alloc)
	}
	defer image_free(expected)

	description := evaluated(r, command_description(r, c))
	if expected.width != actual.width || expected.height != actual.height {
		return fmt.aprintf(
			"Screenshot size mismatch: %s - expected %dx%d, actual %dx%d. Screenshots must have the same dimensions to compare.",
			description, expected.width, expected.height, actual.width, actual.height, allocator = r.alloc)
	}
	differing := make([dynamic]bool, context.temp_allocator)
	percent := image_match_percent(expected, actual, &differing)
	if percent >= threshold do return nil
	diff := image_diff(actual, differing[:])
	defer image_free(diff)
	if png, pok := image_png(diff, context.temp_allocator); pok {
		stem := strings.trim_suffix(filepath.base(file), filepath.ext(file))
		write_file(fmt.tprintf("%s/%s_diff.png", filepath.dir(file), stem), png)
	}
	return fmt.aprintf("Comparison error: %s - threshold not met, current: %s%%", description, kotlin_double(percent, context.temp_allocator), allocator = r.alloc)
}

// ---- screen recording -----------------------------------------------------------------------

Recording :: struct {
	active:  bool,
	process: os.Process, // `adb shell screenrecord` or `simctl io recordVideo`
	file:    string, // the video, `<path>.mp4`
}

@(private = "file")
DEVICE_RECORDING :: "/sdcard/speedrun-recording.mp4"

// startRecording: Android's screenrecord (bit rate below), or the simulator's recordVideo
// (h264). One at a time: a second start is ignored.
start_recording :: proc(r: ^Runner, file: string) -> Err {
	if r.recording.active do return nil
	null, nerr := os.open("/dev/null", {.Write})
	if nerr != nil do return "cannot open /dev/null"
	defer os.close(null)
	started := false
	p: os.Process
	perr: os.Error
	if r.dev.platform == .IOS {
		os.remove(file)
		p, perr = os.process_start({command = {"xcrun", "simctl", "io", r.dev.udid, "recordVideo", "--force", "--codec", "h264", file}, stdout = null, stderr = null})
	} else {
		_ = shell(r, "rm -f %s", DEVICE_RECORDING)
		// Stock screenrecord stops after 3 minutes unless told otherwise (API 34+ can).
		limit := "--time-limit 0 " if api_level(r) >= 34 else ""
		p, perr = os.process_start({command = adb_command("shell", fmt.tprintf("screenrecord %s--bit-rate 100000 %s", limit, DEVICE_RECORDING)), stdout = null, stderr = null})
	}
	if perr != nil do return fmt.aprintf("could not start the screen recording: %v", perr, allocator = r.alloc)
	// Recording from when its file appears (10 s at most).
	deadline := time.tick_now()
	for time.tick_since(deadline) < 10 * time.Second {
		if state, werr := os.process_wait(p, 0); werr == nil && state.exited do break
		if r.dev.platform == .IOS {
			started = os.exists(file)
		} else {
			started = !strings.contains(shell(r, "ls %s", DEVICE_RECORDING), "No such file")
		}
		if started do break
		time.sleep(20 * time.Millisecond)
	}
	if !started {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		if r.dev.platform == .IOS do return "Screen recording failed to start: the simulator did not create the video"
		return "Failed to capture screen recording on the device. Note that some Android emulators do not support screen recording."
	}
	r.recording = {true, p, file}
	return nil
}

// stopRecording, and the end of a flow still recording: stop it, keep the video.
stop_recording :: proc(r: ^Runner) -> Err {
	if !r.recording.active do return nil
	r.recording.active = false
	p := r.recording.process
	if r.dev.platform == .IOS {
		// simctl writes the video out on SIGINT.
		posix.kill(posix.pid_t(p.pid), .SIGINT)
		if _, werr := os.process_wait(p, 15 * time.Second); werr != nil {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			return "the screen recording did not stop"
		}
		return nil
	}
	_ = shell(r, "killall -INT screenrecord")
	if _, werr := os.process_wait(p, 15 * time.Second); werr != nil {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
	}
	out, ok := adb("pull", DEVICE_RECORDING, r.recording.file)
	_ = shell(r, "rm -f %s", DEVICE_RECORDING)
	if !ok do return fmt.aprintf("could not copy the screen recording: %s", out, allocator = r.alloc)
	return nil
}

// ---- media --------------------------------------------------------------------------------

// addMedia: images and videos into the device's gallery. Android: into Pictures or Movies,
// then the media scanner; iOS: simctl.
add_media :: proc(r: ^Runner, files: []string) -> Err {
	for f in files {
		ext := filepath.ext(f)
		ext = ext[1:] if len(ext) > 0 else ""
		switch ext {
		case "png", "jpeg", "jpg", "gif", "mp4":
		case:
			return fmt.aprintf("Extension .%s is not yet supported for add media", ext, allocator = r.alloc)
		}
		if r.dev.platform == .IOS {
			add_media_ios(r, f) or_return
			continue
		}
		dir := "/sdcard/Movies" if ext == "mp4" else "/sdcard/Pictures"
		target := fmt.tprintf("%s/%s", dir, filepath.base(f))
		if out, ok := adb("push", f, target); !ok do return fmt.aprintf("could not copy %s to the device: %s", f, out, allocator = r.alloc)
		_ = shell(r, "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://%s", target)
	}
	return nil
}

// The simulator's service reads the file, not simctl: a file under a folder macOS protects
// (Downloads, Documents, Desktop) makes it ask for access, and until someone answers,
// `simctl addmedia` waits (and so does every simctl call after it). A copy in the temp
// folder needs no permission.
@(private = "file")
add_media_ios :: proc(r: ^Runner, file: string) -> Err {
	tmp, _ := os.temp_directory(context.temp_allocator)
	copy_path := fmt.tprintf("%s/speedrun-media-%d-%s", strings.trim_right(tmp, "/"), os.get_pid(), filepath.base(file))
	data, rerr := os.read_entire_file(file, context.temp_allocator)
	if rerr != nil do return fmt.aprintf("cannot read %s: %v", file, rerr, allocator = r.alloc)
	if os.write_entire_file(copy_path, data) != nil do return fmt.aprintf("cannot write %s", copy_path, allocator = r.alloc)
	defer os.remove(copy_path)

	null, nerr := os.open("/dev/null", {.Write})
	if nerr != nil do return "cannot open /dev/null"
	defer os.close(null)
	p, perr := os.process_start({command = {"xcrun", "simctl", "addmedia", r.dev.udid, copy_path}, stdout = null, stderr = null})
	if perr != nil do return fmt.aprintf("could not run simctl: %v", perr, allocator = r.alloc)
	state, werr := os.process_wait(p, 60 * time.Second)
	if werr != nil {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		return fmt.aprintf(
			"`simctl addmedia` did not finish within 60 s (%s). Is macOS asking whether the simulator may access a folder? Answer that prompt and run again.",
			file, allocator = r.alloc)
	}
	if !state.exited || state.exit_code != 0 do return fmt.aprintf("`simctl addmedia` failed for %s", file, allocator = r.alloc)
	return nil
}

// ---- location -------------------------------------------------------------------------------

// Android: the shell's test location providers (Android 12+), sent again every 2 s, so apps
// asking for updates keep getting them. The agent sets them
// in-process (op_location, ~1 ms); without it, `cmd location` per provider (~9 ms each) and
// an `adb shell` loop re-sending.
Location_Mock :: struct {
	ready:     bool,
	providers: [dynamic]string,
	in_agent:  bool, // the agent sets and re-sends them
	updater:   os.Process, // the `adb shell` loop re-sending the location
	updating:  bool,
}

LOCATION_RESEND_MS :: 2000

set_location :: proc(r: ^Runner, latitude, longitude: f64, keep_sending := true) -> Err {
	lat, lon := kotlin_double(latitude, context.temp_allocator), kotlin_double(longitude, context.temp_allocator)
	if r.dev.platform == .IOS {
		if out, ok := simctl("location", r.dev.udid, "set", fmt.tprintf("%s,%s", lat, lon)); !ok do return strings.clone(out, r.alloc)
		return nil
	}
	if api_level(r) < 31 {
		// No test providers from the shell before Android 12: the emulator's own GPS.
		if out, ok := adb("emu", "geo", "fix", lon, lat); !ok {
			return fmt.aprintf("setLocation needs Android 12+ or an emulator: %s", out, allocator = r.alloc)
		}
		return nil
	}
	m := &r.location
	if !m.ready {
		_ = shell(r, "appops set com.android.shell android:mock_location allow")
		m.providers.allocator = r.alloc
		for p in ([]string{"gps", "network", "fused"}) {
			_ = shell(r, "cmd location providers add-test-provider %s", p)
			if out := shell(r, "cmd location providers set-test-provider-enabled %s true", p); !strings.contains(out, "Exception") {
				append(&m.providers, p)
			}
		}
		if len(m.providers) == 0 do return "could not add test location providers on the device"
		m.ready = true
		n, _ := op_location(r.c, m.providers[:], lat, lon, LOCATION_RESEND_MS)
		m.in_agent = n == len(m.providers)
		if !m.in_agent && n > 0 do _, _ = op_location(r.c, nil, "", "", 0)
		if !m.in_agent && r.debug do fmt.println("      [location: the agent cannot set test providers; using `cmd location`]")
		if m.in_agent do return nil
	}
	if m.in_agent {
		// Every point is re-sent, travel steps included.
		if n, ok := op_location(r.c, m.providers[:], lat, lon, LOCATION_RESEND_MS); ok && n == len(m.providers) do return nil
		m.in_agent = false
	}
	location_stop_updates(r)
	for p in m.providers {
		_ = shell(r, "cmd location providers set-test-provider-location %s --location %s,%s --accuracy 1", p, lat, lon)
	}
	if !keep_sending do return nil
	loop := strings.builder_make(context.temp_allocator)
	strings.write_string(&loop, "while true; do sleep 2; ")
	for p in m.providers {
		fmt.sbprintf(&loop, "cmd location providers set-test-provider-location %s --location %s,%s --accuracy 1; ", p, lat, lon)
	}
	strings.write_string(&loop, "done")
	null, nerr := os.open("/dev/null", {.Write})
	if nerr != nil do return nil
	defer os.close(null)
	p, perr := os.process_start({command = adb_command("shell", strings.to_string(loop)), stdout = null, stderr = null})
	if perr == nil {
		m.updater, m.updating = p, true
	}
	return nil
}

location_stop_updates :: proc(r: ^Runner) {
	if r.location.in_agent do _, _ = op_location(r.c, nil, "", "", 0)
	if !r.location.updating do return
	_ = os.process_kill(r.location.updater)
	_, _ = os.process_wait(r.location.updater)
	r.location.updating = false
}

// travel (Traveller): from point to point in 50 steps each, a step every 1/50 of the time
// the distance takes at `speed`. The distance is TravelCommand.getDistanceInMeters, which
// converts to radians twice: legs take far less time than their real length would.
travel :: proc(r: ^Runner, d: Travel) -> Err {
	if len(d.points) == 0 do return nil
	STEPS :: 50
	start := d.points[0]
	set_location(r, start[0], start[1], len(d.points) == 1) or_return
	for k in 1 ..< len(d.points) {
		end := d.points[k]
		ms := i64(travel_distance(start, end) / d.speed * 1000)
		pause := time.Duration(ms / STEPS) * time.Millisecond
		for i in 1 ..= STEPS {
			last := k == len(d.points) - 1 && i == STEPS
			lat := start[0] + (end[0] - start[0]) / STEPS * f64(i)
			lon := start[1] + (end[1] - start[1]) / STEPS * f64(i)
			set_location(r, lat, lon, last) or_return
			time.sleep(pause)
		}
		start = end
	}
	return nil
}

// Meters between two points. The latitudes and longitudes go through to_radians twice:
// travel's timing, which flows are written for, comes from this distance.
@(private = "file")
travel_distance :: proc(a, b: [2]f64) -> f64 {
	o_lat, o_lon := math.to_radians(a[0]), math.to_radians(a[1])
	a_lat, a_lon := math.to_radians(b[0]), math.to_radians(b[1])
	d_lat, d_lon := math.to_radians(a_lat - o_lat), math.to_radians(a_lon - o_lon)
	h := math.sin(d_lat / 2) * math.sin(d_lat / 2) +
		math.cos(math.to_radians(o_lat)) * math.cos(math.to_radians(a_lat)) * math.sin(d_lon / 2) * math.sin(d_lon / 2)
	return 6371 * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h)) * 1000
}

// ---- openLink autoVerify (Android) ----------------------------------------------------------

// openLink autoVerify: Android's "Open with" dialog: the flow's app, by its name (as a
// regex), then "Just once"; when only a longer text holds the name (the
// dialog's title for a single app), "Just once" alone. Then Chrome's first run: accept its
// terms, decline the sign-in.
auto_verify :: proc(r: ^Runner, app: string) -> Err {
	if label, ok := op_label(r.c, app, context.temp_allocator); app != "" && ok && label != "" {
		if r.debug do fmt.printf("      [autoVerify: %s is named %q]\n", app, label)
		if !read_screen(r) do return "agent connection lost"
		if el := deepest_text_match(r, compile(r, label) or_return); el >= 0 {
			n := r.h.nodes[el]
			if _, tok := op_tap(r.c, n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2); !tok do return "agent connection lost"
			_ = tap_id(r, "android:id/button_once") or_return
		} else if deepest_text_match(r, compile(r, fmt.tprintf(".*%s.*", label)) or_return) >= 0 {
			_ = tap_id(r, "android:id/button_once") or_return
		}
	}
	_ = tap_id(r, "com.android.chrome:id/terms_accept") or_return
	_ = tap_id(r, "com.android.chrome:id/negative_button") or_return
	return nil

	tap_id :: proc(r: ^Runner, id: string) -> (tapped: bool, err: Err) {
		if !read_screen(r) do return false, "agent connection lost"
		for &n in r.h.nodes do if n.kept && n.id == id && has_bounds(n) {
			if _, ok := op_tap(r.c, n.left + (n.right - n.left) / 2, n.top + (n.bottom - n.top) / 2); !ok do return false, "agent connection lost"
			return true, settle(r)
		}
		return false, nil
	}
}

// Filters.deepestMatchingElement over text, hint and description: the first match in the
// hierarchy none of whose descendants match too. -1 when none.
@(private = "file")
deepest_text_match :: proc(r: ^Runner, rx: ^Rx) -> int {
	matches := make([dynamic]int, 0, 8, context.temp_allocator)
	for i in r.h.order {
		n := r.h.nodes[i]
		if has_bounds(n) && (rx_full(rx, n.text) || rx_full(rx, n.hint) || rx_full(rx, n.desc)) do append(&matches, i)
	}
	outer: for m in matches {
		for other in matches {
			for p := r.h.nodes[other].parent; p >= 0; p = r.h.nodes[p].parent {
				if p == m do continue outer
			}
		}
		return m
	}
	return -1
}
