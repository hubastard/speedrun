// clearState on a simulator. An app keeps its data in folders on the Mac (its data container,
// its app groups' and its extensions'), so emptying them from here takes milliseconds, where
// reinstalling the app (what Maestro does) takes ~0.8 s and makes its next launch ~0.1 s
// slower. What reinstalling resets elsewhere is reset too: the app's TCC permissions, its
// location authorization, and app-group preferences, which cfprefsd keeps cached (the app's
// own go with its process). App groups another installed app also has are kept, as
// reinstalling keeps them. The notification setting is held by SpringBoard, out of reach:
// when the app has one other than the launch asks for, or notifications scheduled or
// delivered, it is reinstalled (or with SPEEDRUN_CLEAR_STATE_REINSTALL=1). The keychain
// survives both, as on a device.
package speedrun

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:unicode/utf16"

@(private = "file")
CONTAINER_METADATA :: ".com.apple.mobile_container_manager.metadata.plist"

// What a fresh install leaves in a container, besides its metadata.
@(private = "file")
APP_CONTAINER_DIRS :: []string{"Documents", "Library/Caches", "Library/Preferences", "SystemData", "tmp"}
@(private = "file")
GROUP_CONTAINER_DIRS :: []string{"Library/Caches", "Library/Preferences"}

// notifications: how the launch that follows sets them ("allow", "deny", else "").
ios_clear_state :: proc(r: ^Runner, app: string, notifications := "") -> Err {
	udid := r.dev.udid
	delete_key(&ios_location_set, fmt.tprintf("%s %s", udid, app)) // reset either way
	// Stopping the app and finding its folders take ~170 ms each: at once.
	stop, serr := os.process_start({command = {"xcrun", "simctl", "terminate", udid, app}})
	info, err := ios_app_info(udid, app)
	if serr == nil do _, _ = os.process_wait(stop)
	if err != "" do return fmt.aprintf("Could not find app binary for bundle %s: %s", app, err)
	why := "SPEEDRUN_CLEAR_STATE_REINSTALL=1"
	if os.get_env("SPEEDRUN_CLEAR_STATE_REINSTALL", context.temp_allocator) != "1" do why = ios_empty_app(udid, app, info, notifications)
	if why == "" do return nil
	note(r, "clear state: reinstalling %s (%s)", app, why)
	return ios_reinstall(udid, app, info.bundle)
}

// Reinstalls the app from a copy of its installed bundle.
@(private = "file")
ios_reinstall :: proc(udid, app, bundle: string) -> Err {
	tmp, _ := os.temp_directory(context.temp_allocator)
	copy := fmt.tprintf("%s/%s-%d.app", strings.trim_right(tmp, "/"), app, os.get_pid())
	// An APFS clone (cp -c) when the temp folder is on the same volume: ~60 ms instead of
	// ~150 ms for a 60 MB app. Otherwise a plain copy.
	if !copy_app(bundle, copy, clone = true) && !copy_app(bundle, copy, clone = false) {
		return fmt.aprintf("could not copy %s", bundle)
	}
	defer os.remove_all(copy)
	simctl("uninstall", udid, app)
	if out, ok := simctl("install", udid, copy); !ok do return fmt.aprintf("could not reinstall %s: %s", app, out)
	return nil
}

@(private = "file")
copy_app :: proc(from, to: string, clone: bool) -> bool {
	os.remove_all(to)
	state, _, _, err := os.process_exec({command = {"cp", "-cR" if clone else "-R", from, to}}, context.temp_allocator)
	return err == nil && state.exited && state.exit_code == 0
}

@(private = "file")
Ios_App :: struct {
	bundle, data: string, // its .app, its data container
	groups:       [dynamic]string, // its app groups' containers
	shared:       map[string]bool, // those another app has too: reinstalling keeps them
}

