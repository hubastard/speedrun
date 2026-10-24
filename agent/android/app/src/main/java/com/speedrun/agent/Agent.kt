package com.speedrun.agent

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.hypot

internal const val TAG = "SpeedrunAgent"

/**
 * Logcat, tag SpeedrunAgent. The shell entry point also echoes to stdout: that is what
 * `adb shell` shows, and speedrun watches it to know when the agent is up.
 */
internal object AgentLog {
    @Volatile var echoToStdout = false

    fun i(msg: String) {
        Log.i(TAG, msg)
        if (echoToStdout) println(msg)
    }

    fun w(msg: String, t: Throwable? = null) {
        Log.w(TAG, msg, t)
        if (echoToStdout) println("W: $msg" + (t?.let { ": $it" } ?: ""))
    }

    fun e(msg: String, t: Throwable? = null) {
        Log.e(TAG, msg, t)
        if (echoToStdout) println("E: $msg" + (t?.let { ": $it" } ?: ""))
    }
}

/**
 * Wire protocol (big-endian):
 *   request  = u8 op, then op-specific fields
 *   response = u32 length, u32 agent_us, body[length - 4]
 *   str = u16 len + utf8; bytes = u32 len + data
 *
 *   1 PING                                   -> (empty)
 *   2 TREE                                   -> u32 count, count * node
 *        the active window, every node (invisible ones too), pre-order
 *        node = u16 depth, i32 l, i32 t, i32 r, i32 b, u8 flags,
 *               str text, str desc, str id, str class, str hint, str error
 *        flags: 1 clickable, 2 enabled, 4 focused, 8 scrollable, 16 checked,
 *               32 visible to user, 64 selected
 *  10 SCREEN                                 -> u32 count, count * node
 *        every window (active one first, then status bar, dialogs, keyboard...), each root
 *        at depth 0, keeping only children the system reports visible to the user (all of
 *        a WebView's): the hierarchy Maestro matches selectors against.
 *   6 FIND   str text                        -> u32 count, count * node
 *        nodes of the active window whose text or content description contains text,
 *        ignoring case, in document order (depth is 0). The app's own search: one round
 *        trip instead of TREE's ~40 after a screen change. Text an app sets only through an
 *        accessibility delegate is not searched; fall back to TREE when FIND finds nothing.
 *   3 TAP    i32 x, i32 y                    -> u32 prep_us, u32 inject_us, u8 inject_path
 *   4 KEY    i32 keycode                     -> u32 prep_us, u32 inject_us, u8 inject_path
 *        prep = active-window lookup + frame-stats clear; inject_path = see InjectPath
 *        (formerly fast_inject: 0 and 1 keep their meaning, 2 = shell-uid InputManager).
 *   7 SWIPE  i32 x1, i32 y1, i32 x2, i32 y2, i32 duration_ms, i32 flags
 *                                            -> u32 prep_us, u32 inject_us, u8 inject_path
 *        a drag from (x1,y1) to (x2,y2) lasting duration_ms. flags & 1 (fling): lift at
 *        the end, like `adb shell input swipe`, so the content keeps its speed and flings.
 *        Otherwise the pointer stays still for SWIPE_HOLD_MS before lifting: no fling, the
 *        content moves by about the drag distance (less the first 16 dp, spent on touch
 *        slop). The events carry those timestamps but are injected right away, ending now;
 *        only the first MOVE waits for the app (~1 frame).
 *  13 PRESS  i32 x, i32 y, i32 hold_ms       -> u32 prep_us, u32 inject_us, u8 inject_path
 *        DOWN, held for hold_ms in real time (long press), UP.
 *   8 TYPE   str text                        -> u32 prep_us, u32 inject_us, u8 inject_path,
 *                                               u32 skipped
 *        key events into the focused field (virtual keyboard map, like `adb shell input
 *        text`). Text with a character no key produces (most non-ASCII) is inserted at the
 *        focused field's cursor instead, whole (insertText). skipped = characters not typed:
 *        those with no key sequence when no editable field has the input focus.
 *   9 ERASE  i32 count                       -> u32 prep_us, u32 inject_us, u8 inject_path
 *        count DEL key presses.
 *  12 MARK                                   -> (empty)
 *        an action without input: the next SETTLE measures from here (waiting for a screen
 *        that is already changing, e.g. Maestro's waitForAnimationToEnd).
 *  11 SHELL  str command                     -> bytes stdout
 *        runs as the shell user through UiAutomation (no shell syntax: the line is split on
 *        spaces). For app control: am force-stop, pm clear, pm grant, am start...
 *  14 SCREENSHOT                             -> bytes png
 *  21 LABEL    str package                     -> str label ("" when unknown)
 *        the app's name in the device's language (AppLabel).
 *  20 LOCATION str "providers lat lon interval_ms"
 *                                            -> u8 providers set
 *        test-provider location on each comma-separated provider, sent again every
 *        interval_ms until the next LOCATION or the client leaving (MockLocation). No
 *        providers only stops that. 0 set = not available here: use the shell commands.
 *   5 SETTLE i32 quiet_ms, i32 no_change_ms, i32 timeout_ms
 *                                            -> u8 status, u32 ui_done_us, u32 waited_us,
 *                                               u8 method, u32 frames, u32 probes, u32 probe_max_us,
 *                                               u32 events
 *        status: 0 = UI changed then went quiet, 1 = nothing changed, 2 = timeout
 *        method: 0 = window switches, frame stats and the active window's accessibility
 *                events, plus the idle probe; 1 = accessibility-event fallback
 *        frames/events = change signals seen of each kind
 *        times are measured from the last action (TAP, KEY, SWIPE, TYPE, ERASE, PRESS, MARK).
 *
 * Settle (method 0): the UI is settled when
 *   1. the active window id is stable,
 *   2. that window has presented no new frame for quiet_ms and sent no UI-change
 *      accessibility event for quiet_ms, or for EVENT_QUIET_MS after an in-place change
 *      (no window switch) last seen as an event, and
 *   3. an accessibility round trip to the app (served on its main thread) returns fast,
 *      which means the main thread is idle and not about to produce more frames.
 */
