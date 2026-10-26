// Which flows `speedrun test` runs: a single flow file runs as is; files and directories
// (walked recursively) are filtered by the workspace config's `flows` globs (default "*": the
// top level of each directory), by tags, and split into the `executionOrder` sequence and the
// rest. The order: the given files, then each directory as the file system lists it, depth
// first (as Java's Files.walk does).
package speedrun

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:text/regex"

Workspace_Config :: struct {
	flows:                      [dynamic]string, // globs, "!" excludes; empty: "*"
	include_tags, exclude_tags: [dynamic]string,
	flows_order:                [dynamic]string, // executionOrder.flowsOrder
	continue_on_failure:        bool, // executionOrder.continueOnFailure (default true)
	test_output_dir:            string,
}

Plan :: struct {
	flows:               [dynamic]string, // run after the sequence, in this order
	sequence:            [dynamic]string, // executionOrder: run first, in this order
	continue_on_failure: bool,
	config:              Workspace_Config,
}

// Keys of a workspace config: a YAML file with only these (and no `---`) is a
// workspace config, never a flow.
WORKSPACE_KEYS :: []string {
	"flows", "includeTags", "excludeTags", "executionOrder", "baselineBranch", "notifications",
	"disableRetries", "platform", "testOutputDir",
}

workspace_plan :: proc(
	inputs: []string,
	include_tags, exclude_tags: []string,
	config_path: string,
	alloc: mem.Allocator,
) -> (
	plan: Plan,
	err: Err,
) {
	context.allocator = alloc
	plan.continue_on_failure = true
	abs := make([]string, len(inputs))
	for p, i in inputs {
		abs[i] = absolute(p)
		if !os.exists(abs[i]) do return plan, fmt.aprintf("Flow path does not exist: %s", abs[i])
	}
	config := strings.clone(absolute(config_path)) if config_path != "" else ""

	if len(abs) == 1 && os.is_file(abs[0]) {
		if _, e := load_flow(abs[0], alloc); e != "" do return plan, e
		if config != "" do plan.config = read_workspace_config(config) or_return
		plan.continue_on_failure = plan.config.continue_on_failure
		append(&plan.flows, abs[0])
		return plan, nil
	}

	files, dirs: [dynamic]string
	for p in abs {
		if os.is_dir(p) do append(&dirs, strings.trim_right(p, "/"))
		else do append(&files, p)
	}
	if config == "" {
		for d in dirs {
			for name in ([]string{"config.yaml", "config.yml"}) {
				candidate := fmt.aprintf("%s/%s", d, name)
				if os.exists(candidate) {
					config = candidate
					break
				}
			}
			if config != "" do break
		}
	}
	found: [dynamic]string
	for f in files do if is_flow_file(f, config) do append(&found, f)
	in_dirs: [dynamic]string
	for d in dirs do walk_flow_files(d, config, &in_dirs)
	if len(found) == 0 && len(in_dirs) == 0 {
		return plan, fmt.aprintf("Flow directories do not contain any Flow files: %s", strings.join(dirs[:], ", "))
	}

	cfg: Workspace_Config
	cfg.continue_on_failure = true
	if config != "" do cfg = read_workspace_config(config) or_return
	plan.config = cfg
	plan.continue_on_failure = cfg.continue_on_failure
	globs := cfg.flows[:] if len(cfg.flows) > 0 else []string{"*"}
	positive, negative: [dynamic]string
	for g in globs {
		if strings.has_prefix(g, "!") do append(&negative, g[1:])
		else do append(&positive, g)
	}
	if len(positive) == 0 && len(negative) > 0 {
		b := strings.builder_make()
		strings.write_string(&b, "Flow inclusion patterns contain only negation patterns, so no Flows would match:\n")
		for g in negative do fmt.sbprintf(&b, "- !%s\n", g)
		strings.write_string(&b, "\nAdd a positive pattern to select the Flows to run. For example, to run all Flows except the negated ones:\n\nflows:\n  - \"*\"\n")
		for g in negative do fmt.sbprintf(&b, "  - \"!%s\"\n", g)
		return plan, strings.trim_right(strings.to_string(b), "\n")
	}
	pos := glob_matchers(dirs[:], positive[:]) or_return
	neg := glob_matchers(dirs[:], negative[:]) or_return
	defer {
		for &m in pos do regex.destroy(m)
		for &m in neg do regex.destroy(m)
	}
	candidates: [dynamic]string
	append(&candidates, ..found[:])
	for f in in_dirs {
		if matches_any(pos[:], f) && !matches_any(neg[:], f) do append(&candidates, f)
	}
	if len(candidates) == 0 {
		if len(globs) == 1 && globs[0] == "*" {
			return plan, fmt.aprintf(
				"Top-level directories do not contain any Flows: %s\nTo run flows in subdirectories, list them under `flows:` in the workspace config (config.yaml), e.g. `flows: [\"subfolder/*\"]`.",
				strings.join(dirs[:], ", "),
			)
		}
		b := strings.builder_make()
		strings.write_string(&b, "Flow inclusion pattern(s) did not match any Flow files:")
		for g in positive do fmt.sbprintf(&b, "\n- %s", g)
		return plan, strings.to_string(b)
	}

	// Tags (each flow is loaded, which also validates it).
	all_include, all_exclude: [dynamic]string
	append(&all_include, ..include_tags)
	append(&all_include, ..cfg.include_tags[:])
	append(&all_exclude, ..exclude_tags)
	append(&all_exclude, ..cfg.exclude_tags[:])
	kept: [dynamic]string
	names: map[string]string // flow name -> path, for executionOrder
	for f in candidates {
		flow, e := load_flow(f, alloc)
		if e != "" do return plan, e
		has_any :: proc(tags, wanted: []string) -> bool {
			for t in tags do if slice.contains(wanted, t) do return true
			return false
		}
		if len(all_include) > 0 && !has_any(flow.tags[:], all_include[:]) do continue
		if len(all_exclude) > 0 && has_any(flow.tags[:], all_exclude[:]) do continue
		append(&kept, f)
		names[flow.name if flow.name != "" else flow_file_name(f)] = f
	}
	if len(kept) == 0 {
		b := strings.builder_make()
		strings.write_string(&b, "Include / Exclude tags did not match any Flows:\n\nInclude Tags:\n")
		for t in all_include do fmt.sbprintf(&b, "- %s\n", t)
		strings.write_string(&b, "\nExclude Tags:\n")
		for t in all_exclude do fmt.sbprintf(&b, "- %s\n", t)
		return plan, strings.trim_right(strings.to_string(b), "\n")
	}

	// executionOrder (ExecutionOrderPlanner): the longest prefix of flowsOrder whose flows are
	// all present runs first, in that order; none when no ordered flow is present; an error
	// when some are but not the first.
	any_present := false
	for name in cfg.flows_order do if name in names do any_present = true
	if any_present {
		in_order := 0
		for name in cfg.flows_order {
			if name not_in names do break
			in_order += 1
		}
		if in_order == 0 {
			missing: [dynamic]string
			for name in cfg.flows_order do if name not_in names do append(&missing, name)
			return plan, fmt.aprintf("Could not find flows needed for execution in order: %s", strings.join(missing[:], ", "))
		}
		for name in cfg.flows_order[:in_order] do append(&plan.sequence, names[name])
	}
	for f in kept do if !slice.contains(plan.sequence[:], f) do append(&plan.flows, f)
	return plan, nil
}