// From `simctl listapps` (an old-style plist, as JSON through plutil): {bundle id: {Path:
// "/…/X.app", DataContainer: "file:///…/", GroupContainers: {"group.x": "file:///…/"}}}.
@(private = "file")
ios_app_info :: proc(udid, app: string) -> (info: Ios_App, err: string) {
	cmd := fmt.tprintf("xcrun simctl listapps '%s' | plutil -convert json -o - -", udid)
	state, out, stderr, perr := os.process_exec({command = {"/bin/sh", "-c", cmd}}, context.temp_allocator)
	if perr != nil || !state.success do return {}, strings.trim_space(string(stderr))
	v, jerr := json.parse(out, allocator = context.temp_allocator)
	if jerr != nil do return {}, "could not read xcrun simctl listapps"
	apps, _ := v.(json.Object)
	this, found := apps[app].(json.Object)
	if !found do return {}, "No application record found for that bundle identifier"
	info.bundle = plist_path(this["Path"].(json.String) or_else "")
	info.data = plist_path(this["DataContainer"].(json.String) or_else "")
	info.groups = make([dynamic]string, context.temp_allocator)
	info.shared = make(map[string]bool, 4, context.temp_allocator)
	mine := this["GroupContainers"].(json.Object) or_else nil
	for id, url in mine {
		path := plist_path(url.(json.String) or_else "")
		append(&info.groups, path)
		for other, o in apps {
			if other == app do continue
			theirs := o.(json.Object) or_else nil
			if _, has := (theirs["GroupContainers"].(json.Object) or_else nil)[id]; has do info.shared[path] = true
		}
	}
	if info.bundle == "" do return {}, fmt.tprintf("no Path for %s in xcrun simctl listapps", app)
	return info, ""
}

// "file:///a%20b/" -> /a b
@(private = "file")
plist_path :: proc(value: string) -> string {
	v := value
	if strings.has_prefix(v, "file://") {
		v = v[len("file://"):]
		if d, ok := net.percent_decode(v, context.temp_allocator); ok do v = d
	}
	return strings.trim_right(v, "/")
}

// Empties the app's folders and resets what reinstalling it would. Else why not (nothing
// done, or not all of it): it is reinstalled.
@(private = "file")
ios_empty_app :: proc(udid, app: string, info: Ios_App, notifications: string) -> (why: string) {
	home := os.get_env("HOME", context.temp_allocator)
	root := fmt.tprintf("%s/Library/Developer/CoreSimulator/Devices/%s/data", home, udid)
	// Only folders where simctl keeps this simulator's apps (not another device set).
	if !strings.has_prefix(info.data, fmt.tprintf("%s/Containers/Data/Application/", root)) do return fmt.tprintf("data container %s", info.data)
	groups := fmt.tprintf("%s/Containers/Shared/AppGroup/", root)
	for g in info.groups do if !strings.has_prefix(g, groups) do return fmt.tprintf("group container %s", g)

	// Notifications: allowed or denied (0 = never asked) as the launch will set them.
	status, pending, nok := ios_notification_state(root, app)
	if !nok do return "notification settings unread"
	if pending > 0 do return fmt.tprintf("%d notifications scheduled or delivered", pending)
	want := 2 if notifications == "allow" else 1 if notifications == "deny" else 0
	if status > 0 && status != want do return fmt.tprintf("notifications %d, launched with %q", status, notifications)

	extensions, eok := ios_extension_containers(root, info.bundle)
	if !eok do return "extensions unread"

	// TCC permissions (set again by the launch), location authorization.
	db := fmt.tprintf("%s/Library/TCC/TCC.db", root)
	sql := fmt.tprintf("DELETE FROM access WHERE client = %s AND client_type = 0;", sql_quote(app))
	if state, _, _, err := os.process_exec({command = {"sqlite3", "-cmd", ".timeout 5000", db, sql}}, context.temp_allocator); err != nil || !state.success do return "TCC database"
	if clients, ok := plist_read(fmt.tprintf("%s/Library/Caches/locationd/clients.plist", root)); ok {
		if _, has := plist_get(clients, fmt.tprintf("i%s:", app)); has {
			if out, rok := simctl("privacy", udid, "reset", "location-always", app); !rok do return out
		}
	}

	// cfprefsd serves an app group's preferences from its cache after their file is gone: they
	// are deleted through it (~350 ms per `simctl spawn`, all at once). It writes them as they
	// change, so a group without the file has none.
	domains := make([dynamic]string, context.temp_allocator)
	for g in info.groups {
		if info.shared[g] do continue
		entries, _ := os.read_all_directory_by_path(fmt.tprintf("%s/Library/Preferences", g), context.temp_allocator)
		for e in entries do if strings.has_suffix(e.name, ".plist") do append(&domains, strings.trim_suffix(e.fullpath, ".plist"))
	}
	spawns := make([dynamic]os.Process, context.temp_allocator)
	for d in domains {
		if p, err := os.process_start({command = {"xcrun", "simctl", "spawn", udid, "defaults", "delete", d}}); err == nil do append(&spawns, p)
	}
	for p in spawns do _, _ = os.process_wait(p)

	if !empty_container(info.data, APP_CONTAINER_DIRS) do return fmt.tprintf("could not empty %s", info.data)
	for dir in extensions do if !empty_container(dir, APP_CONTAINER_DIRS) do return fmt.tprintf("could not empty %s", dir)
	for dir in info.groups do if !info.shared[dir] && !empty_container(dir, GROUP_CONTAINER_DIRS) do return fmt.tprintf("could not empty %s", dir)
	return ""
}