private object Op {
    const val PING = 1
    const val TREE = 2
    const val TAP = 3
    const val KEY = 4
    const val SETTLE = 5
    const val FIND = 6
    const val SWIPE = 7
    const val TYPE = 8
    const val ERASE = 9
    const val SCREEN = 10
    const val SHELL = 11
    const val MARK = 12
    const val PRESS = 13
    const val SCREENSHOT = 14
    const val LOCATION = 20
    const val LABEL = 21
}

// SWIPE without fling: pointer still for this long before lifting. Past the VelocityTracker's
// 40 ms "pointer stopped" threshold, so the gesture never flings.
private const val SWIPE_HOLD_MS = 60
private const val SWIPE_STEP_MS = 8 // one MOVE per ~120 Hz touch sample

// Quiet time needed after a UI-change accessibility event: apps send content-change and
// scroll events at most every ~100 ms, so a shorter gap does not prove the UI stopped.
private const val EVENT_QUIET_MS = 120

private const val SHELL_UID = 2000 // android.os.Process.SHELL_UID

/**
 * Shared by both entry points: AgentInstrumentation (UiAutomation from the instrumentation,
 * UiAutomation injection) and ShellMain (UiAutomation built in a shell-uid process,
 * InputManager injection).
 */
class Agent(private val ua: UiAutomation, private val injector: Injector) {
    // elapsedRealtimeNanos of the most recent UI-change accessibility event, from any window
    // and per window id.
    private val lastChange = AtomicLong(0L)
    private val lastChangeByWindow = ConcurrentHashMap<Int, Long>()
    // elapsedRealtimeNanos of the most recent injected action.
    @Volatile private var lastAction = 0L
    // Active window when the last action was injected (its frame stats are cleared then).
    private var actionWindow = -1

    private val bodyBuf = ByteArrayOutputStream(256 * 1024)
    private val body = DataOutputStream(bodyBuf)
    private val treeBuf = ByteArrayOutputStream(256 * 1024)
    private val tree = DataOutputStream(treeBuf)
    private val bounds = Rect()
    private val mockLocation = MockLocation()

