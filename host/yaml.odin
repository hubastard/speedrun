// A YAML reader for Maestro flow files: block mappings and sequences, plain, quoted and
// block (| >) scalars, flow collections ([a, b], {k: v}), comments and `---` documents.
// Anchors, aliases and tags are rejected with the line number, never silently misread.
// Scalars stay text; the flow layer converts them per field (bool, int, string).
package speedrun

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Yaml_Kind :: enum u8 {
	Null,
	Scalar,
	Seq,
	Map,
}

Yaml :: struct {
	kind:   Yaml_Kind,
	text:   string, // Scalar
	quoted: bool, // Scalar: written in quotes, so never null
	items:  [dynamic]^Yaml, // Seq
	keys:   [dynamic]string, // Map, in file order
	vals:   [dynamic]^Yaml,
	line:   int, // 1-based
}

yaml_get :: proc(m: ^Yaml, key: string) -> ^Yaml {
	if m == nil || m.kind != .Map do return nil
	for k, i in m.keys do if k == key do return m.vals[i]
	return nil
}

@(private = "file")
Line :: struct {
	indent:  int,
	content: string, // without indentation, comment and trailing spaces
	raw:     string, // whole line, for block scalars
	no:      int,
	blank:   bool,
}

@(private = "file")
Parser :: struct {
	lines:    []Line,
	i, end:   int, // current line, end of the current document
	alloc:    mem.Allocator,
	err:      string,
	err_line: int,
}

// Parses every document in `src`. On error, `err` says what and `err_line` where.
yaml_parse :: proc(src: string, alloc: mem.Allocator) -> (docs: [dynamic]^Yaml, err: string, err_line: int) {
	context.allocator = alloc
	p := Parser {
		alloc = alloc,
	}
	lines: [dynamic]Line
	starts: [dynamic]int // first line index of each document
	append(&starts, 0)
	for raw_line, k in strings.split_lines(src) {
		no := k + 1
		raw := strings.trim_right(raw_line, "\r")
		indent := 0
		for indent < len(raw) && raw[indent] == ' ' do indent += 1
		if indent < len(raw) && raw[indent] == '\t' {
			return docs, "tabs are not allowed for indentation", no
		}
		content := strings.trim_right(strip_comment(raw[indent:]), " \t")
		if indent == 0 && (content == "---" || content == "...") {
			if content == "---" && len(lines) > 0 do append(&starts, len(lines))
			continue
		}
		if indent == 0 && strings.has_prefix(content, "--- ") {
			return docs, "content after `---` on the same line is not supported", no
		}
		append(&lines, Line{indent = indent, content = content, raw = raw, no = no, blank = content == ""})
	}
	p.lines = lines[:]
	for s, k in starts {
		p.i = s
		p.end = len(lines) if k + 1 == len(starts) else starts[k + 1]
		skip_blank(&p)
		if p.i >= p.end do continue
		doc := parse_block(&p, -1)
		if p.err == "" {
			skip_blank(&p)
			if p.i < p.end do fail(&p, p.lines[p.i].no, "unexpected content (bad indentation?)")
		}
		if p.err != "" do return docs, p.err, p.err_line
		append(&docs, doc)
	}
	return docs, "", 0
}

@(private = "file")
fail :: proc(p: ^Parser, line: int, msg: string, args: ..any) {
	if p.err != "" do return
	p.err = fmt.aprintf(msg, ..args, allocator = p.alloc)
	p.err_line = line
}

@(private = "file")
skip_blank :: proc(p: ^Parser) {
	for p.i < p.end && p.lines[p.i].blank do p.i += 1
}

// Cuts a `#` comment that is outside quotes and preceded by a space (or at the start).
@(private = "file")
strip_comment :: proc(s: string) -> string {
	quote: u8 = 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case quote == '"' && c == '\\':
			i += 1
		case quote != 0 && c == quote:
			if quote == '\'' && i + 1 < len(s) && s[i + 1] == '\'' {
				i += 1 // '' inside single quotes
			} else {
				quote = 0
			}
		case quote == 0 && (c == '"' || c == '\'') && starts_value(s, i):
			quote = c
		case quote == 0 && c == '#' && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '\t'):
			return s[:i]
		}
	}
	return s
}

// A quote opens a quoted scalar only where a value can start, so `It's` stays plain.
@(private = "file")
starts_value :: proc(s: string, i: int) -> bool {
	j := i - 1
	for j >= 0 && (s[j] == ' ' || s[j] == '\t') do j -= 1
	return j < 0 || strings.index_byte(":-[{,?", s[j]) >= 0
}