// Removes all but the container's metadata and SplashBoard's launch screen snapshots, then
// makes `dirs` again.
@(private = "file")
empty_container :: proc(dir: string, dirs: []string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return false
	for e in entries {
		switch e.name {
		case CONTAINER_METADATA:
			continue
		case "Library":
			lib, lerr := os.read_all_directory_by_path(e.fullpath, context.temp_allocator)
			if lerr != nil do return false
			for l in lib do if l.name != "SplashBoard" && !remove_entry(l) do return false
			continue
		}
		if !remove_entry(e) do return false
	}
	for d in dirs do if e := os.make_directory_all(fmt.tprintf("%s/%s", dir, d)); e != nil && e != .Exist do return false
	return true
}

@(private = "file")
remove_entry :: proc(e: os.File_Info) -> bool {
	if e.type == .Directory do return os.remove_all(e.fullpath) == nil
	return os.remove(e.fullpath) == nil
}

// The app's notification authorization (-1: it never registered, 0: not asked yet, 1: denied,
// 2: allowed, 3: provisional) and how many notifications it has scheduled or delivered (in
// Notification Center). SpringBoard keeps the first in
// Library/BulletinBoard/VersionedSectionInfo.plist: {sectionInfo: {app: an archived
// BBSectionInfo}}; usernotificationsd the others in Library/UserNotifications: Library.plist
// archives {app: folder}, the folder's Pending- and DeliveredNotifications.plist arrays.
@(private = "file")
ios_notification_state :: proc(root, app: string) -> (status, pending: int, ok: bool) {
	status = -1
	path := fmt.tprintf("%s/Library/BulletinBoard/VersionedSectionInfo.plist", root)
	if os.exists(path) {
		bb := plist_read(path) or_return
		sections, _ := plist_get(bb, "sectionInfo")
		if blob, has := plist_get(sections, app); has {
			data := blob.([]u8) or_return
			archived := plist_parse(data) or_return
			status = -2
			objects := plist_get(archived, "$objects") or_return
			for o in objects.([]Plist) or_return {
				if v, vok := plist_get(o, "authorizationStatus"); vok {
					status = int(v.(i64) or_return)
					break
				}
			}
			if status == -2 do return 0, 0, false
		}
	}
	library := fmt.tprintf("%s/Library/UserNotifications/Library.plist", root)
	if !os.exists(library) do return status, 0, true
	folders := plist_unarchive(plist_read(library) or_return) or_return
	folder, has := plist_get(folders, app)
	if !has do return status, 0, true
	name := folder.(string) or_return
	for file in ([]string{"PendingNotifications.plist", "DeliveredNotifications.plist"}) {
		path := fmt.tprintf("%s/Library/UserNotifications/%s/%s", root, name, file)
		if !os.exists(path) do continue
		list := plist_unarchive(plist_read(path) or_return) or_return
		items := list.([]Plist) or_return
		pending += len(items)
	}
	return status, pending, true
}

