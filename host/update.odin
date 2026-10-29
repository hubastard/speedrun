// speedrun update: replaces this install with the latest release (or a given one), running
// install.sh from the repository into the folder this binary is in.
package speedrun

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

UPDATE_USAGE :: `usage: speedrun update [version]
Replaces this speedrun (and its iOS agent) with the latest release, or the one named
(speedrun update v0.1.7), in the folder it is installed in.`

run_update_cli :: proc(args: []string) -> int {
	if len(args) > 1 || (len(args) == 1 && strings.has_prefix(args[0], "-")) {
		fmt.println(UPDATE_USAGE)
		return 0 if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") else 2
	}
	exe, eerr := os.get_executable_path(context.temp_allocator)
	if eerr != nil {
		fmt.eprintln("could not find where speedrun is installed")
		return 1
	}
	dir := os.dir(exe)
	if homebrew_install() {
		fmt.eprintln("This speedrun was installed with Homebrew: brew upgrade speedrun")
		return 1
	}
	// A build from source: its folder holds the sources, whose agent/ install.sh would
	// replace.
	if os.exists(fmt.tprintf("%s/build.sh", dir)) || os.exists(fmt.tprintf("%s/host", dir)) {
		fmt.eprintf("This speedrun was built from source (%s): update it with git pull, then ./build.sh.\n", dir)
		return 1
	}
	repo := update_repo()
	version := args[0] if len(args) == 1 else ""
	if version == "" {
		latest, err := latest_release(repo)
		if err != "" {
			fmt.eprintln(err)
			return 1
		}
		if latest == VERSION {
			fmt.printf("speedrun %s is the latest release.\n", VERSION)
			return 0
		}
		version = latest
		fmt.printf("Updating speedrun %s to %s...\n", VERSION, latest)
	}
	environ, _ := os.environ(context.temp_allocator)
	env := make([dynamic]string, 0, len(environ) + 4, context.temp_allocator)
	append(&env, ..environ)
	append(&env, fmt.tprintf("SPEEDRUN_DIR=%s", dir), "SPEEDRUN_NO_MODIFY_PATH=1", fmt.tprintf("SPEEDRUN_VERSION=%s", version), fmt.tprintf("SPEEDRUN_REPO=%s", repo))
	script := fmt.tprintf("curl -fsSL https://raw.githubusercontent.com/%s/main/install.sh | bash", repo)
	p, perr := os.process_start({command = {"bash", "-c", script}, env = env[:], stdout = os.stdout, stderr = os.stderr})
	if perr != nil {
		fmt.eprintf("could not run the installer: %v\n", perr)
		return 1
	}
	state, werr := os.process_wait(p)
	if werr != nil || !state.success do return 1
	if info, running := session_running(); running {
		fmt.printf("A session is running on the previous version (%s): speedrun session stop, then start one.\n", info.device)
	}
	return 0
}

// The latest release's tag, from GitHub's API.
@(private = "file")
latest_release :: proc(repo: string) -> (tag: string, err: string) {
	state, out, _, perr := os.process_exec({command = {"curl", "-fsSL", fmt.tprintf("https://api.github.com/repos/%s/releases/latest", repo)}}, context.temp_allocator)
	if perr != nil || !state.success do return "", fmt.tprintf("could not find speedrun's latest release (https://github.com/%s/releases)", repo)
	v, jerr := json.parse(out, allocator = context.temp_allocator)
	if jerr != nil do return "", "could not read GitHub's answer about the latest release"
	obj, _ := v.(json.Object)
	name, _ := obj["tag_name"].(json.String)
	if name == "" do return "", "GitHub's answer names no latest release"
	return name, ""
}

@(private = "file")
update_repo :: proc() -> string {
	repo := os.get_env("SPEEDRUN_REPO", context.temp_allocator)
	return repo if repo != "" else "hubastard/speedrun"
}

// ---- a newer release ------------------------------------------------------------------------

