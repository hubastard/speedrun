// --format html / html-detailed: a Bootstrap page (cards: the
// suite's summary, then a collapsible card per flow; the detailed one adds every step).
package speedrun

import "core:c/libc"
import "core:fmt"
import "core:strings"

@(private = "file")
DETAILED_CSS :: `.step-item {
    border-left: 3px solid #dee2e6;
    padding-left: 12px;
    padding-top: 8px;
    padding-bottom: 8px;
}

.step-header {
    font-family: monospace;
    font-size: 14px;
}

.step-name {
    font-weight: 500;
}
`

html_report :: proc(suites: []Suite_Result, detailed: bool) -> string {
	b := strings.builder_make()
	w :: proc(b: ^strings.Builder, args: ..any) {
		for a in args do fmt.sbprint(b, a)
	}
	w(&b, "<html>\n  <head>\n    <title>Test Report</title>\n",
		"    <link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css\" integrity=\"sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH\" crossorigin=\"anonymous\">\n",
		"  </head>\n  <body>\n")
	for &s in suites {
		failed := 0
		for f in s.flows do if !f.passed do failed += 1
		w(&b, "    <div class=\"card mb-4\">\n      <div class=\"card-body\">\n",
			"        <h1 class=\"mt-5 text-center\">Flow Execution Summary</h1>\n        <br>",
			"Test Result: ", "PASSED" if s.passed else "FAILED", "<br>Duration: ", kotlin_duration(s.duration_ms), "<br>")
		w(&b, "Start Time: ", time_element(s.start_unix_ms), "<br><br>\n")
		w(&b, "        <div class=\"card-group mb-4\">\n")
		card :: proc(b: ^strings.Builder, classes, title: string, n: int) {
			fmt.sbprintf(b, "          <div class=\"%s\">\n            <div class=\"card-body\">\n", classes)
			fmt.sbprintf(b, "              <h5 class=\"card-title text-center\">%s</h5>\n", title)
			fmt.sbprintf(b, "              <h3 class=\"card-text text-center\">%d</h3>\n            </div>\n          </div>\n", n)
		}
		card(&b, "card", "Total number of Flows", len(s.flows))
		card(&b, "card text-white bg-danger", "Failed Flows", failed)
		card(&b, "card text-white bg-success", "Successful Flows", len(s.flows) - failed)
		w(&b, "        </div>\n")
		if failed > 0 {
			w(&b, "        <div class=\"card border-danger mb-3\">\n          <div class=\"card-body text-danger\"><b>Failed Flow</b><br>\n",
				"            <p class=\"card-text\">")
			for f in s.flows do if !f.passed do w(&b, html_escape(f.name), "<br>")
			w(&b, "</p>\n          </div>\n        </div>\n")
		}
		for &f, index in s.flows {
			status := "SUCCESS" if f.passed else "ERROR"
			id := fmt.tprintf("flow-%d-%s", index, html_id(f.name))
			w(&b, "        <div class=\"card mb-4\">\n          <div class=\"card-header\">\n            <h5 class=\"mb-0\">",
				"<button class=\"", "btn btn-success" if f.passed else "btn btn-danger",
				"\" type=\"button\" data-bs-toggle=\"collapse\" data-bs-target=\"#", id,
				"\" aria-expanded=\"false\" aria-controls=\"", id, "\">", html_escape(f.name), " : ", status,
				"</button></h5>\n          </div>\n")
			w(&b, "          <div class=\"collapse\" id=\"", id, "\">\n            <div class=\"card-body\">\n",
				"              <p class=\"card-text\">Status: ", status, "<br>Duration: ", kotlin_duration(f.duration_ms),
				"<br>Start Time: ", time_element(f.start_unix_ms), "<br>File Name: ", html_escape(flow_file_name(f.file_path)), "<br>")
			if len(f.tags) > 0 {
				w(&b, "Tags: ")
				for t in f.tags do w(&b, "<span class=\"badge bg-primary me-1\">", html_escape(t), "</span>")
				w(&b, "<br>")
			}
			w(&b, "</p>\n")
			if len(f.properties) > 0 {
				w(&b, "              <h6 class=\"mt-3 mb-2\">Properties</h6>\n              <div class=\"table-responsive\">\n",
					"                <table class=\"table table-sm table-bordered\">\n",
					"                  <thead>\n                    <tr>\n                      <th>Property</th>\n                      <th>Value</th>\n                    </tr>\n                  </thead>\n",
					"                  <tbody>\n")
				for p in f.properties {
					w(&b, "                    <tr>\n                      <td>", html_escape(p.key), "</td>\n                      <td>",
						html_escape(p.value), "</td>\n                    </tr>\n")
				}
				w(&b, "                  </tbody>\n                </table>\n              </div>\n")
			}
			if !f.passed do w(&b, "              <p class=\"card-text text-danger\">", html_escape(f.error if f.error != "" else "Unknown error"), "</p>\n")
			if detailed && len(f.steps) > 0 {
				w(&b, "              <h6 class=\"mt-3 mb-3\">Test Steps (", len(f.steps), ")</h6>\n")
				for st in f.steps {
					icon := "⚪"
					switch st.status {
					case "COMPLETED": icon = "✅"
					case "WARNED":    icon = "⚠️"
					case "FAILED":    icon = "❌"
					case "SKIPPED":   icon = "⏭️"
					}
					w(&b, "              <div class=\"step-item mb-2\">\n",
						"                <div class=\"step-header d-flex justify-content-between align-items-center\"><span>", icon,
						" <span class=\"step-name\">", html_escape(st.description), "</span></span><span class=\"badge bg-light text-dark\">",
						st.duration, "</span></div>\n              </div>\n")
				}
			}
			w(&b, "            </div>\n          </div>\n        </div>\n")
		}
		w(&b, "      </div>\n")
		if detailed do w(&b, "      <style>", DETAILED_CSS, "</style>\n")
		w(&b, "      <script src=\"https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.min.js\" integrity=\"sha384-0pUGZvbkm6XF6gxjEnlmuGrJXVbNuzT9qBBavbLwCsOGabYfZo0T0to5eqruptLy\" crossorigin=\"anonymous\"></script>\n    </div>\n")
	}
	w(&b, "  </body>\n</html>\n")
	return strings.to_string(b)
}