// The data containers of the app's extensions (its .appex), which reinstalling empties too:
// in Containers/Data/PluginKitPlugin, named by their metadata's MCMMetadataIdentifier.
@(private = "file")
ios_extension_containers :: proc(root, bundle: string) -> (dirs: [dynamic]string, ok: bool) {
	dirs = make([dynamic]string, context.temp_allocator)
	ids := make(map[string]bool, 4, context.temp_allocator)
	for sub in ([]string{"PlugIns", "Extensions"}) {
		entries, _ := os.read_all_directory_by_path(fmt.tprintf("%s/%s", bundle, sub), context.temp_allocator)
		for e in entries {
			if !strings.has_suffix(e.name, ".appex") do continue
			plist := plist_read(fmt.tprintf("%s/Info.plist", e.fullpath)) or_return
			id := plist_get(plist, "CFBundleIdentifier") or_return
			ids[id.(string) or_return] = true
		}
	}
	if len(ids) == 0 do return dirs, true
	plugins := fmt.tprintf("%s/Containers/Data/PluginKitPlugin", root)
	entries, err := os.read_all_directory_by_path(plugins, context.temp_allocator)
	if err != nil do return dirs, !os.exists(plugins)
	for e in entries {
		// Binary plists, read here: hundreds of them, too many to convert any with plutil.
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", e.fullpath, CONTAINER_METADATA), context.temp_allocator)
		if rerr != nil do continue
		meta, mok := plist_parse(data)
		if !mok do continue
		id, iok := plist_get(meta, "MCMMetadataIdentifier")
		if !iok do continue
		if s, sok := id.(string); sok && ids[s] do append(&dirs, e.fullpath)
	}
	return dirs, true
}

// ---- Property lists ------------------------------------------------------------------------

// A property list value. Dates and reals read as f64.
@(private = "file")
Plist :: union {
	string,
	i64,
	f64,
	bool,
	[]u8,
	Plist_Uid,
	[]Plist,
	Plist_Dict,
}
@(private = "file")
Plist_Uid :: distinct u64
@(private = "file")
Plist_Dict :: struct {
	keys, values: []Plist,
}

// A plist file, binary as is, other formats through plutil.
@(private = "file")
plist_read :: proc(path: string) -> (p: Plist, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return nil, false
	if !strings.has_prefix(string(data), "bplist00") {
		state, out, _, perr := os.process_exec({command = {"plutil", "-convert", "binary1", "-o", "-", path}}, context.temp_allocator)
		if perr != nil || !state.success do return nil, false
		data = out
	}
	return plist_parse(data)
}

// dict[key], for a string key.
@(private = "file")
plist_get :: proc(p: Plist, key: string) -> (v: Plist, ok: bool) {
	d := p.(Plist_Dict) or_return
	for k, i in d.keys do if s, sok := k.(string); sok && s == key do return d.values[i], true
	return nil, false
}

// An NSKeyedArchiver archive's root: NSDictionary as a Plist_Dict, NSArray as []Plist, with
// their members resolved (one level: what is read here).
@(private = "file")
plist_unarchive :: proc(archive: Plist) -> (v: Plist, ok: bool) {
	objects := plist_get(archive, "$objects") or_return
	objs := objects.([]Plist) or_return
	resolve :: proc(objs: []Plist, p: Plist) -> (Plist, bool) {
		uid, is_uid := p.(Plist_Uid)
		if !is_uid do return p, true
		if int(uid) >= len(objs) do return nil, false
		return objs[uid], true
	}
	top := plist_get(archive, "$top") or_return
	root := resolve(objs, plist_get(top, "root") or_return) or_return
	if name, is_string := root.(string); is_string && name == "$null" do return []Plist{}, true // an empty one
	members :: proc(objs: []Plist, p: Plist, key: string) -> (out: []Plist, ok: bool) {
		v := plist_get(p, key) or_return
		list := v.([]Plist) or_return
		out = make([]Plist, len(list), context.temp_allocator)
		for m, i in list {
			uid := m.(Plist_Uid) or_return
			if int(uid) >= len(objs) do return nil, false
			out[i] = objs[uid]
		}
		return out, true
	}
	values := members(objs, root, "NS.objects") or_return
	if _, has := plist_get(root, "NS.keys"); !has do return values, true
	keys := members(objs, root, "NS.keys") or_return
	if len(keys) != len(values) do return nil, false
	return Plist_Dict{keys, values}, true
}

