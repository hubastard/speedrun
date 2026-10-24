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
// - `faker`, Java's Datafaker in Maestro: its common providers (see below).
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

	// Datafaker (Maestro's `faker` and inputRandom*): the providers flows use, with
	// Datafaker's English word lists (datafaker/data.json) and formats. Other providers
	// and methods are an error naming the call.
	let fakerText = ''
	let fakerData = null
	const data = () => fakerData || (fakerData = JSON.parse(fakerText))
	const int = n => Math.floor(Math.random() * n)
	const pick = list => list[int(list.length)]
	const digit = () => String(int(10))
	// '#': a digit, 'Ø': a digit but 0.
	const numerify = f => f.replace(/#/g, digit).replace(/Ø/g, () => String(1 + int(9)))
	const lower = s => s.toLowerCase().replace(/[^a-z0-9]/g, '')
	const cap = s => s.charAt(0).toUpperCase() + s.slice(1)
	const digits = n => { let s = String(1 + int(9)); while (s.length < n) s += digit(); return s }
	const letters = (n, set) => { let s = ''; for (let i = 0; i < n; i++) s += set.charAt(int(set.length)); return s }
	const LOWER = 'abcdefghijklmnopqrstuvwxyz'
	const firstName = () => pick(int(2) ? data().male_first_name : data().female_first_name)
	const lastName = () => pick(data().last_name)
	const fullName = () => {
		const n = int(6)
		if (n === 0) return pick(data().prefix) + ' ' + firstName() + ' ' + lastName()
		if (n === 1) return firstName() + ' ' + lastName() + ' ' + pick(data().suffix)
		return firstName() + ' ' + lastName()
	}
	const username = () => lower(firstName()) + '.' + lower(lastName())
	const cityName = () => {
		switch (int(4)) {
		case 0: return pick(data().city_prefix) + ' ' + firstName() + pick(data().city_suffix)
		case 1: return pick(data().city_prefix) + ' ' + firstName()
		case 2: return firstName() + pick(data().city_suffix)
		default: return lastName() + pick(data().city_suffix)
		}
	}
	const streetName = () => (int(2) ? firstName() : lastName()) + ' ' + pick(data().street_suffix)
	const streetAddress = () => numerify(pick(data().building_number)) + ' ' + streetName()
	const zipCode = () => numerify('#####')
	const domainWord = () => lower(lastName())
	const domainName = () => domainWord() + '.' + pick(data().domain_suffix)
	const word = () => pick(data().lorem)
	const words = n => Array.from({ length: n }, word)
	const sentence = (n, extra) => {
		const count = (n === undefined ? 3 : n) + int((extra === undefined ? 6 : extra) + 1)
		return cap(words(Math.max(count, 1)).join(' ')) + '.'
	}
	const paragraph = n => Array.from({ length: (n === undefined ? 3 : n) + int(4) }, () => sentence()).join(' ')
	const phone = () => '(' + String(2 + int(8)) + digit() + digit() + ') ' + String(2 + int(8)) + digit() + digit() + '-' + numerify('####')
	const between = (min, max) => (min === max ? min : min + int(max - min))
	const decimal = (min, max) => min + Math.random() * (max - min)
	const hex = n => letters(n, '0123456789abcdef')
	const uuid = () => hex(8) + '-' + hex(4) + '-4' + hex(3) + '-' + '89ab'.charAt(int(4)) + hex(3) + '-' + hex(12)
	const providers = {
		name: {
			firstName, lastName, fullName, name: fullName, username,
			nameWithMiddle: () => firstName() + ' ' + lastName() + ' ' + lastName(),
			prefix: () => pick(data().prefix), suffix: () => pick(data().suffix),
		},
		internet: {
			emailAddress: local => (local === undefined ? username() : String(local)) + '@' + pick(data().free_email),
			safeEmailAddress: local => (local === undefined ? username() : String(local)) + '@example.com',
			username, domainName, domainWord, domainSuffix: () => pick(data().domain_suffix),
			url: () => 'https://www.' + domainWord() + '-' + domainWord() + '.' + pick(data().domain_suffix) + '/',
			password: (min, max) => letters(between(min === undefined ? 8 : min, (max === undefined ? 16 : max) + 1), LOWER + '0123456789'),
			uuid,
			ipV4Address: () => [1 + int(254), int(256), int(256), 1 + int(254)].join('.'),
		},
		address: {
			city: cityName, cityName, country: () => pick(data().country), countryCode: () => pick(data().country_code),
			cityPrefix: () => pick(data().city_prefix), citySuffix: () => pick(data().city_suffix),
			streetName, streetAddress, streetSuffix: () => pick(data().street_suffix),
			buildingNumber: () => numerify(pick(data().building_number)),
			secondaryAddress: () => numerify(pick(data().secondary_address)),
			zipCode, postcode: zipCode, state: () => pick(data().state), stateAbbr: () => pick(data().state_abbr),
			fullAddress: () => streetAddress() + ', ' + cityName() + ', ' + pick(data().state_abbr) + ' ' + zipCode(),
			latitude: () => decimal(-90, 90).toFixed(8), longitude: () => decimal(-180, 180).toFixed(8),
		},
		number: {
			// Datafaker's randomNumber(n) has n digits; without n, up to 10.
			randomNumber: n => Number(n === undefined ? String(int(1e10)) : digits(Math.max(1, Math.min(18, n)))),
			randomDigit: () => int(10), randomDigitNotZero: () => 1 + int(9),
			numberBetween: (min, max) => between(Math.ceil(min), Math.floor(max)),
			digits: n => numerify('#'.repeat(n === undefined ? 1 : n)),
			randomDouble: (decimals, min, max) => Number(decimal(min, max).toFixed(decimals)),
			positive: () => 1 + int(2147483646), negative: () => -(1 + int(2147483647)),
		},
		lorem: {
			word, words: n => words(n === undefined ? 3 : n), sentence, paragraph,
			sentences: n => Array.from({ length: n === undefined ? 3 : n }, () => sentence()),
			paragraphs: n => Array.from({ length: n === undefined ? 3 : n }, () => paragraph()),
			characters: n => letters(n === undefined ? 255 : n, LOWER + '0123456789'),
		},
		text: {
			text: (min, max) => letters(max === undefined || typeof max !== 'number' ? (min === undefined ? 20 : min) : between(min, max + 1), LOWER),
		},
		phoneNumber: { cellPhone: phone, phoneNumber: phone, subscriberNumber: n => numerify('#'.repeat(n === undefined ? 4 : n)) },
		color: { name: () => pick(data().color), hex: () => '#' + hex(6).toUpperCase() },
		company: {
			name: () => {
				switch (int(3)) {
				case 0: return lastName() + ' ' + pick(data().company_suffix)
				case 1: return lastName() + '-' + lastName()
				default: return lastName() + ', ' + lastName() + ' and ' + lastName()
				}
			},
			suffix: () => pick(data().company_suffix), industry: () => pick(data().industry), profession: () => pick(data().profession),
		},
		bool: { bool: () => int(2) === 1 },
	}
	const unsupported = what => { throw new Error(what + ' is not supported by speedrun yet') }
	g.faker = new Proxy({}, {
		get(_, k) {
			if (typeof k === 'symbol') return undefined
			const methods = providers[k]
			if (!methods) unsupported('faker.' + k + '()')
			const provider = new Proxy(methods, {
				get(t, m) {
					if (typeof m === 'symbol' || Object.prototype.hasOwnProperty.call(t, m)) return t[m]
					unsupported('faker.' + k + '().' + m + '()')
				},
			})
			return () => provider
		},
	})
	// inputRandom*: InputRandomCommand.genRandomString.
	function random(spec) {
		const [kind, n] = spec.split(':')
		const length = Number(n)
		switch (kind) {
		case 'NUMBER': return String(providers.number.randomNumber(length))
		case 'TEXT_EMAIL_ADDRESS': return providers.internet.emailAddress()
		case 'TEXT_PERSON_NAME': return firstName() + ' ' + lastName()
		case 'TEXT_CITY_NAME': return cityName()
		case 'TEXT_COUNTRY_NAME': return providers.address.country()
		case 'TEXT_COLOR': return providers.color.name()
		default: return providers.text.text(length)
		}
	}

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
		setFakerData(text) {
			fakerText = text
		},
		random,
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