// Kotlin's Duration.toString: "850ms", "24.764s", "1m 1.5s", "1h 0m 5s".
kotlin_duration :: proc(ms: f64) -> string {
	total := i64(ms)
	if total < 1000 do return fmt.tprintf("%dms", total)
	h, m := total / 3_600_000, total % 3_600_000 / 60_000
	sec := fmt.tprintf("%.3f", f64(total % 60_000) / 1000)
	sec = strings.trim_right(strings.trim_right(sec, "0"), ".")
	parts: [dynamic]string
	parts.allocator = context.temp_allocator
	if h > 0 do append(&parts, fmt.tprintf("%dh", h))
	if h > 0 || m > 0 do append(&parts, fmt.tprintf("%dm", m))
	if sec != "0" || len(parts) == 0 do append(&parts, fmt.tprintf("%ss", sec))
	// Kotlin leaves out trailing zero components: "1m", "1h 0m" -> "1h".
	for len(parts) > 1 && (parts[len(parts) - 1] == "0m") do pop(&parts)
	return strings.join(parts[:], " ", context.temp_allocator)
}

// <time datetime="ISO_OFFSET_DATE_TIME">MMM d, yyyy, HH:mm:ss z</time>, in the local zone.
@(private = "file")
time_element :: proc(unix_ms: i64) -> string {
	t := libc.time_t(unix_ms / 1000)
	tm := libc.localtime(&t)
	if tm == nil do return ""
	iso, human, zone: [64]u8
	libc.strftime(raw_data(iso[:]), len(iso), "%Y-%m-%dT%H:%M:%S", tm)
	libc.strftime(raw_data(zone[:]), len(zone), "%z", tm)
	libc.strftime(raw_data(human[:]), len(human), "%b %-d, %Y, %H:%M:%S %Z", tm)
	z := string(cstring(raw_data(zone[:])))
	offset := fmt.tprintf("%s:%s", z[:3], z[3:]) if len(z) == 5 else z
	millis := unix_ms % 1000
	frac := fmt.tprintf(".%03d", millis) if millis != 0 else ""
	return fmt.tprintf("<time datetime=\"%s%s%s\">%s</time>", string(cstring(raw_data(iso[:]))), frac, offset, string(cstring(raw_data(human[:]))))
}

@(private = "file")
html_escape :: proc(s: string) -> string {
	return xml_escape(s, attribute = false)
}

// The flow name with characters outside [a-zA-Z0-9_-] replaced by "-".
@(private = "file")
html_id :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		strings.write_rune(&b, c if ok else '-')
	}
	return strings.to_string(b)
}
