// speedrun's web agent, the part that runs in the page (web.odin injects it into every
// document before the page's own scripts). It reads the page as flows see it, with Maestro's
// rules (maestro-web.js: text, resource-id, invalid tags, same-origin iframes, <option>s in a
// focused <select>), and tells when the page has settled from what the page itself reports:
// DOM mutations, input, scrolls, focus, CSS animations still running, requests in flight.
// Nothing is polled at an interval: a settle wakes on a change or on a frame.
(() => {
// Once per document. A window's first about:blank document hands its window over to the page
// that replaces it (window.open's), and Chrome runs no script for that new document: web.odin
// calls the agent through WEB_AGENT, which sets it up again (__speedrunInstall) when it belongs
// to another document.
const install = () => {
	if (window.__speedrun && window.__speedrun.document === document) return
	const now = () => performance.now()
	const INVALID_TAGS = new Set(['noscript', 'script', 'br', 'img', 'svg', 'g', 'path', 'style'])
	const SYNTHETIC = 100000 // <option>s are placed from here, out of the page's coordinates (as Maestro)
	const FIELD = '\x1f', NODE = '\x1e'
	// Requests count as activity for their first REQUEST_BUSY_MS only: a long poll, a stream or
	// a beacon that never ends would keep a page from ever settling.
	const REQUEST_BUSY_MS = 2000
	// A timer up to TIMER_BUSY_MS away is activity until it runs (a debounce, a delayed render),
	// one set after the action a settle measures from. Longer ones are the page's own pace.
	const TIMER_BUSY_MS = 1000
	// A tap or a key that changed nothing, with nothing under way, has its answer after
	// NO_CHANGE_FRAMES frames: the page reacts within the event, or through a timer or a
	// request, which count. (The device agents wait up to `noChange` ms: an app's JavaScript
	// thread can run a press late.)
	const NO_CHANGE_FRAMES = 3
	// What moves or resizes elements, the animations a tap must not land in the middle of. A
	// fade or a color change leaves every element where it is.
	const GEOMETRY = /^(transform|translate|scale|rotate|top|left|right|bottom|inset|width|height|min-|max-|margin|padding|flex|grid|font-size|line-height|border-width|offset)/
	const TRANSFORM = /^(transform|translate|scale|rotate)/
	// A timer due within this of an animation's end is that animation's cleanup.
	const CLEANUP_SLACK_MS = 34

	const state = {
		changed: now(), // the last change the page made
		settled: -1, // when the last settle ended
		mark: now(), // the action a settle measures from (MARK)
		requests: new Map(), // id -> start
		nextRequest: 0,
		timers: new Map(), // short timers not run yet: id -> [set, due]
		seq: 0, // changes so far
		frame: 0, // frames so far
		changedFrame: 0, // the frame count at the last change
		readSeq: 0, // seq at the last read
		last: [], // the elements of the last read, in its order
		index: new Map(), // element -> its index in `last`
	}
	const changed = () => {
		state.changed = now()
		state.seq++
		state.changedFrame = state.frame
		if (waiters.length) for (const w of waiters.splice(0)) w()
	}
	const waiters = [] // waitChange's
	const countFrames = () => { state.frame++; requestAnimationFrame(countFrames) }
	requestAnimationFrame(countFrames)

	// Short timers (setTimeout up to TIMER_BUSY_MS) as activity until they run or are cleared:
	// those an event handler or a promise sets, not those a timer sets (a polling loop, a
	// JavaScript animation would never let the page settle) or a layout observer (below).
	const setTimeout_ = window.setTimeout, clearTimeout_ = window.clearTimeout
	let inTimer = false
	window.setTimeout = function (fn, delay, ...rest) {
		if (typeof fn !== 'function') return setTimeout_.call(this, fn, delay, ...rest)
		const d = Number(delay) || 0
		const tracked = !inTimer && d <= TIMER_BUSY_MS
		const id = setTimeout_.call(this, function () {
			state.timers.delete(id)
			const outer = inTimer
			inTimer = true
			try { return fn.apply(this, arguments) } finally { inTimer = outer }
		}, delay, ...rest)
		if (tracked) state.timers.set(id, [now(), now() + d])
		return id
	}
	window.clearTimeout = function (id) {
		state.timers.delete(id)
		return clearTimeout_.call(this, id)
	}
	// Nor those a layout observer sets: a resize handler's debounce (Material UI's tabs move
	// their indicator 166 ms after a layout) is the page's reaction to its own layout.
	if (window.ResizeObserver) {
		const ResizeObserver_ = window.ResizeObserver
		window.ResizeObserver = class ResizeObserver extends ResizeObserver_ {
			constructor(callback) {
				super(function () {
					const outer = inTimer
					inTimer = true
					try { return callback.apply(this, arguments) } finally { inTimer = outer }
				})
			}
		}
	}

	// ---- what the page does ----
	// A node that has kept changing for RESTLESS_MS, never still for PAUSE_MS (a ticking
	// counter, a JavaScript animation, an auto-playing carousel), is restless: its changes stop
	// counting, or a page with one would never settle. One that changes now and then (a clock
	// each second) counts each time.
	const RESTLESS_MS = 500, PAUSE_MS = 250
	const changing = new WeakMap() // node -> [since, last]
	// Whether a change to node n at t counts (n is not restless).
	const counts = (n, t) => {
		let s = changing.get(n)
		if (!s || t - s[1] > PAUSE_MS) s = [t, t]
		else s[1] = t
		changing.set(n, s)
		return t - s[0] < RESTLESS_MS
	}
	const mutated = (records) => {
		const t = now()
		let any = false
		for (const r of records) if (counts(r.target.nodeType === 1 ? r.target : r.target.parentNode || r.target, t)) any = true
		if (any) changed()
	}
	new MutationObserver(mutated).observe(document, { subtree: true, childList: true, characterData: true, attributes: true })
	// Elements that moved without a change to the page's nodes: an image without a set size
	// that loaded, a font that swapped in, a stylesheet that arrived (Chrome's layout shifts).
	// An image's load is no change of its own: one with a set size moves nothing (an avatar
	// from another server arriving after the screen came up).
	try {
		new PerformanceObserver((list) => {
			const t = now()
			let any = false
			for (const e of list.getEntries()) {
				if (!e.sources || !e.sources.length) any = true
				else for (const s of e.sources) if (!s.node || (!animating(s.node) && counts(s.node, t))) any = true
			}
			if (any) changed()
		}).observe({ type: 'layout-shift' })
	} catch (e) {}
	// Firefox reports no layout shifts: there an image's load counts, as it may move others.
	const shifts = !!(window.PerformanceObserver && PerformanceObserver.supportedEntryTypes &&
		PerformanceObserver.supportedEntryTypes.includes('layout-shift'))
	const loaded = (e) => {
		const tag = e.target && e.target.tagName ? e.target.tagName.toLowerCase() : ''
		if (tag === 'iframe' || tag === 'frame' || !tag || (!shifts && tag === 'img')) changed()
	}
	document.addEventListener('load', loaded, { capture: true, passive: true })
	for (const type of ['input', 'change', 'scroll', 'focusin', 'focusout', 'transitionstart', 'transitionend', 'animationstart', 'animationend', 'DOMContentLoaded'])
		document.addEventListener(type, changed, { capture: true, passive: true })
	// --animations fast or off in a browser with no playback rate of its own to set (Firefox):
	// each animation sped up as it starts (web_firefox.odin sets the rate before this runs).
	const rate = window.__speedrunAnimationRate
	if (rate > 1) {
		const sped = new WeakSet()
		const speed = (a) => { if (!sped.has(a)) { sped.add(a); a.playbackRate *= rate } }
		const speedUp = (e) => { if (e.target && e.target.getAnimations) for (const a of e.target.getAnimations()) speed(a) }
		for (const type of ['transitionrun', 'animationstart'])
			document.addEventListener(type, speedUp, { capture: true, passive: true })
		const animate = Element.prototype.animate
		Element.prototype.animate = function (...args) {
			const a = animate.apply(this, args)
			speed(a)
			return a
		}
	}
	window.addEventListener('resize', changed, { passive: true })
	window.addEventListener('popstate', changed, { passive: true })
	window.addEventListener('hashchange', changed, { passive: true })

	const started = () => {
		const id = state.nextRequest++
		state.requests.set(id, now())
		return () => { state.requests.delete(id); changed() }
	}
	if (window.fetch) {
		const fetch = window.fetch
		window.fetch = function (...args) {
			const done = started()
			try {
				const p = fetch.apply(this, args)
				p.then(done, done)
				return p
			} catch (e) { done(); throw e }
		}
	}
	if (window.XMLHttpRequest) {
		const send = XMLHttpRequest.prototype.send
		XMLHttpRequest.prototype.send = function (...args) {
			const done = started()
			this.addEventListener('loadend', done, { once: true })
			try { return send.apply(this, args) } catch (e) { done(); throw e }
		}
	}

	// Work the page still has under way: requests in their first REQUEST_BUSY_MS, short timers,
	// finite CSS animations and transitions still running (an endless one, a spinner, never
	// ends) that move other elements (reflows). One that moves only its own element and what it
	// holds (a transform, a field's label floating up, a drawer sliding in, a button's ripple)
	// is waited for only when a tap aims there (steady). A timer that ends with such an
	// animation is its cleanup (a transition library's, removing the ripple): no work either.
	// What is under way ('' when nothing): 'request', 'animation <property>', 'timer <ms>'.
	const busy = (t) => {
		for (const start of state.requests.values()) if (t - start < REQUEST_BUSY_MS) return 'request'
		let pending = 0
		for (const [set, due] of state.timers.values()) if (set >= state.mark && due + 50 > t) pending++
		if (!pending && !document.getAnimations) return ''
		const ends = [] // when the animations that do not count end
		for (const a of document.getAnimations ? document.getAnimations() : []) {
			if (a.playState !== 'running') continue
			const timing = a.effect && a.effect.getComputedTiming ? a.effect.getComputedTiming() : null
			if (!timing || !Number.isFinite(timing.endTime)) continue
			if (reflows(a)) return 'animation ' + animated(a).join(' ')
			const start = a.startTime === null ? t : a.startTime
			ends.push(start + timing.endTime / (Math.abs(a.playbackRate) || 1))
		}
		for (const [set, due] of state.timers.values()) {
			if (set < state.mark || due + 50 <= t) continue
			if (!ends.some((end) => Math.abs(end - due) <= CLEANUP_SLACK_MS)) return 'timer ' + Math.round(due - set)
		}
		return ''
	}
	// The properties an animation animates.
	const animated = (a) => {
		if (a.transitionProperty) return [a.transitionProperty]
		const out = []
		try {
			for (const k of a.effect.getKeyframes()) for (const p in k) {
				if (p === 'offset' || p === 'easing' || p === 'composite' || p === 'computedOffset') continue
				out.push(p.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()))
			}
		} catch (e) { return ['all'] }
		return out
	}
	// An animation that moves or resizes what it animates.
	const moves = (a) => animated(a).some((p) => GEOMETRY.test(p) || p === 'all')
	// An animation that moves other elements a tap could aim at: one of the layout's properties
	// (not a transform, which leaves the layout as it is) on an element in the flow (not
	// absolutely positioned), whose reflow reaches something clickable. A reflow stops at the
	// nearest absolutely positioned container; one that pointer-events: none leaves out holds
	// only decoration (a text field's outline, its notch opening for the label).
	const reflows = (a) => {
		if (!animated(a).some((p) => (GEOMETRY.test(p) && !TRANSFORM.test(p)) || p === 'all')) return false
		const el = a.effect && a.effect.target
		if (!el || !el.isConnected) return !el
		if (positioned(el)) return false
		for (let p = el.parentElement; p; p = p.parentElement) {
			if (positioned(p)) return getComputedStyle(p).pointerEvents !== 'none'
		}
		return true
	}
	const positioned = (el) => {
		const position = getComputedStyle(el).position
		return position === 'absolute' || position === 'fixed'
	}
	// Node n moves by an animation of its own (left alone by layout shifts: busy and steady
	// judge the animation).
	const animating = (n) => {
		const el = n.nodeType === 1 ? n : n.parentElement
		if (!el || !el.getAnimations) return false
		for (const a of el.getAnimations()) if (a.playState === 'running' && moves(a)) return true
		return false
	}

	// STEADY: resolves true once element i of the last read and its containers have stopped
	// moving (the animations that do not count as the page's work: they move only what they
	// animate), at once false when none moves; after `timeout` ms at most. A tap mid-slide
	// lands where the element was.
	const steady = (i, timeout) => new Promise((resolve) => {
		const moving = []
		for (let el = state.last[i]; el && el.getAnimations; el = el.parentElement) {
			for (const a of el.getAnimations()) {
				if (a.playState !== 'running' || !moves(a)) continue
				const timing = a.effect && a.effect.getComputedTiming ? a.effect.getComputedTiming() : null
				if (timing && Number.isFinite(timing.endTime)) moving.push(a.finished.catch(() => {}))
			}
		}
		if (!moving.length) return resolve(false)
		// Then a frame, for the layout to show where it rests (or a timer's: a page the browser
		// does not draw has no frames).
		let done = false
		const finish = () => {
			if (done) return
			done = true
			requestAnimationFrame(() => resolve(true))
			setTimeout_(() => resolve(true), 50)
		}
		Promise.all(moving).then(finish)
		setTimeout_(finish, timeout)
	})

	// ---- reading the page (maestro-web.js's traverse) ----
	const nodeText = (node, tag) => {
		switch (tag) {
			case 'input':
			case 'textarea':
				return node.value || node.placeholder || node.ariaLabel || ''
			case 'select':
				return Array.from(node.selectedOptions).map((o) => o.text).join(', ')
		}
		// The element's own text nodes, as Maestro; their white space as the page shows it,
		// collapsed and trimmed (Maestro keeps the source's: a button written over three lines
		// reads "\n  Save\n", which `tapOn: Save` does not match).
		let s = ''
		for (const c of node.childNodes) if (c.nodeType === 3) s += c.textContent
		return s.replace(/\s+/g, ' ').trim()
	}
	const identifier = (node, prop, attr) => {
		const v = node[prop]
		if (typeof v === 'string') return v || null
		const a = node.getAttribute && node.getAttribute(attr)
		return typeof a === 'string' && a !== '' ? a : null
	}
	const resourceId = (node) => {
		const flt = node.attributes['flt-semantics-identifier']
		if (!(flt || node.id || node.ariaLabel || node.name || node.title || node.htmlFor || node.attributes['data-testid'])) return ''
		return (flt && flt.value) || identifier(node, 'id', 'id') || identifier(node, 'ariaLabel', 'aria-label') ||
			identifier(node, 'name', 'name') || identifier(node, 'title', 'title') || identifier(node, 'htmlFor', 'for') ||
			(node.attributes['data-testid'] && node.attributes['data-testid'].value) || ''
	}
	const clean = (s) => (s.indexOf(FIELD) >= 0 || s.indexOf(NODE) >= 0 ? s.replace(/[\x1e\x1f]/g, ' ') : s)
	// Flags, as host/main.odin's Flag bits: Clickable 1, Enabled 2, Focused 4, Scrollable 8,
	// Checked 16, Visible 32, Selected 64. Maestro's web hierarchy has no clickable attribute:
	// none is set, so a selector picks among matches in the page's order, as Maestro does.
	const flags = (node, tag, w, h) => {
		let f = 32
		if (!node.disabled) f |= 2
		if (node === document.activeElement && tag !== 'body') f |= 4
		if (node.checked === true || node.getAttribute('aria-checked') === 'true') f |= 16
		if (node.selected === true) f |= 64
		// Scrollable: content past its box that it clips (scrolled, or hidden: a carousel), so
		// that bounds are cut to it (the runner's clip_to_scroll_views). Not the page itself.
		if (tag !== 'html' && tag !== 'body' && (node.scrollHeight > node.clientHeight + 1 || node.scrollWidth > node.clientWidth + 1) && w > 0 && h > 0) {
			const cs = getComputedStyle(node)
			const clips = (v) => v !== 'visible'
			if (clips(cs.overflowY) || clips(cs.overflowX)) f |= 8
		}
		return f
	}

	const tree = () => {
		const out = []
		const last = []
		const add = (node, depth, l, t, r, b, f, text, id, cls) => {
			last.push(node)
			out.push(depth + FIELD + l + FIELD + t + FIELD + r + FIELD + b + FIELD + f + FIELD + clean(text) + FIELD + FIELD + clean(id) + FIELD + cls + FIELD + FIELD)
		}
		const vw = window.innerWidth, vh = window.innerHeight
		add(document.documentElement, 0, 0, 0, vw, vh, 32 | 2, '', '', 'Viewport')
		const walk = (node, depth, ox, oy) => {
			const tag = node.tagName.toLowerCase()
			if (INVALID_TAGS.has(tag)) return
			if (tag === 'iframe') {
				let doc = null
				try { doc = node.contentDocument } catch (e) {}
				const rect = node.getBoundingClientRect()
				if (doc && doc.body) {
					walk(doc.body, depth, ox + rect.x, oy + rect.y)
				} else {
					add(node, depth, Math.round(rect.left + ox), Math.round(rect.top + oy), Math.round(rect.right + ox), Math.round(rect.bottom + oy), 32 | 2, '', '', 'iframe')
				}
				return
			}
			if (tag === 'option') {
				// Only in a <select> that has the focus, out of the page's coordinates.
				if (!node.parentElement || !node.parentElement.matches(':focus-within')) return
				const i = Array.prototype.indexOf.call(node.parentElement.children, node)
				add(node, depth, SYNTHETIC, SYNTHETIC + i * 20, SYNTHETIC + 100, SYNTHETIC + i * 20 + 20, flags(node, tag, 0, 0), nodeText(node, tag), resourceId(node), tag)
				return
			}
			const r = node.getBoundingClientRect()
			add(node, depth, Math.round(r.left + ox), Math.round(r.top + oy), Math.round(r.right + ox), Math.round(r.bottom + oy),
				flags(node, tag, r.width, r.height), nodeText(node, tag), resourceId(node), tag)
			for (const c of node.children) walk(c, depth + 1, ox, oy)
		}
		if (document.body) walk(document.body, 1, 0, 0)
		state.last = last
		state.index = new Map(last.map((n, i) => [n, i]))
		state.readSeq = state.seq
		// The trailing flag (Hierarchy.unsettled): the page changed since the last settle ended,
		// or has work under way.
		const unsettled = (state.settled >= 0 && state.changed > state.settled) || busy(now())
		return out.join(NODE) + NODE + (unsettled ? '1' : '0')
	}

	// The node of the last read that a click at x, y reaches (the element there or the nearest
	// of its ancestors that the read lists), then the frame of what is there.
	const hit = (x, y) => {
		if (x >= SYNTHETIC && y >= SYNTHETIC) {
			for (let i = 0; i < state.last.length; i++) {
				const n = state.last[i]
				if (n.tagName && n.tagName.toLowerCase() === 'option') {
					const k = Array.prototype.indexOf.call(n.parentElement.children, n)
					if (y >= SYNTHETIC + k * 20 && y < SYNTHETIC + k * 20 + 20) return [i, x, y, x, y]
				}
			}
			return [-1, 0, 0, 0, 0]
		}
		let doc = document, el = null, ox = 0, oy = 0
		for (;;) {
			el = doc.elementFromPoint(x - ox, y - oy)
			if (!el || el.tagName.toLowerCase() !== 'iframe') break
			let inner = null
			try { inner = el.contentDocument } catch (e) {}
			if (!inner) break
			const r = el.getBoundingClientRect()
			ox += r.left
			oy += r.top
			doc = inner
		}
		if (!el) return [-1, 0, 0, 0, 0]
		const r = el.getBoundingClientRect()
		const frame = [Math.round(r.left + ox), Math.round(r.top + oy), Math.round(r.right + ox), Math.round(r.bottom + oy)]
		for (let n = el; n; n = n.parentElement || (n.ownerDocument !== document && n.ownerDocument.defaultView.frameElement)) {
			const i = state.index.get(n)
			if (i !== undefined) return [i, ...frame]
		}
		return [-1, ...frame]
	}

	// The indices, in the last read, of the elements a CSS selector matches.
	const css = (selector) => {
		const out = []
		for (const el of document.querySelectorAll(selector)) {
			const i = state.index.get(el)
			if (i !== undefined) out.push(i)
		}
		return out
	}

	// Brings element i of the last read into view, centered, as a scroll would (scrollUntilVisible
	// on an element the page holds already).
	const reveal = (i) => {
		const el = state.last[i]
		if (!el || !el.scrollIntoView) return false
		el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
		return true
	}

	// MARK: the next settle measures from now.
	const mark = () => { state.mark = now(); return state.mark }

	// SETTLE: resolves with "status,uiDoneMs,waitedMs,frames,why" (status 0 settled, 1 no change,
	// 2 timeout), checked after each change and on each frame. Settled: the page changed since
	// the mark, then nothing changed for `quiet` ms with no work under way (why: the last work
	// it waited for, busy's). No change: nothing
	// changed and nothing is under way `noChange` ms after the mark. `changedBefore`: a change
	// the page cannot see happened (a navigation to this document).
	// Quiet: a frame drawn since the last change (and `quiet` ms at most since it).
	const settle = (quiet, noChange, timeout, changedBefore) => new Promise((resolve) => {
		const start = state.mark
		const startFrame = state.frame
		let frames = 0, timer = 0, raf = 0, done = false, why = ''
		const check = () => {
			if (done) return
			const t = now()
			const sawChange = changedBefore || state.changed > start
			const working = busy(t)
			if (working) why = working
			const drawn = state.frame > state.changedFrame || t - state.changed >= quiet
			let status = -1
			if (sawChange && !working && drawn) status = 0
			else if (!sawChange && !working && (t - start >= noChange || state.frame - startFrame >= NO_CHANGE_FRAMES)) status = 1
			else if (t - start >= timeout) status = 2
			if (status < 0) return
			done = true
			cancelAnimationFrame(raf)
			clearTimeout_(timer)
			state.settled = now()
			resolve(status + ',' + Math.max(0, Math.round(state.changed - start)) + ',' + Math.round(t - start) + ',' + frames + ',' + why)
		}
		const frame = () => { frames++; check(); if (!done) raf = requestAnimationFrame(frame) }
		// A timer as well: frames stop in a page the browser does not draw (a hidden window).
		// (The page's own setTimeout counts timers as its work: the original.)
		const tick = () => { check(); if (!done) timer = setTimeout_(tick, 16) }
		raf = requestAnimationFrame(frame)
		timer = setTimeout_(tick, 16)
		check()
	})

	// The focused field's text length (-1: no editable field has the focus).
	const fieldLength = () => {
		let el = document.activeElement
		while (el && el.tagName && el.tagName.toLowerCase() === 'iframe') {
			try { el = el.contentDocument.activeElement } catch (e) { break }
		}
		if (!el) return -1
		if (el.isContentEditable) return (el.textContent || '').length
		const tag = el.tagName.toLowerCase()
		if ((tag === 'input' || tag === 'textarea') && !el.readOnly && !el.disabled) return (el.value || '').length
		return -1
	}

	// Selects all the focused field's text (eraseText of all of it: one Backspace then); false
	// when it cannot.
	const selectField = () => {
		let el = document.activeElement, doc = document
		while (el && el.tagName && el.tagName.toLowerCase() === 'iframe') {
			try { doc = el.contentDocument; el = doc.activeElement } catch (e) { return false }
		}
		if (!el) return false
		try {
			if (el.isContentEditable) {
				const range = doc.createRange()
				range.selectNodeContents(el)
				const sel = doc.getSelection()
				sel.removeAllRanges()
				sel.addRange(range)
				return true
			}
			el.select()
			return true
		} catch (e) { return false }
	}

	// A tap on an <option> (synthetic coordinates): select it, as Maestro's tapOnSyntheticElement.
	const tapOption = (x, y) => {
		const [i] = hit(x, y)
		const option = i >= 0 ? state.last[i] : null
		if (!option) return false
		const select = option.parentElement
		option.selected = true
		select.dispatchEvent(new Event('change', { bubbles: true }))
		select.blur()
		return true
	}

	// Resolves with true once the page changes after the last read (at once if it has), false
	// after `timeout` ms: a lookup waiting for an element reads again only then.
	const waitChange = (timeout) => new Promise((resolve) => {
		if (state.seq !== state.readSeq) return resolve(true)
		let done = false
		const finish = (v) => { if (!done) { done = true; resolve(v) } }
		waiters.push(() => finish(true))
		setTimeout_(() => finish(state.seq !== state.readSeq), timeout)
	})

	Object.defineProperty(window, '__speedrun', {
		value: { document, tree, hit, css, mark, settle, fieldLength, selectField, tapOption, changed, waitChange, reveal, steady },
		enumerable: false,
		configurable: true,
	})
}
Object.defineProperty(window, '__speedrunInstall', { value: install, enumerable: false, configurable: true })
install()
})()
