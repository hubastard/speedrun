// The JavaScript world flows' scripts run in, as Maestro 2.11.0 sets it up for GraalJS
// (maestro-client js/GraalJsEngine.kt, GraalJsHttp.kt), here on QuickJS-ng. engine.c
// evaluates this file once per flow and calls the function it evaluates to with the natives
// (log, http, platform); host/js.odin then drives the object it returns.
//
// What scripts see, as in Maestro:
// - undeclared names are `undefined`, not a ReferenceError (`${NAME || 'default'}`);
// - env variables as global strings, set again before every script; globals a script
//   creates are gone at the next one (only `output` and `maestro` carry state);
// - each script runs in its own function scope, strict, its value being the last
//   expression's (`(function(){ return eval(script) })()` in Maestro);
// - `output`, `maestro.platform`, `maestro.copiedText`, `json()`, `relativePoint()`,
//   `http.get/post/put/delete/request` (synchronous; through curl, see js.odin) and
//   `console.log`, whose lines show under the command.
// Not here: `faker` (Java's Datafaker in Maestro) is an error naming the call.
(function (natives) {
	'use strict'
	const g = globalThis
	// Bindings Maestro never removes between scripts (permanentBindingKeys).
	const PERMANENT = new Set(['http', 'faker', 'output', 'maestro', 'json', 'relativePoint'])

	// GraalJS's Value.toString(), which Maestro substitutes for `${...}`: a string as it is,
	// anything else in its display form (`[1, 2]`, `{a: 1, b: "x"}`).
	function show(v, depth) {
		try {
			switch (typeof v) {
			case 'string':
				return depth > 0 ? JSON.stringify(v) : v
			case 'undefined':
				return 'undefined'
			case 'function':
				return 'function ' + (v.name || '') + '() { [code] }'
			case 'object':
				if (v === null) return 'null'
				if (Array.isArray(v)) {
					if (depth > 2) return 'Array(' + v.length + ')'
					return '[' + v.map(x => show(x, depth + 1)).join(', ') + ']'
				}
				if (v instanceof Date || v instanceof Error || v instanceof RegExp) return String(v)
				if (depth > 2) return '{...}'
				return '{' + Object.keys(v).map(k => k + ': ' + show(v[k], depth + 1)).join(', ') + '}'
			default:
				return String(v)
			}
		} catch (e) {
			return String(v)
		}
	}

	Object.setPrototypeOf(g, new Proxy(Object.prototype, {
		has() {
			return true
		},
	}))

	g.json = function json(text) {
		return JSON.parse(text)
	}
	g.relativePoint = function relativePoint(x, y) {
		return Math.ceil(x * 100) + '%,' + Math.ceil(y * 100) + '%'
	}
	g.output = {}
	const maestro = { platform: natives.platform }
	g.maestro = maestro

	// GraalJsHttp.executeRequest with okhttp's rules: only a string `body` is sent, GET and
	// HEAD take none, POST/PUT/PATCH need one; `multipartForm` values are text parts, or
	// files with `{filePath, mediaType}` (relative to the running script).
	function request(method, url, params) {
		params = params && typeof params === 'object' ? params : {}
		const body = typeof params.body === 'string' ? params.body : undefined
		const form = params.multipartForm && typeof params.multipartForm === 'object' ? params.multipartForm : undefined
		const headers = []
		if (params.headers && typeof params.headers === 'object') {
			for (const k of Object.keys(params.headers)) headers.push([k, String(params.headers[k])])
		}
		const parts = []
		if (form) {
			for (const k of Object.keys(form)) {
				const v = form[k]
				if (v && typeof v === 'object' && v.filePath != null) {
					parts.push({ name: k, file: String(v.filePath), type: v.mediaType == null ? '' : String(v.mediaType) })
				} else {
					parts.push({ name: k, value: v !== null && typeof v === 'object' ? JSON.stringify(v) : String(v) })
				}
			}
		}
		const hasBody = body !== undefined || form !== undefined
		if (!hasBody && ['POST', 'PUT', 'PATCH', 'PROPPATCH', 'REPORT'].includes(method)) {
			throw new Error('method ' + method + ' must have a request body.')
		}
		if (hasBody && (method === 'GET' || method === 'HEAD')) {
			throw new Error('method ' + method + ' must not have a request body.')
		}
		const reply = JSON.parse(natives.http(JSON.stringify({
			method, url: String(url), headers, has_body: body !== undefined, body: body || '', form: form !== undefined, parts,
		})))
		if (reply.error) throw new Error(reply.error)
		return { ok: reply.status >= 200 && reply.status < 300, status: reply.status, body: reply.body, headers: reply.headers }
	}
	g.http = {
		get: (url, params) => request('GET', url, params),
		post: (url, params) => request('POST', url, params),
		put: (url, params) => request('PUT', url, params),
		delete: (url, params) => request('DELETE', url, params),
		request: (url, params) => request(params && typeof params.method === 'string' ? params.method : 'GET', url, params),
	}

	g.faker = new Proxy({}, {
		get(_, k) {
			if (typeof k === 'symbol') return undefined
			throw new Error('faker.' + k + '() is not supported by speedrun yet')
		},
	})

	const print = (...args) => natives.log(args.map(a => typeof a === 'string' ? a : show(a, 0)).join(' '))
	g.console = { log: print, info: print, warn: print, error: print, debug: print, trace: print }

	const baseline = new Set(Object.getOwnPropertyNames(g))
	// A function of the global scope only: the script sees none of this file's names.
	const evaluate = new Function('__speedrun_script', '"use strict"; return eval(__speedrun_script)')
	let env = {}

	return {
		setEnv(text) {
			env = JSON.parse(text)
		},
		setCopiedText(text) {
			maestro.copiedText = text
		},
		run(script) {
			for (const k of Object.getOwnPropertyNames(g)) {
				if (!baseline.has(k)) {
					try {
						delete g[k]
					} catch (e) {}
				}
			}
			for (const k of Object.keys(env)) if (!PERMANENT.has(k)) g[k] = env[k]
			return show(evaluate(script), 0)
		},
	}
})