@(private = "file")
new_node :: proc(p: ^Parser, kind: Yaml_Kind, line: int) -> ^Yaml {
	n := new(Yaml, p.alloc)
	n.kind = kind
	n.line = line
	return n
}

@(private = "file")
is_seq_entry :: proc(s: string) -> bool {
	return s == "-" || strings.has_prefix(s, "- ")
}

// Index of the `:` that ends a mapping key on this line, or -1.
@(private = "file")
map_colon :: proc(s: string) -> int {
	if len(s) == 0 || s[0] == '[' || s[0] == '{' do return -1
	i := 0
	if s[0] == '"' || s[0] == '\'' {
		q := s[0]
		i = 1
		for i < len(s) {
			if q == '"' && s[i] == '\\' {
				i += 2
				continue
			}
			if s[i] == q {
				if q == '\'' && i + 1 < len(s) && s[i + 1] == '\'' {
					i += 2
					continue
				}
				break
			}
			i += 1
		}
		i += 1
		for i < len(s) && s[i] == ' ' do i += 1
		return i if i < len(s) && s[i] == ':' && (i + 1 == len(s) || s[i + 1] == ' ') else -1
	}
	for ; i < len(s); i += 1 {
		if s[i] == ':' && (i + 1 == len(s) || s[i + 1] == ' ' || s[i + 1] == '\t') do return i
	}
	return -1
}

// The block node starting at the current line; its indentation must exceed `parent`.
@(private = "file")
parse_block :: proc(p: ^Parser, parent: int) -> ^Yaml {
	skip_blank(p)
	if p.i >= p.end do return new_node(p, .Null, p.lines[p.end - 1].no if p.end > 0 else 0)
	l := p.lines[p.i]
	if l.indent <= parent {
		return new_node(p, .Null, l.no)
	}
	if is_seq_entry(l.content) do return parse_seq(p, l.indent)
	if map_colon(l.content) >= 0 do return parse_map(p, l.indent)
	return parse_value(p, l.content, l.indent - 1, l.no)
}

@(private = "file")
parse_seq :: proc(p: ^Parser, indent: int) -> ^Yaml {
	seq := new_node(p, .Seq, p.lines[p.i].no)
	for p.err == "" {
		skip_blank(p)
		if p.i >= p.end do break
		l := &p.lines[p.i]
		if l.indent != indent || !is_seq_entry(l.content) do break
		rest := strings.trim_left(l.content[1:], " ")
		if rest == "" {
			p.i += 1
			append(&seq.items, parse_block(p, indent))
			continue
		}
		// "- key: v" or "- - x": the rest of the line becomes a node at its own column,
		// so the item's following lines (indented to that column) continue it.
		l.indent += len(l.content) - len(rest)
		l.content = rest
		append(&seq.items, parse_block(p, indent))
	}
	return seq
}

@(private = "file")
parse_map :: proc(p: ^Parser, indent: int) -> ^Yaml {
	m := new_node(p, .Map, p.lines[p.i].no)
	for p.err == "" {
		skip_blank(p)
		if p.i >= p.end do break
		l := p.lines[p.i]
		if l.indent < indent do break
		if l.indent > indent {
			fail(p, l.no, "bad indentation")
			break
		}
		if is_seq_entry(l.content) do break // a sequence at the parent key's level ends this map
		colon := map_colon(l.content)
		if colon < 0 {
			fail(p, l.no, "expected `key: value`, found `%s`", l.content)
			break
		}
		key_node := parse_scalar(p, strings.trim_right(l.content[:colon], " "), l.no)
		if key_node == nil do break
		key := key_node.text
		for k in m.keys do if k == key {
			fail(p, l.no, "duplicate key `%s`", key)
			return m
		}
		rest := strings.trim_left(l.content[colon + 1:], " \t")
		val: ^Yaml
		if rest == "" {
			p.i += 1
			skip_blank(p)
			if p.i < p.end && p.lines[p.i].indent == indent && is_seq_entry(p.lines[p.i].content) {
				val = parse_seq(p, indent) // "key:\n- a": a sequence may sit at the key's level
			} else {
				val = parse_block(p, indent)
			}
		} else {
			val = parse_value(p, rest, indent, l.no)
		}
		append(&m.keys, key)
		append(&m.vals, val)
	}
	return m
}