// A binary plist (bplist00): objects, an offset table, then a 32-byte trailer.
@(private = "file")
plist_parse :: proc(data: []u8) -> (p: Plist, ok: bool) {
	if len(data) < 40 || string(data[:8]) != "bplist00" do return nil, false
	t := data[len(data) - 32:]
	offset_size, ref_size := int(t[6]), int(t[7])
	count, top, table := be_uint(t[8:16]), be_uint(t[16:24]), be_uint(t[24:32])
	if offset_size == 0 || ref_size == 0 || count > u64(len(data)) || top >= count || table + count * u64(offset_size) > u64(len(data)) do return nil, false
	b := Bplist{data, int(table), offset_size, ref_size, int(count)}
	return bplist_object(&b, int(top), 0)
}

@(private = "file")
Bplist :: struct {
	data:                   []u8,
	table, offset_size:     int,
	ref_size, count:        int,
}

@(private = "file")
be_uint :: proc(b: []u8) -> (v: u64) {
	for x in b do v = v << 8 | u64(x)
	return
}

@(private = "file")
bplist_object :: proc(b: ^Bplist, index, depth: int) -> (p: Plist, ok: bool) {
	if index < 0 || index >= b.count || depth > 32 do return nil, false
	at := b.table + index * b.offset_size
	off := int(be_uint(b.data[at:at + b.offset_size]))
	if off >= len(b.data) do return nil, false
	marker := b.data[off]
	kind, info := marker >> 4, int(marker & 0xF)
	pos := off + 1
	// A length: in the marker, or (0xF) an int object after it.
	length := info
	if info == 0xF && (kind == 0x4 || kind == 0x5 || kind == 0x6 || kind == 0xA || kind == 0xC || kind == 0xD) {
		if pos >= len(b.data) || b.data[pos] >> 4 != 0x1 do return nil, false
		n := 1 << (b.data[pos] & 0xF)
		if pos + 1 + n > len(b.data) do return nil, false
		length = int(be_uint(b.data[pos + 1:pos + 1 + n]))
		pos += 1 + n
	}
	need :: proc(b: ^Bplist, pos, n: int) -> bool {return n >= 0 && pos + n <= len(b.data)}
	switch kind {
	case 0x0:
		switch marker {
		case 0x08: return false, true
		case 0x09: return true, true
		}
		return nil, true
	case 0x1:
		n := 1 << uint(info)
		if !need(b, pos, n) do return nil, false
		return i64(be_uint(b.data[pos:pos + n])), true
	case 0x2, 0x3:
		n := 1 << uint(info)
		if !need(b, pos, n) do return nil, false
		bits := be_uint(b.data[pos:pos + n])
		if n == 4 do return f64(transmute(f32)u32(bits)), true
		return transmute(f64)bits, true
	case 0x4:
		if !need(b, pos, length) do return nil, false
		return b.data[pos:pos + length], true
	case 0x5:
		if !need(b, pos, length) do return nil, false
		return string(b.data[pos:pos + length]), true
	case 0x6:
		if !need(b, pos, 2 * length) do return nil, false
		units := make([]u16, length, context.temp_allocator)
		for &u, i in units do u = u16(be_uint(b.data[pos + 2 * i:pos + 2 * i + 2]))
		out := make([]u8, 4 * length, context.temp_allocator)
		return string(out[:utf16.decode_to_utf8(out, units)]), true
	case 0x8:
		if !need(b, pos, info + 1) do return nil, false
		return Plist_Uid(be_uint(b.data[pos:pos + info + 1])), true
	case 0xA, 0xC:
		if !need(b, pos, length * b.ref_size) do return nil, false
		list := make([]Plist, length, context.temp_allocator)
		for &v, i in list {
			r := pos + i * b.ref_size
			v = bplist_object(b, int(be_uint(b.data[r:r + b.ref_size])), depth + 1) or_return
		}
		return list, true
	case 0xD:
		if !need(b, pos, 2 * length * b.ref_size) do return nil, false
		d := Plist_Dict{make([]Plist, length, context.temp_allocator), make([]Plist, length, context.temp_allocator)}
		for i in 0 ..< length {
			k, v := pos + i * b.ref_size, pos + (length + i) * b.ref_size
			d.keys[i] = bplist_object(b, int(be_uint(b.data[k:k + b.ref_size])), depth + 1) or_return
			d.values[i] = bplist_object(b, int(be_uint(b.data[v:v + b.ref_size])), depth + 1) or_return
		}
		return d, true
	}
	return nil, false
}