// The file name without its extension (a flow's default name, and MAESTRO_FILENAME).
flow_file_name :: proc(path: string) -> string {
	base := path[strings.last_index_byte(path, '/') + 1:]
	if i := strings.last_index_byte(base, '.'); i > 0 do return base[:i]
	return base
}

absolute :: proc(path: string) -> string {
	if strings.has_prefix(path, "/") do return strings.clone(path)
	cwd, _ := os.get_working_directory(context.allocator)
	p := strings.trim_prefix(path, "./")
	return fmt.aprintf("%s/%s", cwd, p)
}

@(private = "file")
walk_flow_files :: proc(dir, config: string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return
	for e in entries {
		path := fmt.aprintf("%s/%s", dir, e.name)
		if e.type == .Directory {
			walk_flow_files(path, config, out)
		} else if is_flow_file(path, config) {
			append(out, path)
		}
	}
}

// A flow file: a .yaml/.yml file other than the workspace config.
@(private = "file")
is_flow_file :: proc(path, config: string) -> bool {
	if !os.is_file(path) || path == config do return false
	if !strings.has_suffix(path, ".yaml") && !strings.has_suffix(path, ".yml") do return false
	if flow_file_name(path) == "config" do return false
	return !is_workspace_config_file(path)
}

@(private = "file")
is_workspace_config_file :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return false
	text := string(data)
	if strings.contains(text, "\n---") do return false // a flow: config, then commands
	docs, yerr, _ := yaml_parse(text, context.temp_allocator)
	if yerr != "" || len(docs) != 1 || docs[0].kind != .Map do return false
	for key in docs[0].keys do if !slice.contains(WORKSPACE_KEYS, key) do return false
	return true
}