// An inline value starting on the current line (`rest`), which may continue on following
// lines indented deeper than `indent`. Advances past every line it uses.
@(private = "file")
parse_value :: proc(p: ^Parser, rest: string, indent: int, no: int) -> ^Yaml {
	switch rest[0] {
	case '&', '*', '!':
		fail(p, no, "YAML anchors, aliases and tags are not supported")
		return nil
	case '|', '>':
		return parse_block_scalar(p, rest, indent, no)
	case '[', '{':
		text := rest
		p.i += 1
		for !balanced(text) && p.i < p.end {
			text = strings.concatenate({text, " ", p.lines[p.i].content}, p.alloc)
			p.i += 1
		}
		pos := 0
		v := parse_flow(p, text, &pos, no)
		for pos < len(text) && text[pos] == ' ' do pos += 1
		if v != nil && pos < len(text) do fail(p, no, "unexpected `%s` after a flow collection", text[pos:])
		return v
	}
	// Scalar, possibly folded over more-indented lines (plain) or until its closing quote.
	text := rest
	p.i += 1
	for p.i < p.end && p.lines[p.i].indent > indent && !p.lines[p.i].blank {
		q := text[0]
		if (q == '"' || q == '\'') && quote_closed(text) do break
		if q != '"' && q != '\'' && map_colon(p.lines[p.i].content) >= 0 do break
		text = strings.concatenate({text, " ", p.lines[p.i].content}, p.alloc)
		p.i += 1
	}
	return parse_scalar(p, text, no)
}

@(private = "file")
quote_closed :: proc(s: string) -> bool {
	q := s[0]
	for i := 1; i < len(s); i += 1 {
		if q == '"' && s[i] == '\\' {
			i += 1
			continue
		}
		if s[i] == q {
			if q == '\'' && i + 1 < len(s) && s[i + 1] == '\'' {
				i += 1
				continue
			}
			return true
		}
	}
	return false
}

@(private = "file")
balanced :: proc(s: string) -> bool {
	depth := 0
	quote: u8 = 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case quote == '"' && c == '\\':
			i += 1
		case quote != 0:
			if c == quote do quote = 0
		case c == '"' || c == '\'':
			quote = c
		case c == '[' || c == '{':
			depth += 1
		case c == ']' || c == '}':
			depth -= 1
		}
	}
	return depth <= 0
}

// `|` keeps line breaks, `>` folds them into spaces; `-` strips the final newline, `+` keeps
// all trailing ones.
@(private = "file")
parse_block_scalar :: proc(p: ^Parser, header: string, indent: int, no: int) -> ^Yaml {
	literal := header[0] == '|'
	chomp: u8 = 0
	for c in header[1:] {
		switch c {
		case '-', '+':
			chomp = u8(c)
		case:
			fail(p, no, "unsupported block scalar header `%s`", header)
			return nil
		}
	}
	p.i += 1
	body: [dynamic]string
	block_indent := -1
	for p.i < p.end {
		// Raw lines: inside a block scalar `#` is text, not a comment.
		l := p.lines[p.i]
		blank := strings.trim_space(l.raw) == ""
		if !blank && l.indent <= indent do break
		if !blank && block_indent < 0 do block_indent = l.indent
		append(&body, "" if blank else l.raw[min(block_indent, len(l.raw)):])
		p.i += 1
	}
	b := strings.builder_make(p.alloc)
	for line, k in body {
		if k > 0 {
			strings.write_byte(&b, '\n' if literal || line == "" || body[k - 1] == "" else ' ')
		}
		strings.write_string(&b, line)
	}
	text := strings.to_string(b)
	switch chomp {
	case '-':
		text = strings.trim_right(text, "\n")
	case '+':
		text = strings.concatenate({text, "\n"}, p.alloc)
	case:
		text = strings.concatenate({strings.trim_right(text, "\n"), "\n"}, p.alloc)
	}
	n := new_node(p, .Scalar, no)
	n.text = text
	n.quoted = true
	return n
}