    init {
        val info = ua.serviceInfo
        info.flags = info.flags or
            AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
            AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
            AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS // needed for ua.windows
        ua.serviceInfo = info

        // Event-driven change tracking: we never poll the tree to find out whether it changed.
        ua.setOnAccessibilityEventListener { e ->
            when (e.eventType) {
                AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
                AccessibilityEvent.TYPE_WINDOWS_CHANGED,
                AccessibilityEvent.TYPE_VIEW_SCROLLED,
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED -> {
                    val t = SystemClock.elapsedRealtimeNanos()
                    lastChange.set(t)
                    lastChangeByWindow[e.windowId] = t
                }
            }
        }
    }

    fun serve(port: Int) {
        ServerSocket(port, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            AgentLog.i("listening on 127.0.0.1:$port")
            while (true) {
                val sock = server.accept()
                sock.tcpNoDelay = true
                AgentLog.i("client connected")
                try {
                    val input = DataInputStream(BufferedInputStream(sock.getInputStream()))
                    val output = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 256 * 1024))
                    while (true) {
                        val op = input.read()
                        if (op < 0) break
                        handle(op, input, output)
                        output.flush()
                    }
                } catch (e: IOException) {
                    AgentLog.i("client gone: $e")
                } finally {
                    mockLocation.stop()
                    sock.close()
                }
            }
        }
    }

    private fun handle(op: Int, input: DataInputStream, out: DataOutputStream) {
        bodyBuf.reset()
        val t0 = SystemClock.elapsedRealtimeNanos()
        when (op) {
            Op.PING -> Unit
            Op.TREE -> writeTree()
            Op.TAP -> tap(input.readInt().toFloat(), input.readInt().toFloat())
            Op.KEY -> key(input.readInt())
            Op.SETTLE -> settle(input.readInt(), input.readInt(), input.readInt())
            Op.FIND -> writeFind(readStr(input))
            Op.SWIPE -> swipe(
                input.readInt().toFloat(), input.readInt().toFloat(),
                input.readInt().toFloat(), input.readInt().toFloat(), input.readInt(),
                fling = input.readInt() and 1 != 0,
            )
            Op.TYPE -> type(readStr(input))
            Op.ERASE -> erase(input.readInt())
            Op.SCREEN -> writeScreen()
            Op.SHELL -> shell(readStr(input))
            Op.MARK -> beginAction()
            Op.PRESS -> press(input.readInt().toFloat(), input.readInt().toFloat(), input.readInt())
            Op.SCREENSHOT -> screenshot()
            Op.LOCATION -> location(readStr(input))
            Op.LABEL -> writeStr(AppLabel.of(readStr(input)) ?: "")
            else -> throw IOException("unknown op $op")
        }
        body.flush()
        val agentUs = ((SystemClock.elapsedRealtimeNanos() - t0) / 1000).toInt()
        out.writeInt(4 + bodyBuf.size())
        out.writeInt(agentUs)
        bodyBuf.writeTo(out)
    }

    // ---- tree -------------------------------------------------------------------------

    /** Root of the active window, waiting up to ~100 ms for one to appear. */
    private fun activeRoot(): AccessibilityNodeInfo? {
        for (i in 0 until 20) {
            ua.rootInActiveWindow?.let { return it }
            Thread.sleep(5)
        }
        return null
    }

    private fun writeTree() {
        val root = activeRoot()
        if (root == null) {
            body.writeInt(0)
            return
        }

        treeBuf.reset()
        var count = 0
        val nodes = ArrayDeque<AccessibilityNodeInfo>()
        val depths = ArrayDeque<Int>()
        nodes.addLast(root)
        depths.addLast(0)
        while (nodes.isNotEmpty()) {
            val n = nodes.removeLast()
            val depth = depths.removeLast()
            writeNode(n, depth)
            count++
            // Push children in reverse so they pop in document order (pre-order DFS).
            for (i in n.childCount - 1 downTo 0) {
                val c = n.getChild(i) ?: continue
                nodes.addLast(c)
                depths.addLast(depth + 1)
            }
        }
        tree.flush()
        body.writeInt(count)
        treeBuf.writeTo(body)
    }

    /** One round trip: the app searches its own view hierarchy (see FIND in the protocol). */
    private fun writeFind(text: String) {
        val hits = activeRoot()?.findAccessibilityNodeInfosByText(text).orEmpty()
        treeBuf.reset()
        for (n in hits) writeNode(n, 0)
        tree.flush()
        body.writeInt(hits.size)
        treeBuf.writeTo(body)
    }

    private fun writeNode(n: AccessibilityNodeInfo, depth: Int) {
        n.getBoundsInScreen(bounds)
        tree.writeShort(depth)
        tree.writeInt(bounds.left)
        tree.writeInt(bounds.top)
        tree.writeInt(bounds.right)
        tree.writeInt(bounds.bottom)
        var f = 0
        if (n.isClickable) f = f or 1
        if (n.isEnabled) f = f or 2
        if (n.isFocused) f = f or 4
        if (n.isScrollable) f = f or 8
        if (n.isChecked) f = f or 16
        if (n.isVisibleToUser) f = f or 32
        if (n.isSelected) f = f or 64
        tree.writeByte(f)
        str(n.text)
        str(n.contentDescription)
        str(n.viewIdResourceName)
        str(n.className)
        str(n.hintText)
        str(n.error)
    }

    /** All windows, as Maestro's hierarchy dump sees them (see SCREEN in the protocol). */
    private fun writeScreen() {
        treeBuf.reset()
        var count = 0
        val seen = HashSet<Int>()
        val active = ua.rootInActiveWindow
        if (active != null) {
            seen.add(active.windowId)
            count += walkVisible(active)
        }
        val windows = try { ua.windows } catch (e: Exception) { emptyList() }
        for (w in windows) {
            if (!seen.add(w.id)) continue
            val root = w.root ?: continue
            count += walkVisible(root)
        }
        tree.flush()
        body.writeInt(count)
        treeBuf.writeTo(body)
    }

    /** Pre-order from a window root, skipping subtrees not visible to the user. */
    private fun walkVisible(root: AccessibilityNodeInfo): Int {
        var count = 0
        val nodes = ArrayDeque<AccessibilityNodeInfo>()
        val depths = ArrayDeque<Int>()
        val inWebView = ArrayDeque<Boolean>()
        nodes.addLast(root)
        depths.addLast(0)
        inWebView.addLast(false)
        while (nodes.isNotEmpty()) {
            val n = nodes.removeLast()
            val depth = depths.removeLast()
            // Like Maestro: a WebView's content is often reported invisible, so keep all of it.
            val web = inWebView.removeLast() || n.className?.contains("WebView") == true
            writeNode(n, depth)
            count++
            for (i in n.childCount - 1 downTo 0) {
                val c = n.getChild(i) ?: continue
                if (!web && !c.isVisibleToUser) continue
                nodes.addLast(c)
                depths.addLast(depth + 1)
                inWebView.addLast(web)
            }
        }
        return count
    }

    private fun shell(command: String) {
        val out = ByteArrayOutputStream()
        if (Process.myUid() == SHELL_UID) {
            // Already the shell user. UiAutomation.executeShellCommand loses the output here:
            // with the connection in-process it closes the pipe's write end on return, while
            // the command is still writing. Same argument splitting as that call.
            val args = command.split(' ').filter { it.isNotEmpty() }
            val process = ProcessBuilder(args).redirectErrorStream(true).start()
            process.inputStream.use { it.copyTo(out) }
            process.waitFor()
        } else {
            ParcelFileDescriptor.AutoCloseInputStream(ua.executeShellCommand(command)).use { it.copyTo(out) }
        }
        body.writeInt(out.size())
        out.writeTo(body)
    }

    private fun location(request: String) {
        val parts = request.split(' ')
        val providers = parts[0].split(',').filter { it.isNotEmpty() }
        val count = if (providers.isEmpty() || parts.size < 4) {
            mockLocation.stop()
            0
        } else {
            mockLocation.set(providers, parts[1].toDouble(), parts[2].toDouble(), parts[3].toLong())
        }
        body.writeByte(count)
    }

    private fun screenshot() {
        val bitmap = ua.takeScreenshot() ?: throw IOException("screenshot failed")
        val png = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, png)
        bitmap.recycle()
        body.writeInt(png.size())
        png.writeTo(body)
    }

    private fun writeStr(s: String) {
        val b = s.toByteArray(Charsets.UTF_8)
        val n = minOf(b.size, 0xFFFF)
        body.writeShort(n)
        body.write(b, 0, n)
    }

    private fun readStr(input: DataInputStream): String {
        val b = ByteArray(input.readUnsignedShort())
        input.readFully(b)
        return String(b, Charsets.UTF_8)
    }

    private fun str(s: CharSequence?) {
        if (s == null) {
            tree.writeShort(0)
            return
        }
        val b = s.toString().toByteArray(Charsets.UTF_8)
        val n = minOf(b.size, 0xFFFF)
        tree.writeShort(n)
        tree.write(b, 0, n)
    }

    // ---- input ------------------------------------------------------------------------
    // Injection is asynchronous: the call returns once the event is queued, not once the
    // app has handled it. Waiting for the app is settle()'s job, so the tap measures the tool.

    private fun beginAction() {
        actionWindow = activeWindowId()
        if (actionWindow >= 0) {
            // Clearing starts a fresh frame log, so every frame seen later came after the action.
            try { ua.clearWindowContentFrameStats(actionWindow) } catch (e: Exception) { }
        }
        lastAction = SystemClock.elapsedRealtimeNanos()
    }

    /** Runs an action and writes its timing breakdown to the response body. */
    private inline fun timedAction(injectAll: () -> Unit) {
        val t0 = SystemClock.elapsedRealtimeNanos()
        beginAction()
        val t1 = SystemClock.elapsedRealtimeNanos()
        injectAll()
        val t2 = SystemClock.elapsedRealtimeNanos()
        body.writeInt(((t1 - t0) / 1000).toInt())
        body.writeInt(((t2 - t1) / 1000).toInt())
        body.writeByte(injector.path) // after injecting, so a fallback taken mid-action shows
    }

    private fun tap(x: Float, y: Float) = timedAction {
        val downTime = SystemClock.uptimeMillis()
        injectMotion(MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0))
        injectMotion(MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, 0))
    }

    private fun injectMotion(e: MotionEvent, sync: Boolean = false) {
        e.source = InputDevice.SOURCE_TOUCHSCREEN
        injector.inject(e, sync)
        e.recycle()
    }

    private fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Int, fling: Boolean) = timedAction {
        val duration = durationMs.coerceIn(0, 10_000)
        val hold = if (fling) 0 else SWIPE_HOLD_MS
        val dx = x2 - x1
        val dy = y2 - y1
        // Timestamps end now, so the app sees the gesture's speed without us waiting it out.
        val down = SystemClock.uptimeMillis() - duration - hold
        fun move(f: Float, sync: Boolean = false) = injectMotion(
            MotionEvent.obtain(down, down + (duration * f).toLong(), MotionEvent.ACTION_MOVE, x1 + dx * f, y1 + dy * f, 0),
            sync,
        )
        injectMotion(MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x1, y1, 0))
        // First MOVE just past touch slop, handled by the app before the rest (about one
        // frame): a scrolling parent intercepts the gesture on it. Sent together, all MOVEs
        // reach the app as one batched MOVE, which the parent spends on intercepting, so
        // nothing would scroll.
        val dist = hypot(dx, dy)
        val first = if (dist > 0f) minOf(1f, swipeFirstMovePx / dist) else 1f
        move(first, sync = true)
        val steps = maxOf(1, duration / SWIPE_STEP_MS)
        for (i in 1..steps) {
            val f = i.toFloat() / steps
            if (f > first) move(f)
        }
        if (!fling) {
            // A second sample at the end leaves zero motion for touch resampling to
            // extrapolate, and lifting SWIPE_HOLD_MS after the drag stops means zero velocity.
            injectMotion(MotionEvent.obtain(down, down + duration + 10, MotionEvent.ACTION_MOVE, x2, y2, 0))
        }
        val up = maxOf(SystemClock.uptimeMillis(), down + duration + hold)
        injectMotion(MotionEvent.obtain(down, up, MotionEvent.ACTION_UP, x2, y2, 0))
    }

    private fun press(x: Float, y: Float, holdMs: Int) = timedAction {
        val down = SystemClock.uptimeMillis()
        injectMotion(MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, x, y, 0))
        Thread.sleep(holdMs.coerceIn(0, 60_000).toLong()) // the app's long-press timer runs in real time
        injectMotion(MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y, 0))
    }

    // 2x the 8 dp touch slop.
    private val swipeFirstMovePx = 16 * Resources.getSystem().displayMetrics.density

    private fun key(code: Int) = timedAction { pressKey(code) }

    private fun pressKey(code: Int, sync: Boolean = false) {
        val t = SystemClock.uptimeMillis()
        injector.inject(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
        injector.inject(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0), sync)
    }

    private val keyMap by lazy { KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD) }

    private fun type(text: String) {
        var skipped = 0
        timedAction {
            val keys = ArrayList<KeyEvent>()
            for (ch in text) {
                val events = keyMap.getEvents(charArrayOf(ch))
                if (events == null) {
                    skipped++
                    continue
                }
                for (e in events) {
                    e.source = InputDevice.SOURCE_KEYBOARD
                    keys += e
                }
            }
            if (skipped > 0 && insertText(text)) {
                skipped = 0
                return@timedAction
            }
            // Keys reach the app in order, so once the last one is handled, all are.
            keys.forEachIndexed { i, e -> injector.inject(e, sync = i == keys.lastIndex) }
        }
        body.writeInt(skipped)
    }

    /**
     * Text no key events can type: replaces the focused field's selection (the cursor), and
     * the cursor goes after it, as an input method's commitText would (Maestro switches to its
     * own IME for this). One accessibility action, served on the app's main thread, so the
     * text is in when it returns. False when no editable field has the input focus.
     */
    private fun insertText(text: String): Boolean {
        val node = ua.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        if (!node.isEditable) return false
        val current = if (node.isShowingHintText) "" else node.text?.toString() ?: ""
        var start = node.textSelectionStart
        var end = node.textSelectionEnd
        if (start !in 0..current.length || end !in 0..current.length) {
            start = current.length
            end = current.length
        }
        if (start > end) start = end.also { end = start }
        val args = Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
            current.substring(0, start) + text + current.substring(end),
        )
        if (!node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) return false
        val cursor = Bundle()
        cursor.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start + text.length)
        cursor.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, start + text.length)
        node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, cursor)
        return true
    }

    // The last DEL waits until the app has handled it (and so every DEL before it). The IME
    // applies DELs asynchronously; without the wait, spare DELs (erasing more characters than
    // the field holds) could land after the next command's first typed characters.
    private fun erase(count: Int) = timedAction {
        val n = count.coerceIn(0, 10_000)
        repeat(n) { pressKey(KeyEvent.KEYCODE_DEL, sync = it == n - 1) }
    }

    // ---- settle -----------------------------------------------------------------------

    /** System-side query (does not touch the app's main thread). */
    private fun activeWindowId(): Int {
        val windows = try { ua.windows } catch (e: Exception) { return -1 }
        var id = -1
        for (w in windows) if (w.isActive) id = w.id
        return id
    }

    /**
     * Latest posted-frame timestamp for the window since its stats were cleared,
     * Long.MIN_VALUE if no frame yet, or null if stats are unavailable.
     */
    private fun latestFrame(windowId: Int): Long? {
        val stats = try { ua.getWindowContentFrameStats(windowId) } catch (e: Exception) { null }
            ?: return null
        var latest = Long.MIN_VALUE
        for (i in 0 until stats.frameCount) latest = maxOf(latest, stats.getFramePostedTimeNano(i))
        return latest
    }

    /** Round trip served by the app's main thread; slow means the app is busy. Returns µs. */
    private fun probeMainThread(): Long {
        val t = SystemClock.elapsedRealtimeNanos()
        try {
            ua.rootInActiveWindow?.refresh() // refresh() bypasses the client-side node cache
        } catch (e: Exception) {
            // Window went away mid-probe: treat as busy.
            return Long.MAX_VALUE / 1000
        }
        return (SystemClock.elapsedRealtimeNanos() - t) / 1000
    }

    /**
     * Decided per call. The window we acted on may already be gone (BACK closes it), which is
     * a change in itself: settleFrames() then follows the new active window.
     */
    private fun settle(quietMs: Int, noChangeMs: Int, timeoutMs: Int) {
        val useFrames = actionWindow >= 0 &&
            (latestFrame(actionWindow) != null || activeWindowId().let { it >= 0 && it != actionWindow })
        if (useFrames) settleFrames(quietMs, noChangeMs, timeoutMs)
        else settleEvents(maxOf(quietMs, EVENT_QUIET_MS), noChangeMs, timeoutMs)
    }

    private fun settleFrames(quietMs: Int, noChangeMs: Int, timeoutMs: Int) {
        val start = lastAction
        val quiet = quietMs * 1_000_000L
        val eventQuiet = maxOf(quietMs, EVENT_QUIET_MS) * 1_000_000L
        val noChange = noChangeMs * 1_000_000L
        val timeout = timeoutMs * 1_000_000L
        val busyUs = 10_000L // an idle main thread answers in ~1 ms

        var window = actionWindow
        var seen = Long.MIN_VALUE   // latest frame timestamp already counted
        var frames = 0
        var changed = false
        var last = start            // time we last observed a change
        var probes = 0
        var probeMaxUs = 0L
        var status = 2
        var now = start

        var eventsSeen = start      // latest accessibility event already counted
        var events = 0
        var lastWasEvent = false    // the last change seen was an event
        var switched = false        // the active window changed since the action

        fun poll(): Boolean { // returns true if something changed
            val w = activeWindowId()
            if (w != window) {
                window = w
                seen = Long.MIN_VALUE
                lastWasEvent = false
                switched = true
                if (w >= 0) try { ua.clearWindowContentFrameStats(w) } catch (e: Exception) { }
                return true
            }
            if (w < 0) return false
            val f = latestFrame(w)
            if (f != null && f > seen) {
                seen = f
                frames++
                lastWasEvent = false
                return true
            }
            // Accessibility events from the active window: the only signal for in-place changes
            // (scroll, typing) when frame stats stay empty, as on Android 12+ where a window
            // draws into a child (BLAST) layer they do not see. Apps send content-change and
            // scroll events at most every ~100 ms, so after an in-place change we wait out
            // eventQuiet. After a window switch the short quiet plus the idle probe has been
            // enough (the next lookup always finds its target), and the burst of events every
            // new window sends would otherwise add ~100 ms to each transition.
            val ev = lastChangeByWindow[w] ?: 0L
            if (ev > eventsSeen) {
                eventsSeen = ev
                events++
                lastWasEvent = true
                return true
            }
            return false
        }

        while (true) {
            now = SystemClock.elapsedRealtimeNanos()
            if (poll()) { changed = true; last = now }

            val quietReached = changed && now - last >= if (lastWasEvent && !switched) eventQuiet else quiet
            val noChangeReached = !changed && now - start >= noChange
            if (quietReached || noChangeReached) {
                val p = probeMainThread()
                probes++
                probeMaxUs = maxOf(probeMaxUs, p)
                now = SystemClock.elapsedRealtimeNanos()
                val busy = p > busyUs
                if (poll() || busy) {
                    // App was working or drew during the probe: not settled, keep watching.
                    changed = true
                    last = now
                } else {
                    status = if (changed) 0 else 1
                    break
                }
            }
            if (now - start >= timeout) { status = 2; break }
            Thread.sleep(5)
        }

        body.writeByte(status)
        body.writeInt(if (changed) ((last - start) / 1000).toInt() else 0)
        body.writeInt(((now - start) / 1000).toInt())
        body.writeByte(0)
        body.writeInt(frames)
        body.writeInt(probes)
        body.writeInt(minOf(probeMaxUs, Int.MAX_VALUE.toLong()).toInt())
        body.writeInt(events)
    }

    /** Fallback: Android coalesces content-change events (~100 ms), hence the larger window. */
    private fun settleEvents(quietMs: Int, noChangeMs: Int, timeoutMs: Int) {
        val start = lastAction
        val quiet = quietMs * 1_000_000L
        val noChange = noChangeMs * 1_000_000L
        val timeout = timeoutMs * 1_000_000L
        var status = 2
        var now = start
        while (true) {
            now = SystemClock.elapsedRealtimeNanos()
            val last = lastChange.get()
            if (last > start) {
                if (now - last >= quiet) { status = 0; break }
            } else if (now - start >= noChange) {
                status = 1; break
            }
            if (now - start >= timeout) { status = 2; break }
            Thread.sleep(1)
        }
        val last = lastChange.get()
        body.writeByte(status)
        body.writeInt(if (last > start) ((last - start) / 1000).toInt() else 0)
        body.writeInt(((now - start) / 1000).toInt())
        body.writeByte(1)
        body.writeInt(0)
        body.writeInt(0)
        body.writeInt(0)
        body.writeInt(0)
    }
}