@(private = "file")
read_workspace_config :: proc(path: string) -> (cfg: Workspace_Config, err: Err) {
	cfg.continue_on_failure = true
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil do return cfg, fmt.aprintf("The config file %s does not exist.", path)
	if strings.trim_space(string(data)) == "" do return cfg, nil
	docs, yerr, yline := yaml_parse(string(data), context.allocator)
	if yerr != "" do return cfg, fmt.aprintf("%s:%d: %s", path, yline, yerr)
	if len(docs) == 0 || docs[0].kind == .Null do return cfg, nil
	if docs[0].kind != .Map do return cfg, fmt.aprintf("%s: the workspace config must be a map", path)
	root := docs[0]
	unknown: [dynamic]string
	for key, i in root.keys {
		v := root.vals[i]
		switch key {
		case "flows":
			string_list(v, &cfg.flows) or_return
		case "includeTags":
			string_list(v, &cfg.include_tags) or_return
		case "excludeTags":
			string_list(v, &cfg.exclude_tags) or_return
		case "testOutputDir":
			if v.kind == .Scalar do cfg.test_output_dir = v.text
		case "executionOrder":
			if v.kind != .Map do continue
			for k2, j in v.keys {
				switch k2 {
				case "flowsOrder":
					string_list(v.vals[j], &cfg.flows_order) or_return
				case "continueOnFailure":
					cfg.continue_on_failure = v.vals[j].kind != .Scalar || v.vals[j].text != "false"
				}
			}
		case "baselineBranch", "notifications", "disableRetries", "platform":
		// Cloud and device set-up keys: nothing to do here.
		case:
			append(&unknown, key)
		}
	}
	if len(unknown) > 0 {
		fmt.eprintf("Config file '%s' contains unknown keys: %s\n", path, strings.join(unknown[:], ", "))
	}
	return cfg, nil

	string_list :: proc(v: ^Yaml, out: ^[dynamic]string) -> Err {
		#partial switch v.kind {
		case .Scalar:
			append(out, v.text)
		case .Seq:
			for item in v.items {
				if item.kind != .Scalar do return "expected a list of strings"
				append(out, item.text)
			}
		case .Null:
		case:
			return "expected a string or a list of strings"
		}
		return nil
	}
}

// Java PathMatcher "glob:" patterns, anchored at each directory: * stays within a path
// segment, ** crosses them, ?, [...] ([!...] negates) and {a,b} as in Java.
@(private = "file")
glob_matchers :: proc(dirs, globs: []string) -> (out: [dynamic]regex.Regular_Expression, err: Err) {
	for g in globs {
		for d in dirs {
			pattern := fmt.aprintf("^(?:%s)$", glob_to_regex(fmt.aprintf("%s/%s", d, g)))
			re, rerr := regex.create(pattern)
			if rerr != nil do return out, fmt.aprintf("invalid flows pattern %q", g)
			append(&out, re)
		}
	}
	return out, nil
}

@(private = "file")
glob_to_regex :: proc(glob: string) -> string {
	b := strings.builder_make()
	in_group := false
	for i := 0; i < len(glob); i += 1 {
		c := glob[i]
		switch c {
		case '\\':
			if i + 1 < len(glob) {
				i += 1
				write_literal(&b, glob[i])
			}
		case '*':
			if i + 1 < len(glob) && glob[i + 1] == '*' {
				strings.write_string(&b, ".*")
				i += 1
			} else {
				strings.write_string(&b, "[^/]*")
			}
		case '?':
			strings.write_string(&b, "[^/]")
		case '[':
			strings.write_byte(&b, '[')
			i += 1
			if i < len(glob) && glob[i] == '!' {
				strings.write_byte(&b, '^')
				i += 1
			}
			for i < len(glob) && glob[i] != ']' {
				if glob[i] == '\\' || glob[i] == '[' do strings.write_byte(&b, '\\')
				strings.write_byte(&b, glob[i])
				i += 1
			}
			strings.write_byte(&b, ']')
		case '{':
			strings.write_string(&b, "(?:")
			in_group = true
		case '}':
			if in_group {
				strings.write_byte(&b, ')')
				in_group = false
			} else {
				write_literal(&b, c)
			}
		case ',':
			if in_group do strings.write_byte(&b, '|')
			else do write_literal(&b, c)
		case:
			write_literal(&b, c)
		}
	}
	return strings.to_string(b)

	write_literal :: proc(b: ^strings.Builder, c: u8) {
		if strings.index_byte(".^$+()|[]{}\\*?", c) >= 0 do strings.write_byte(b, '\\')
		strings.write_byte(b, c)
	}
}

@(private = "file")
matches_any :: proc(matchers: []regex.Regular_Expression, path: string) -> bool {
	for m in matchers {
		if _, ok := regex.match(m, path, context.temp_allocator, context.temp_allocator); ok do return true
	}
	return false
}