// `[a, b]` and `{k: v}`, nested, with plain or quoted scalars.
@(private = "file")
parse_flow :: proc(p: ^Parser, s: string, pos: ^int, no: int) -> ^Yaml {
	skip :: proc(s: string, pos: ^int) {
		for pos^ < len(s) && (s[pos^] == ' ' || s[pos^] == '\t') do pos^ += 1
	}
	skip(s, pos)
	if pos^ >= len(s) {
		fail(p, no, "unterminated flow collection")
		return nil
	}
	switch s[pos^] {
	case '[', '{':
		is_map := s[pos^] == '{'
		close: u8 = '}' if is_map else ']'
		n := new_node(p, .Map if is_map else .Seq, no)
		pos^ += 1
		for {
			skip(s, pos)
			if pos^ >= len(s) {
				fail(p, no, "unterminated flow collection")
				return nil
			}
			if s[pos^] == close {
				pos^ += 1
				return n
			}
			if is_map {
				k := flow_scalar(p, s, pos, no, true)
				if k == nil do return nil
				skip(s, pos)
				if pos^ >= len(s) || s[pos^] != ':' {
					fail(p, no, "expected `:` in flow mapping")
					return nil
				}
				pos^ += 1
				v := parse_flow(p, s, pos, no)
				if v == nil do return nil
				append(&n.keys, k.text)
				append(&n.vals, v)
			} else {
				v := parse_flow(p, s, pos, no)
				if v == nil do return nil
				append(&n.items, v)
			}
			skip(s, pos)
			if pos^ < len(s) && s[pos^] == ',' do pos^ += 1
		}
	case '&', '*', '!':
		fail(p, no, "YAML anchors, aliases and tags are not supported")
		return nil
	}
	return flow_scalar(p, s, pos, no, false)
}

@(private = "file")
flow_scalar :: proc(p: ^Parser, s: string, pos: ^int, no: int, is_key: bool) -> ^Yaml {
	start := pos^
	if s[start] == '"' || s[start] == '\'' {
		q := s[start]
		i := start + 1
		for i < len(s) {
			if q == '"' && s[i] == '\\' {
				i += 2
				continue
			}
			if s[i] == q {
				if q == '\'' && i + 1 < len(s) && s[i + 1] == '\'' {
					i += 2
					continue
				}
				break
			}
			i += 1
		}
		pos^ = min(i + 1, len(s))
		return parse_scalar(p, s[start:pos^], no)
	}
	i := start
	for i < len(s) {
		c := s[i]
		if c == ',' || c == ']' || c == '}' do break
		if c == ':' && (is_key || i + 1 == len(s) || s[i + 1] == ' ') do break
		i += 1
	}
	pos^ = i
	return parse_scalar(p, strings.trim_space(s[start:i]), no)
}

// A plain, 'single' or "double" quoted scalar; unquoted ~, null and empty are Null.
@(private = "file")
parse_scalar :: proc(p: ^Parser, s: string, no: int) -> ^Yaml {
	n := new_node(p, .Scalar, no)
	if len(s) > 0 && (s[0] == '"' || s[0] == '\'') {
		q := s[0]
		if len(s) < 2 || s[len(s) - 1] != q || !quote_closed(s) {
			fail(p, no, "unterminated quoted string")
			return nil
		}
		inner := s[1:len(s) - 1]
		n.quoted = true
		if q == '\'' {
			n.text, _ = strings.replace_all(inner, "''", "'", p.alloc)
			return n
		}
		b := strings.builder_make(p.alloc)
		for i := 0; i < len(inner); i += 1 {
			c := inner[i]
			if c != '\\' {
				strings.write_byte(&b, c)
				continue
			}
			i += 1
			if i >= len(inner) {
				fail(p, no, "bad escape at the end of a string")
				return nil
			}
			switch inner[i] {
			case 'n':  strings.write_byte(&b, '\n')
			case 't':  strings.write_byte(&b, '\t')
			case 'r':  strings.write_byte(&b, '\r')
			case '0':  strings.write_byte(&b, 0)
			case 'b':  strings.write_byte(&b, '\b')
			case 'f':  strings.write_byte(&b, '\f')
			case 'e':  strings.write_byte(&b, 0x1b)
			case ' ':  strings.write_byte(&b, ' ')
			case '"':  strings.write_byte(&b, '"')
			case '/':  strings.write_byte(&b, '/')
			case '\\': strings.write_byte(&b, '\\')
			case 'x', 'u', 'U':
				width := 2 if inner[i] == 'x' else 4 if inner[i] == 'u' else 8
				if i + width >= len(inner) {
					fail(p, no, "bad \\%c escape", inner[i])
					return nil
				}
				code, ok := strconv.parse_u64_of_base(inner[i + 1:i + 1 + width], 16)
				if !ok {
					fail(p, no, "bad \\%c escape", inner[i])
					return nil
				}
				buf, w := utf8.encode_rune(rune(code))
				strings.write_bytes(&b, buf[:w])
				i += width
			case:
				fail(p, no, "unsupported escape \\%c", inner[i])
				return nil
			}
		}
		n.text = strings.to_string(b)
		return n
	}
	switch s {
	case "", "~", "null", "Null", "NULL":
		n.kind = .Null
	case:
		n.text = s
	}
	return n
}