// speedrun test, session start and --version end with a line when a newer release is out.
// GitHub is asked at most once a day, in the background (a command never waits for it), and
// its answer kept in the state folder: read as the command ends, it reports a release from
// the run that asked if the answer came by then, else from the next one. Off with
// SPEEDRUN_NO_UPDATE_CHECK=1, on CI (CI set: a new machine each run, installing the latest
// anyway) and for builds from source (no release version).
UPDATE_CHECK_INTERVAL :: 24 * time.Hour

@(private = "file")
latest_release_path :: proc() -> string {
	if xdg := os.get_env("XDG_STATE_HOME", context.temp_allocator); xdg != "" do return fmt.tprintf("%s/speedrun/latest-release.json", xdg)
	return fmt.tprintf("%s/.speedrun/latest-release.json", os.get_env("HOME", context.temp_allocator))
}

@(private = "file")
update_check_on :: proc() -> bool {
	_, release := release_version(VERSION)
	return release && os.get_env("SPEEDRUN_NO_UPDATE_CHECK", context.temp_allocator) == "" && os.get_env("CI", context.temp_allocator) == ""
}

// Asks GitHub for the latest release when the last answer is a day old or missing: curl in
// the background, left to finish if speedrun exits first.
update_check_start :: proc() {
	if !update_check_on() do return
	path := latest_release_path()
	if info, err := os.stat(path, context.temp_allocator); err == nil && time.since(info.modification_time) < UPDATE_CHECK_INTERVAL do return
	_ = os.make_directory_all(os.dir(path), {.Read_User, .Write_User, .Execute_User})
	null, nerr := os.open("/dev/null", {.Read, .Write})
	if nerr != nil do return
	defer os.close(null)
	// Whole or not at all (mv): the end of a command can read it while curl writes.
	script := `curl -fsS --max-time 10 "$1" -o "$2.part" && mv "$2.part" "$2"`
	url := fmt.tprintf("https://api.github.com/repos/%s/releases/latest", update_repo())
	_, _ = os.process_start({command = {"sh", "-c", script, "sh", url, path}, stdin = null, stdout = null, stderr = null})
}

// The line saying a newer release is out, from the last answer: "" when there is none (or no
// answer yet).
update_notice :: proc() -> string {
	if !update_check_on() do return ""
	data, err := os.read_entire_file(latest_release_path(), context.temp_allocator)
	if err != nil do return ""
	v, jerr := json.parse(data, allocator = context.temp_allocator)
	if jerr != nil do return ""
	obj, _ := v.(json.Object)
	tag, _ := obj["tag_name"].(json.String)
	latest, lok := release_version(tag)
	current, _ := release_version(VERSION)
	if !lok || !(latest[0] > current[0] || (latest[0] == current[0] && (latest[1] > current[1] || (latest[1] == current[1] && latest[2] > current[2])))) do return ""
	return fmt.tprintf("speedrun %s is out (this is %s): %s", tag, VERSION, "brew upgrade speedrun" if homebrew_install() else "speedrun update")
}

// Installed by Homebrew: the binary (its real path, links resolved) is in a Cellar, which
// Homebrew alone changes.
@(private = "file")
homebrew_install :: proc() -> bool {
	exe, err := os.get_executable_path(context.temp_allocator)
	return err == nil && strings.contains(exe, "/Cellar/speedrun/")
}

// v<major>.<minor>.<patch> and nothing else: a build from source names its commit after it.
@(private = "file")
release_version :: proc(s: string) -> (v: [3]int, ok: bool) {
	if !strings.has_prefix(s, "v") do return
	parts := strings.split(s[1:], ".", context.temp_allocator)
	if len(parts) != 3 do return
	for p, i in parts {
		if p == "" || len(p) > 6 do return
		for c in p do if c < '0' || c > '9' do return
		v[i], _ = strconv.parse_int(p)
	}
	return v, true
}
