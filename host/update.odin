// speedrun update: replaces this install with the latest release (or a given one), running
// install.sh from the repository into the folder this binary is in.
package speedrun

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

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
	// A build from source: its folder holds the sources, whose agent/ install.sh would
	// replace.
	if os.exists(fmt.tprintf("%s/build.sh", dir)) || os.exists(fmt.tprintf("%s/host", dir)) {
		fmt.eprintf("This speedrun was built from source (%s): update it with git pull, then ./build.sh.\n", dir)
		return 1
	}
	repo := os.get_env("SPEEDRUN_REPO", context.temp_allocator)
	if repo == "" do repo = "hubastard/speedrun"
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
