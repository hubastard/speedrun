package com.speedrun.agent

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.AttributionSource
import android.content.res.Resources
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.IBinder
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

/** How long a chunk of typed keys should take the app, at its last pace (see injectKeys). */
private const val KEY_CHUNK_MS = 500L
/** The most key presses in a chunk: a sudden slowdown has to pass 600 ms a key to lose one. */
private const val KEY_CHUNK_MAX = 16

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
 * Wire protocol (big-endian). A connection starts with the agent's token (TOKEN_LENGTH ASCII
 * characters, given when it was started; see serve), then:
 *   request  = u8 op, then op-specific fields
 *   response = u32 length, u32 agent_us, body[length - 4]
 *   str = u16 len + utf8; bytes = u32 len + data
 *
 *   1 PING                                   -> (empty)
 *   2 TREE                                   -> u32 count, count * node
 *        the active window, every node (invisible ones too), pre-order
 *        node = u16 depth, i32 l, i32 t, i32 r, i32 b, u8 flags,
 *               str text, str desc, str id, str class, str hint, str error, u16 drawing
 *        drawing: the view's drawing order among its siblings (higher: drawn over them)
 *        flags: 1 clickable, 2 enabled, 4 focused, 8 scrollable, 16 checked,
 *               32 visible to user, 64 selected
 *  10 SCREEN                                 -> u32 count, count * node, u8 stalled
 *        every window (active one first, then status bar, dialogs, keyboard...), each root
 *        at depth 0, keeping only children the system reports visible to the user (all of
 *        a WebView's): the hierarchy flows' selectors match against. stalled = 1 when a
 *        window's app did not answer an accessibility call (see child): that window is read
 *        in part.
 *   6 FIND   str text                        -> u32 count, count * node
 *        nodes of the active window whose text or content description contains text,
 *        ignoring case, in document order (depth is 0). The app's own search: one round
 *        trip instead of TREE's ~40 after a screen change. Text an app sets only through an
 *        accessibility delegate is not searched; fall back to TREE when FIND finds nothing.
 *   3 TAP    i32 x, i32 y                    -> u32 prep_us, u32 inject_us, u8 inject_path,
 *                                               u16 dropped, u32 dropped_us, u8 taken,
 *                                               u32 transition_us
 *   4 KEY    i32 keycode                     -> u32 prep_us, u32 inject_us, u8 inject_path
 *        prep = active-window lookup + frame-stats clear; inject_path = see InjectPath
 *        (formerly fast_inject: 0 and 1 keep their meaning, 2 = shell-uid InputManager).
 *        dropped = DOWNs the system dropped before one was taken (no window took touches
 *        there: a window opening), dropped_us = how long they held the touch off, taken = 0
 *        when it dropped them all for TOUCH_DROPPED_MAX_MS; transition_us = how long the
 *        touch waited for window transitions, a new window being active (see touchDown).
 *   7 SWIPE  i32 x1, i32 y1, i32 x2, i32 y2, i32 duration_ms, i32 flags
 *                                            -> u32 prep_us, u32 inject_us, u8 inject_path,
 *                                               u16 dropped, u32 dropped_us, u8 taken,
 *                                               u32 transition_us
 *        a drag from (x1,y1) to (x2,y2) lasting duration_ms. flags & 1 (fling): lift at
 *        the end, like `adb shell input swipe`, so the content keeps its speed and flings.
 *        Otherwise the pointer stays still for SWIPE_HOLD_MS before lifting: no fling, the
 *        content moves by about the drag distance (less the first 16 dp, spent on touch
 *        slop). flags & 2 (cancel): a CANCEL instead of the lift, which no scroll view flings
 *        on, but a paging list does not snap on either. The events carry those timestamps but
 *        are injected right away, ending now; only the first MOVE waits for the app (~1 frame).
 *  13 PRESS  i32 x, i32 y, i32 hold_ms       -> u32 prep_us, u32 inject_us, u8 inject_path,
 *                                               u16 dropped, u32 dropped_us, u8 taken,
 *                                               u32 transition_us
 *        DOWN, held for hold_ms in real time (long press), UP.
 *   8 TYPE   str text                        -> u32 prep_us, u32 inject_us, u8 inject_path,
 *                                               u32 skipped, u8 focused, u8 input,
 *                                               u32 input_wait_us
 *        key events into the focused field (virtual keyboard map, like `adb shell input
 *        text`). Text with a character no key produces (most non-ASCII) is inserted at the
 *        focused field's cursor instead, whole (insertText). skipped = characters not typed:
 *        those with no key sequence when no editable field has the input focus. focused = 1
 *        when an editable field had the input focus as typing began (0: the keys went to
 *        whatever had it). Keys wait for the system to start input on that field first (the
 *        keyboard app is told of it then; keys before met a keyboard that took the field as
 *        it was): input = 0 not known (before Android 14, the key service not up), 1 started
 *        already, 2 started after input_wait_us, 3 did not start in a second (typed anyway).
 *  26 TYPE_PACED str text                    -> as TYPE
 *        TYPE, each key once the one before changed the field (injectPaced), with the key
 *        service up; SPEEDRUN_PACED_TYPING=1 on the host.
 *   9 ERASE  i32 count                       -> u32 prep_us, u32 inject_us, u8 inject_path
 *        count DEL key presses.
 *  12 MARK                                   -> (empty)
 *        an action without input: the next SETTLE measures from here (waiting for a screen
 *        that is already changing, e.g. waitForAnimationToEnd).
 *  17 LAUNCHED str package, i32 timeout_ms   -> u8 ok
 *        waits until a window of the package shows a UI that answers (its root can be
 *        read), the app being launched; ok 0 at the timeout.
 *  11 SHELL  str command                     -> bytes stdout
 *        runs as the shell user through UiAutomation (no shell syntax: the line is split on
 *        spaces). For app control: am force-stop, pm clear, pm grant, am start...
 *  14 SCREENSHOT                             -> bytes png
 *  22 PERMS    str package                     -> u8 ok, u16 count, count * (str name,
 *                                               u8 flags, u8 app_op_mode)
 *        the permissions the app requests (Permissions): flags bit 0 granted, bit 1
 *        runtime; app_op_mode for MANAGE_EXTERNAL_STORAGE (0 allowed, 2 errored, 3 default),
 *        255 for the others. ok 0 = not readable here: use dumpsys.
 *  25 FOCUS                                   -> u8 found, i32 left, top, right, bottom
 *        the editable field with the input focus (inputFocus), and its bounds.
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
 *                                               u32 events, u32 js_us, u32 js_ran_us
 *        status: 0 = UI changed then went quiet, 1 = nothing changed, 2 = timeout
 *        method: 0 = window switches, frame stats and the active window's accessibility
 *                events, plus the idle probe; 1 = accessibility-event fallback; 3 = either,
 *                then the tree with an endless animation left out (Restless)
 *        frames/events = change signals seen of each kind; js_us = how long a busy JavaScript
 *        thread held it off (4. below); js_ran_us = CPU time the JavaScript threads used while
 *        it ran (0 for an app without one)
 *        times are measured from the last action (TAP, KEY, SWIPE, TYPE, ERASE, PRESS, MARK).
 *
 * Settle (method 0): the UI is settled when
 *   1. the active window id is stable,
 *   2. that window has presented no new frame for quiet_ms and sent no UI-change
 *      accessibility event for quiet_ms, or for EVENT_QUIET_MS after an in-place change
 *      (no window switch) last seen as an event, and
 *   3. an accessibility round trip to the app (served on its main thread) returns fast,
 *      which means the main thread is idle and not about to produce more frames, and
 *   4. in a React Native app, its JavaScript thread is idle too (JsThread), for at most
 *      JS_WAIT_MAX_NS: the tree can show a screen that does not take touches yet.
 * An animation that never ends (an Animated loop, a ticker, a counter) draws frames forever:
 * once changes have gone on for RESTLESS_START_MS, the tree is read too, and the UI is settled
 * (method 3) when it holds still but for a few elements that change on every read (Restless),
 * the main thread idle. Before, such a screen settled only in the loop's rare pauses, else at
 * the timeout: 10 s per tap.
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
    const val LAUNCHED = 17
    const val LOCATION = 20
    const val LABEL = 21
    const val PERMS = 22
    const val FOCUS = 25
    const val TYPE_PACED = 26
}

// SWIPE without fling: pointer still for this long before lifting. Past the VelocityTracker's
// 40 ms "pointer stopped" threshold, so the gesture never flings.
private const val SWIPE_HOLD_MS = 60
private const val SWIPE_STEP_MS = 8 // one MOVE per ~120 Hz touch sample
// A drag's lift waits this long after its moves (real time): over a frame, so the app handles
// the moves and the lift in different frames, as a finger's.
private const val SWIPE_LIFT_GAP_MS = 25L
// A typed key that changes nothing in the field is waited for this long (Agent.injectPaced).
private const val PACE_TIMEOUT_MS = 500L

// An accessibility call the app doesn't answer returns empty after AccessibilityInteraction-
// Client's 5 s timeout. One that took this long timed out (see child).
private const val STALLED_CALL_MS = 4000L

// A DOWN the system dropped (see touchDown) is put down again this often, for this long.
private const val TOUCH_RETRY_MS = 30L
private const val TOUCH_DROPPED_MAX_NS = 2_000_000_000L

// Quiet time needed after a UI-change accessibility event: apps send content-change and
// scroll events at most every ~100 ms, so a shorter gap does not prove the UI stopped.
private const val EVENT_QUIET_MS = 120

// Endless animations (see Settle): the tree is read every RESTLESS_READ_MS once changes have
// gone on for RESTLESS_START_MS since the action (or the last window switch). An element whose
// frame or text changed on every read for RESTLESS_MS, while most of the tree holds still, is
// restless; a pause of up to RESTLESS_PAUSE_MS does not end its moving (a loop turning
// around). The iOS agent's values (Screen.swift).
private const val RESTLESS_START_NS = 500_000_000L
private const val RESTLESS_READ_NS = 100_000_000L
private const val RESTLESS_NS = 500_000_000L
private const val RESTLESS_PAUSE_NS = 600_000_000L

// A busy JavaScript thread (React Native, see JsThread) holds a settle off for this long at
// most. An app whose JavaScript stays that busy is then not waited for again until it has been
// seen idle once.
private const val JS_WAIT_MAX_NS = 2_000_000_000L

private const val SHELL_UID = 2000 // android.os.Process.SHELL_UID

// A Toast is its own window, which the windows list leaves out (it takes no touches); its text
// comes in an accessibility event. It counts as on screen for Toast.LENGTH_LONG (3.5 s) from
// that event, as in Maestro: the event doesn't say which length the app chose.
private const val TOAST_NS = 3_500_000_000L

/**
 * Shared by both entry points: AgentInstrumentation (UiAutomation from the instrumentation,
 * UiAutomation injection) and ShellMain (UiAutomation built in a shell-uid process,
 * InputManager injection).
 */
/** The token every connection starts with (serve), and how long the agent waits for it. */
const val TOKEN_LENGTH = 32
private const val TOKEN_WAIT_MS = 5000

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
    // The React Native app in front's JavaScript thread (see JsThread), and that app's package,
    // as the last main-thread probe found it.
    private val js = JsThread()
    @Volatile private var frontPackage: String? = null

    // The latest Toast's texts, and until when it shows (elapsedRealtimeNanos).
    @Volatile private var toastTexts: List<String> = emptyList()
    @Volatile private var toastUntil = 0L

    private val serviceInfo: AccessibilityServiceInfo = ua.serviceInfo

    /**
     * The last read showed Compose content: its host view (ComposeView), or a node Compose made
     * (its extra data keys are Compose's, androidx.compose.ui.semantics.id). A bottom sheet's,
     * a dialog's or a popup's window has no ComposeView: its host reads as a ViewGroup (issue
     * #9: in an app's panel, a dot that came on a tab, and a row's detail, were never read).
     * Compose sends accessibility events only while an accessibility service is enabled, and a
     * UiAutomation client is none: nothing evicts its nodes from this client's node cache, and
     * a read refreshes only the root and the ~50 nodes fetched with it, serving the others as
     * they were (a node removed stays, as long as the views' sizes hold). While it shows, each
     * read starts from an empty cache (freshNodes); View-based apps send events, and keep it.
     * The key service (KeyService.kt) is an enabled service: while it is on, Compose sends
     * events too.
     */
    private var composeShown = false

    init {
        val info = serviceInfo
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
                AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED ->
                    if (e.className?.toString()?.startsWith("android.widget.Toast") == true) {
                        // Its message, and on recent Android versions the app's name too.
                        val texts = e.text.map { it.toString() }.filter { it.isNotEmpty() }
                        if (texts.isNotEmpty()) {
                            val t = SystemClock.elapsedRealtimeNanos()
                            toastTexts = texts
                            toastUntil = t + TOAST_NS
                            lastChange.set(t)
                        }
                    }
            }
        }
    }

    /**
     * Serves one client at a time. A connection starts with the token the agent was started
     * with (TOKEN_LENGTH ASCII characters, within TOKEN_WAIT_MS); without it, it is closed:
     * 127.0.0.1 is the device's, and any app on it could otherwise connect and run SHELL as the
     * shell user (or as the agent's app, for the instrumentation).
     */
    fun serve(port: Int, token: String) {
        require(token.length == TOKEN_LENGTH) { "the agent needs a $TOKEN_LENGTH-character token" }
        val expected = token.toByteArray(Charsets.US_ASCII)
        ServerSocket(port, 1, InetAddress.getByName("127.0.0.1")).use { server ->
            AgentLog.i("listening on 127.0.0.1:$port")
            while (true) {
                val sock = server.accept()
                sock.tcpNoDelay = true
                try {
                    val input = DataInputStream(BufferedInputStream(sock.getInputStream()))
                    val output = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 256 * 1024))
                    sock.soTimeout = TOKEN_WAIT_MS
                    val got = ByteArray(TOKEN_LENGTH)
                    input.readFully(got)
                    if (!java.security.MessageDigest.isEqual(got, expected)) {
                        AgentLog.i("a client without the token: closed")
                        continue
                    }
                    sock.soTimeout = 0
                    AgentLog.i("client connected")
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
            Op.SWIPE -> {
                val x1 = input.readInt().toFloat()
                val y1 = input.readInt().toFloat()
                val x2 = input.readInt().toFloat()
                val y2 = input.readInt().toFloat()
                val duration = input.readInt()
                val flags = input.readInt()
                swipe(x1, y1, x2, y2, duration, fling = flags and 1 != 0, cancel = flags and 2 != 0)
            }
            Op.TYPE -> type(readStr(input), paced = false)
            Op.TYPE_PACED -> type(readStr(input), paced = true)
            Op.ERASE -> erase(input.readInt())
            Op.SCREEN -> writeScreen()
            Op.SHELL -> shell(readStr(input))
            Op.MARK -> beginAction()
            Op.PRESS -> press(input.readInt().toFloat(), input.readInt().toFloat(), input.readInt())
            Op.SCREENSHOT -> screenshot()
            Op.LOCATION -> location(readStr(input))
            Op.LABEL -> writeStr(AppLabel.of(readStr(input)) ?: "")
            Op.PERMS -> writePermissions(readStr(input))
            Op.FOCUS -> writeFocus()
            Op.LAUNCHED -> body.writeByte(if (launched(readStr(input), input.readInt())) 1 else 0)
            else -> throw IOException("unknown op $op")
        }
        body.flush()
        val agentUs = ((SystemClock.elapsedRealtimeNanos() - t0) / 1000).toInt()
        out.writeInt(4 + bodyBuf.size())
        out.writeInt(agentUs)
        bodyBuf.writeTo(out)
    }

    // ---- tree -------------------------------------------------------------------------

    /** Empties the node cache before a read while Compose shows (composeShown). */
    private fun freshNodes() {
        if (!composeShown) return
        if (android.os.Build.VERSION.SDK_INT >= 34) ua.clearCache()
        else ua.serviceInfo = serviceInfo // setting it clears the cache
    }

    private fun isCompose(n: AccessibilityNodeInfo): Boolean =
        n.className?.startsWith("androidx.compose.ui.platform.") == true ||
            n.availableExtraData.any { it.startsWith("androidx.compose.ui.semantics.") }

    // A walk of the tree met a call the app did not answer (child).
    private var stalled = false

    /**
     * n's child i, noting in [stalled] a call the app did not answer: its UI thread blocked (an
     * app hanging, a device starved of memory), each call waits 5 s and returns nothing. A walk
     * that went on paid that for every node not fetched yet, and left out each one that failed:
     * one read took 355 s and came back with 76 of the screen's ~108 nodes, which flows then
     * matched against. Walks stop at a stalled call instead, and SCREEN says so (the host reads
     * again until the app answers).
     */
    private fun child(n: AccessibilityNodeInfo, i: Int): AccessibilityNodeInfo? {
        val t = SystemClock.uptimeMillis()
        val c = n.getChild(i)
        if (SystemClock.uptimeMillis() - t >= STALLED_CALL_MS) stalled = true
        return c
    }

    /** A window's root, noting in [stalled] a call the app did not answer (see child). */
    private fun rootOf(get: () -> AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        val t = SystemClock.uptimeMillis()
        val root = get()
        if (SystemClock.uptimeMillis() - t >= STALLED_CALL_MS) stalled = true
        return root
    }

    /** Root of the active window, waiting up to ~100 ms for one to appear. */
    private fun activeRoot(): AccessibilityNodeInfo? {
        for (i in 0 until 20) {
            ua.rootInActiveWindow?.let { return it }
            Thread.sleep(5)
        }
        return null
    }

    private fun writeTree() {
        freshNodes()
        val root = activeRoot()
        if (root == null) {
            body.writeInt(0)
            return
        }

        treeBuf.reset()
        var count = 0
        var compose = false
        val nodes = ArrayDeque<AccessibilityNodeInfo>()
        val depths = ArrayDeque<Int>()
        nodes.addLast(root)
        depths.addLast(0)
        stalled = false
        while (nodes.isNotEmpty() && !stalled) {
            val n = nodes.removeLast()
            val depth = depths.removeLast()
            writeNode(n, depth)
            count++
            if (!compose && isCompose(n)) compose = true
            // Push children in reverse so they pop in document order (pre-order DFS).
            for (i in n.childCount - 1 downTo 0) {
                val c = child(n, i) ?: continue
                nodes.addLast(c)
                depths.addLast(depth + 1)
            }
        }
        root.getBoundsInScreen(bounds)
        count += writeToast(bounds)
        composeShown = compose
        tree.flush()
        body.writeInt(count)
        treeBuf.writeTo(body)
    }

    /** One round trip: the app searches its own view hierarchy (see FIND in the protocol). */
    private fun writeFind(text: String) {
        freshNodes()
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
        tree.writeShort(n.drawingOrder.coerceIn(0, 0xffff))
    }

    /**
     * The Toast showing, if any: a root of its own per text (its message, the app's name), an
     * android.widget.Toast node each, where Android puts a Toast by default (centred, near the
     * bottom of `screen`). The number of nodes written.
     */
    private fun writeToast(screen: Rect): Int {
        val texts = toastTexts
        if (texts.isEmpty() || SystemClock.elapsedRealtimeNanos() >= toastUntil || screen.isEmpty) return 0
        val w = screen.width()
        val h = screen.height()
        val top = screen.bottom - h / 6
        val line = (h / 6 - h / 10) / texts.size
        for ((i, text) in texts.withIndex()) {
            tree.writeShort(0)
            tree.writeInt(screen.left + w / 8)
            tree.writeInt(top + i * line)
            tree.writeInt(screen.right - w / 8)
            tree.writeInt(top + (i + 1) * line)
            tree.writeByte(2 or 32) // enabled, visible
            str(text)
            str(null)
            str(null)
            str("android.widget.Toast")
            str(null)
            str(null)
            tree.writeShort(0)
        }
        return texts.size
    }

    /** All windows, as flows see them (see SCREEN in the protocol). */
    private fun writeScreen() {
        freshNodes()
        treeBuf.reset()
        var count = 0
        walkCompose = false
        val seen = HashSet<Int>()
        val screen = Rect()
        // Each window on its own: one whose app does not answer is read in part, the others
        // (the status bar, an "isn't responding" dialog) in full.
        var anyStalled = false
        stalled = false
        val active = rootOf { ua.rootInActiveWindow }
        anyStalled = stalled
        if (active != null) {
            seen.add(active.windowId)
            active.getBoundsInScreen(screen)
            count += walkVisible(active)
            anyStalled = anyStalled || stalled
        }
        val windows = try { ua.windows } catch (e: Exception) { emptyList() }
        for (w in windows) {
            if (!seen.add(w.id)) continue
            stalled = false
            val root = rootOf { w.root }
            anyStalled = anyStalled || stalled
            if (root == null) continue
            if (screen.isEmpty) root.getBoundsInScreen(screen)
            count += walkVisible(root)
            anyStalled = anyStalled || stalled
        }
        count += writeToast(screen)
        composeShown = walkCompose
        tree.flush()
        body.writeInt(count)
        treeBuf.writeTo(body)
        body.writeByte(if (anyStalled) 1 else 0)
    }

    /** walkVisible met Compose content (composeShown). */
    private var walkCompose = false

    /** Pre-order from a window root, skipping subtrees not visible to the user. */
    private fun walkVisible(root: AccessibilityNodeInfo): Int {
        var count = 0
        val nodes = ArrayDeque<AccessibilityNodeInfo>()
        val depths = ArrayDeque<Int>()
        val inWebView = ArrayDeque<Boolean>()
        nodes.addLast(root)
        depths.addLast(0)
        inWebView.addLast(false)
        stalled = false
        while (nodes.isNotEmpty() && !stalled) {
            val n = nodes.removeLast()
            val depth = depths.removeLast()
            // A WebView's content is often reported invisible, so keep all of it.
            val web = inWebView.removeLast() || n.className?.contains("WebView") == true
            writeNode(n, depth)
            count++
            if (!walkCompose && isCompose(n)) walkCompose = true
            for (i in n.childCount - 1 downTo 0) {
                val c = child(n, i) ?: continue
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

    private fun writePermissions(packageName: String) {
        val list = Permissions.of(packageName)
        body.writeByte(if (list == null) 0 else 1)
        body.writeShort(list?.size ?: 0)
        for (p in list ?: emptyList()) {
            writeStr(p.name)
            body.writeByte((if (p.granted) 1 else 0) or (if (p.runtime) 2 else 0))
            body.writeByte(p.appOpMode)
        }
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

    private fun tap(x: Float, y: Float) {
        timedAction {
            val downTime = touchDown(x, y)
            injectMotion(touch(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y))
        }
        writeTouch()
    }

    // The last touch's DOWNs the system dropped (touchDown), how long they held it off,
    // whether it took one in the end, and how long it waited for window transitions.
    private var dropped = 0
    private var droppedNs = 0L
    private var touchTaken = true
    private var transitionNs = 0L
    // The last touch's down time (uptime ms): input started before it can be the field before.
    private var lastTouchDown = 0L

    private fun writeTouch() {
        body.writeShort(minOf(dropped, 0xFFFF))
        body.writeInt((droppedNs / 1000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
        body.writeByte(if (touchTaken) 1 else 0)
        body.writeInt((transitionNs / 1000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
    }

    // The active window at the last touch or key.
    private var inputWindow = Int.MIN_VALUE

    // UiAutomation.syncInputTransactions(waitForAnimations), hidden: with true, the window
    // manager waits (up to 5 s) until no transition or window animation runs, then until the
    // input dispatcher has the windows as they are. Null when missing.
    private var syncInput: java.lang.reflect.Method? = try {
        UiAutomation::class.java.getMethod("syncInputTransactions", java.lang.Boolean.TYPE)
    } catch (t: Throwable) {
        AgentLog.w("UiAutomation.syncInputTransactions(waitForAnimations) missing: input doesn't wait for window transitions")
        null
    }

    /**
     * A touch or a key in another window than the last one's waits for window transitions: a
     * window that is opening, and the one it covers, take no touches until its transition ends,
     * and a touch on either went to no window (issue #9). A key goes to the focused window,
     * which a closing window can still be: after a back closed a sheet's editor, the next back
     * left the sheet open (issue #9's reporter, v0.4.8). Only then, as the wait costs ~30 ms
     * even with nothing running (the window manager hands the dispatcher its windows);
     * UiAutomation's injection, which UiAutomator and Maestro use, waits so before every event.
     */
    private fun waitForTransitions() {
        transitionNs = 0
        if (actionWindow == inputWindow) return
        val m = syncInput ?: return
        val t = SystemClock.elapsedRealtimeNanos()
        try {
            m.invoke(ua, true)
        } catch (e: Throwable) {
            AgentLog.w("syncInputTransactions failed; input doesn't wait for window transitions", cause(e))
            syncInput = null
            return
        }
        transitionNs = SystemClock.elapsedRealtimeNanos() - t
        beginAction() // the settle measures from the input, not from before the transition
        inputWindow = actionWindow
    }

    /**
     * Puts a finger down at x, y, stamped at() (now by default), and returns its down time. A
     * window that is opening takes no touches until its transition lets it, and the one under
     * it none either: the system drops a DOWN there ("no touchable window"), and its gesture
     * with it, though injecting it went fine (issue #9: an Activity's Button tapped as it came
     * in, ~230 ms into its open transition on API 35, did nothing). So the DOWN waits for the
     * input dispatcher to pick its window, and one it dropped goes down again every
     * TOUCH_RETRY_MS, for up to TOUCH_DROPPED_MAX_NS. The settle then measures from the DOWN
     * it took. Waiting costs well under a millisecond when the dispatcher is idle. A touch
     * can't always tell: with gesture navigation a system spy window under every touch takes
     * the DOWN, and the dispatcher counts that as delivered. So a touch in a window that just
     * came first waits for window transitions (waitForTransitions).
     */
    private fun touchDown(x: Float, y: Float, at: () -> Long = { SystemClock.uptimeMillis() }): Long {
        dropped = 0
        droppedNs = 0
        touchTaken = true
        waitForTransitions()
        val start = SystemClock.elapsedRealtimeNanos()
        while (true) {
            val down = at()
            val e = touch(down, down, MotionEvent.ACTION_DOWN, x, y)
            lastEventTime = maxOf(lastEventTime, down)
            touchTaken = injector.deliver(e)
            e.recycle()
            if (touchTaken) {
                if (dropped > 0) beginAction()
                lastTouchDown = down
                return down
            }
            dropped++
            droppedNs = SystemClock.elapsedRealtimeNanos() - start
            // Ends the dropped gesture for an input verifier that counted its DOWN. Stamped at
            // its down time, so a SWIPE's next DOWN, stamped in the past, comes after it.
            injectMotion(touch(down, down, MotionEvent.ACTION_CANCEL, x, y))
            if (droppedNs >= TOUCH_DROPPED_MAX_NS) {
                AgentLog.w("the system dropped $dropped touches at $x,$y over ${droppedNs / 1_000_000} ms: no window takes touches there")
                return down
            }
            Thread.sleep(TOUCH_RETRY_MS)
        }
    }

    /**
     * A one-finger touch event, as a finger on the touchscreen makes it and `adb shell input`
     * and UiAutomator inject it: the pointer's tool type a finger, the device the touchscreen.
     * MotionEvent.obtain(downTime, eventTime, action, x, y, metaState) leaves the tool type
     * unknown and the device 0, which Compose turns into PointerType.Unknown: buttons took
     * such taps, but an app's Compose text fields never took the focus from them (issue #8).
     */
    private fun touch(down: Long, at: Long, action: Int, x: Float, y: Float): MotionEvent {
        val coords = pointerCoords[0]
        coords.clear()
        coords.x = x
        coords.y = y
        coords.pressure = 1f
        coords.size = 1f
        return MotionEvent.obtain(down, at, action, 1, fingerProperties, pointerCoords, 0, 0, 1f, 1f,
            touchscreen, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
    }

    private val fingerProperties = arrayOf(MotionEvent.PointerProperties().apply { id = 0; toolType = MotionEvent.TOOL_TYPE_FINGER })
    private val pointerCoords = arrayOf(MotionEvent.PointerCoords())

    // The device's touchscreen, as `adb shell input` picks it (0 when there is none).
    private val touchscreen by lazy {
        try {
            InputDevice.getDeviceIds().firstOrNull { InputDevice.getDevice(it)?.supportsSource(InputDevice.SOURCE_TOUCHSCREEN) == true } ?: 0
        } catch (e: Exception) {
            0
        }
    }

    private fun injectMotion(e: MotionEvent, sync: Boolean = false) {
        e.source = InputDevice.SOURCE_TOUCHSCREEN
        lastEventTime = maxOf(lastEventTime, e.eventTime)
        injector.inject(e, sync)
        e.recycle()
    }

    // The latest event time injected. A SWIPE stamped in the past starts after it: Android 17's
    // input verifier refuses a gesture whose down time is earlier than the last one's ("Down
    // time went backwards"), and a gesture that starts before the previous one lifted (in event
    // time) came out reversed: touch resampling mixed the two (a swipe up seen as a swipe down
    // right after a swipe right).
    private var lastEventTime = 0L

    private fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Int, fling: Boolean, cancel: Boolean) {
        timedAction { drag(x1, y1, x2, y2, durationMs, fling, cancel) }
        writeTouch()
    }

    private fun drag(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Int, fling: Boolean, cancel: Boolean) {
        val duration = durationMs.coerceIn(0, 10_000)
        val hold = if (fling) 0 else SWIPE_HOLD_MS
        val dx = x2 - x1
        val dy = y2 - y1
        if (fling) {
            // A swipe (the flow's `swipe`) plays out in real time, as a finger's does. Stamped
            // in the past and sent at once, a React Native Gesture Handler pan sometimes ended
            // with no movement (a swipe left read as a swipe down, 1 run in 3).
            val early = lastEventTime + 1 - SystemClock.uptimeMillis()
            if (early > 0) Thread.sleep(early)
            val down = touchDown(x1, y1)
            if (!touchTaken) return
            val steps = maxOf(1, duration / SWIPE_STEP_MS)
            for (i in 1..steps) {
                val f = i.toFloat() / steps
                val at = down + (duration * f).toLong()
                val wait = at - SystemClock.uptimeMillis()
                if (wait > 0) Thread.sleep(wait)
                injectMotion(touch(down, maxOf(at, SystemClock.uptimeMillis()), MotionEvent.ACTION_MOVE, x1 + dx * f, y1 + dy * f))
            }
            injectMotion(touch(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x2, y2))
            return
        }
        // Timestamps end now, so the app sees the gesture's speed without us waiting it out,
        // unless that would start it before the last gesture did (a tap just before).
        val early = lastEventTime + 1 - (SystemClock.uptimeMillis() - duration - hold)
        if (early > 0) Thread.sleep(early)
        val down = touchDown(x1, y1) { SystemClock.uptimeMillis() - duration - hold }
        if (!touchTaken) return
        fun move(f: Float, sync: Boolean = false) = injectMotion(
            touch(down, down + (duration * f).toLong(), MotionEvent.ACTION_MOVE, x1 + dx * f, y1 + dy * f),
            sync,
        )
        // Two MOVEs just past touch slop, each handled by the app before the next (about a
        // frame each): a scrolling parent intercepts the gesture on the first, or on the
        // second when the view under the finger keeps it from intercepting until the finger
        // moves (React Native's TextInput does, and gives the gesture back on its first MOVE:
        // issue #6, a form's field at the drag's start). Sent together, MOVEs reach the app as
        // one batched MOVE, which the parent spends on intercepting, so nothing would scroll.
        val dist = hypot(dx, dy)
        val first = if (dist > 0f) minOf(1f, swipeFirstMovePx / dist) else 1f
        val second = if (dist > 0f) minOf(1f, (swipeFirstMovePx + swipeSecondMovePx) / dist) else 1f
        move(first, sync = true)
        if (second > first) move(second, sync = true)
        val steps = maxOf(1, duration / SWIPE_STEP_MS)
        for (i in 1..steps) {
            val f = i.toFloat() / steps
            if (f > second) move(f)
        }
        if (!fling) {
            // A second sample at the end leaves zero motion for touch resampling to
            // extrapolate. A third one, still, over 40 ms later: VelocityTracker takes the
            // pointer as stopped and drops the drag's samples. Lifting SWIPE_HOLD_MS after the
            // drag stops would do it too, but ScrollView (React Native's lists) reads the
            // velocity before adding the UP to its tracker; RecyclerView adds it first.
            injectMotion(touch(down, down + duration + 10, MotionEvent.ACTION_MOVE, x2, y2))
            injectMotion(touch(down, down + duration + SWIPE_HOLD_MS - 5, MotionEvent.ACTION_MOVE, x2, y2))
        }
        Thread.sleep(SWIPE_LIFT_GAP_MS)
        val up = maxOf(SystemClock.uptimeMillis(), down + duration + hold)
        // CANCEL: scroll views fling only on a lift (ScrollView, RecyclerView, Compose and
        // Flutter end a cancelled drag where it is). The still pointer alone did not do it on
        // a starved emulator (CI): a React Native list sometimes flung 100+ rows in one drag.
        val end = if (cancel) MotionEvent.ACTION_CANCEL else MotionEvent.ACTION_UP
        injectMotion(touch(down, up, end, x2, y2))
    }

    private fun press(x: Float, y: Float, holdMs: Int) {
        timedAction {
            val down = touchDown(x, y)
            Thread.sleep(holdMs.coerceIn(0, 60_000).toLong()) // the app's long-press timer runs in real time
            injectMotion(touch(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, x, y))
        }
        writeTouch()
    }

    // 2x the 8 dp touch slop.
    private val swipeFirstMovePx = 16 * Resources.getSystem().displayMetrics.density
    // The second MOVE, past the first: the scroll a gesture held by the view under it loses.
    private val swipeSecondMovePx = 4 * Resources.getSystem().displayMetrics.density

    private fun key(code: Int) = timedAction {
        waitForTransitions()
        pressKey(code)
    }

    private fun pressKey(code: Int) {
        if (code == KeyEvent.KEYCODE_DEL && keysThroughField(code, 1)) return
        val t = SystemClock.uptimeMillis()
        injector.inject(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
        injector.inject(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
    }

    private val keyMap by lazy { KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD) }

    private fun type(text: String, paced: Boolean) {
        var skipped = 0
        val keys = ArrayList<Array<KeyEvent>>()
        for (ch in text) {
            val events = keyMap.getEvents(charArrayOf(ch))
            if (events == null) {
                skipped++
                continue
            }
            for (e in events) e.source = InputDevice.SOURCE_KEYBOARD
            keys += events
        }
        if (Build.VERSION.SDK_INT >= 34) ua.clearCache() // the focus as it is now, not as cached
        val field = inputFocus()
        // Keys go through the keyboard app: it must have been told of the field first.
        var input = 0
        var inputWaitNs = 0L
        var changes = -1 // the field's changes so far (the key service's count), -1 unknown
        if (field != null && skipped == 0 && keys.isNotEmpty()) {
            val t = SystemClock.elapsedRealtimeNanos()
            val result = awaitFieldInput(field)
            inputWaitNs = SystemClock.elapsedRealtimeNanos() - t
            val waited = if (result != null && result.containsKey("waited")) result.getLong("waited") else null
            if (result != null && result.containsKey("changes")) changes = result.getInt("changes")
            input = when {
                waited == null -> 0
                waited < 0 -> 3
                waited > 0 -> 2
                else -> 1
            }
        }
        timedAction {
            waitForTransitions()
            if (skipped > 0 && insertText(text)) {
                skipped = 0
                return@timedAction
            }
            if (paced && changes >= 0) injectPaced(keys, changes) else injectKeys(keys)
        }
        if (input != 0) keyCall("typed", Bundle())
        body.writeInt(skipped)
        body.writeByte(if (field != null) 1 else 0)
        body.writeByte(input)
        body.writeInt((inputWaitNs / 1000).toInt())
    }

    /**
     * The editable field with the input focus: the view system's input focus, else a focused
     * editable node in the active window (where the input-focus lookup finds none, as in a
     * view that draws its own nodes). Null when there is none, or the window went away.
     */
    private fun inputFocus(): AccessibilityNodeInfo? = try {
        val node = ua.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (node != null && node.isEditable) node
        else {
            var found: AccessibilityNodeInfo? = null
            val nodes = ArrayDeque<AccessibilityNodeInfo>()
            stalled = false
            rootOf { ua.rootInActiveWindow }?.let { nodes.addLast(it) }
            while (nodes.isNotEmpty() && found == null && !stalled) {
                val n = nodes.removeLast()
                if (n.isFocused && n.isEditable) found = n
                else for (i in 0 until n.childCount) nodes.addLast(child(n, i) ?: continue)
            }
            found
        }
    } catch (e: Exception) {
        null
    }

    private fun writeFocus() {
        val node = inputFocus()
        body.writeByte(if (node != null) 1 else 0)
        if (node != null) node.getBoundsInScreen(bounds) else bounds.setEmpty()
        body.writeInt(bounds.left)
        body.writeInt(bounds.top)
        body.writeInt(bounds.right)
        body.writeInt(bounds.bottom)
    }

    /**
     * Key events, a group per key press, sent in chunks: each event stamped as it is sent, and
     * the last of a chunk waited for (keys reach the app in order, so all are handled when this
     * returns). The input dispatcher hands an app one key at a time, once it has handled the
     * one before, and drops a key event 10 s past its event time as stale: a text stamped and
     * queued at once lost its end, with no error, whenever the app took longer than that to
     * handle it all (issue #7: a starved emulator, a cold app). A chunk is sized to take
     * [KEY_CHUNK_MS] at the pace of the one before, [KEY_CHUNK_MAX] presses at most. Waiting
     * for every key would make sure of it too, but costs ~12 ms a key on the emulator (52
     * characters: 1.5 s instead of 0.9 s).
     */
    private fun injectKeys(presses: List<Array<KeyEvent>>) {
        var next = 0
        var msPerPress = 0L // unknown: the first chunk is two presses, to measure it
        while (next < presses.size) {
            val n = if (msPerPress == 0L) 2 else (KEY_CHUNK_MS / msPerPress).toInt().coerceIn(1, KEY_CHUNK_MAX)
            val end = minOf(next + n, presses.size)
            val start = SystemClock.uptimeMillis()
            for (k in next until end) {
                val down = SystemClock.uptimeMillis()
                presses[k].forEachIndexed { j, e ->
                    val sent = KeyEvent(down, SystemClock.uptimeMillis(), e.action, e.keyCode, e.repeatCount,
                        e.metaState, e.deviceId, e.scanCode, e.flags, e.source)
                    injector.inject(sent, sync = k == end - 1 && j == presses[k].lastIndex)
                }
            }
            msPerPress = maxOf(1L, (SystemClock.uptimeMillis() - start) / (end - next))
            next = end
        }
    }

    private var keyProvider: Any? = null

    /**
     * Key presses through the focused field's input connection, as a keyboard sends them, by
     * the key service (KeyService.kt): false when no editable field has the input focus, or the
     * service is not up (before Android 13, or not turned on), and the keys are injected
     * instead. A Backspace injected as a hardware key deletes, but React Native's onKeyPress
     * fires only when the keyboard app turns it into an input connection call (Gboard 18 does,
     * Gboard 15 does not); through the connection, it fires whatever the keyboard.
     * The service is asked through its content provider, as `content call` does (hidden API:
     * ActivityManager.getContentProviderExternal, IContentProvider.call).
     */
    private fun keysThroughField(code: Int, count: Int): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        if (Build.VERSION.SDK_INT >= 34) ua.clearCache()
        val field = inputFocus() ?: return false
        val extras = Bundle().apply {
            putInt("code", code)
            putInt("count", count)
            putLong("field", KeyService.fieldOf(field))
            putLong("since", lastTouchDown)
        }
        return keyCall("keys", extras)?.getBoolean("sent") == true
    }

    /**
     * The key service's wait for the system to start input on [field]: waited (milliseconds, 0:
     * it had; -1: it did not start in KeyService.INPUT_WAIT_MS) and the field's changes so far;
     * without them, or null, when the service is not up or cannot tell (Android 13).
     */
    private fun awaitFieldInput(field: AccessibilityNodeInfo): Bundle? {
        if (Build.VERSION.SDK_INT < 33) return null
        return keyCall("input", Bundle().apply {
            putLong("field", KeyService.fieldOf(field))
            putLong("since", lastTouchDown)
        })
    }

    /**
     * Key presses one at a time, each once the one before changed the field (the key service
     * hears of each change as the keyboard app does; [changes]: its count so far). Sent as fast
     * as the app takes them, a keyboard app showing suggestions lost a character now and then:
     * one in a word, never the first, on CI's emulators with a software GPU ("calendar" typed
     * as "calendr", then as "calenda"). A press that changes nothing (the app refused it) is
     * waited for PACE_TIMEOUT_MS; after two in a row, the rest go as injectKeys sends them.
     */
    private fun injectPaced(presses: List<Array<KeyEvent>>, changes: Int) {
        var seen = changes
        var misses = 0
        for ((k, press) in presses.withIndex()) {
            if (misses >= 2) {
                injectKeys(presses.subList(k, presses.size))
                return
            }
            val down = SystemClock.uptimeMillis()
            press.forEachIndexed { j, e ->
                val sent = KeyEvent(down, SystemClock.uptimeMillis(), e.action, e.keyCode, e.repeatCount,
                    e.metaState, e.deviceId, e.scanCode, e.flags, e.source)
                injector.inject(sent, sync = j == press.lastIndex)
            }
            val now = keyCall("change", Bundle().apply {
                putInt("after", seen)
                putLong("timeout", PACE_TIMEOUT_MS)
            })?.getInt("changes")
            if (now == null) {
                injectKeys(presses.subList(k + 1, presses.size))
                return
            }
            if (now > seen) {
                seen = now
                misses = 0
            } else misses++
        }
    }

    /** A call to the key service's provider (KeyProvider), null when it cannot be reached. */
    private fun keyCall(method: String, extras: Bundle): Bundle? {
        if (Build.VERSION.SDK_INT < 33) return null
        repeat(2) { // a second try with the provider looked up again: its process may have restarted
            val provider = keyProvider ?: try {
                val am = Class.forName("android.app.ActivityManager").getMethod("getService").invoke(null)!!
                val holder = am.javaClass.getMethod(
                    "getContentProviderExternal", String::class.java, Int::class.javaPrimitiveType,
                    IBinder::class.java, String::class.java,
                ).invoke(am, KeyProvider.AUTHORITY, 0, Binder(), "speedrun") ?: return null
                holder.javaClass.getField("provider").get(holder)
            } catch (e: Throwable) {
                AgentLog.w("key provider: not found", cause(e))
                return null
            } ?: return null
            keyProvider = provider
            try {
                val source = AttributionSource.Builder(SHELL_UID).setPackageName("com.android.shell").build()
                return provider.javaClass.getMethod(
                    "call", AttributionSource::class.java, String::class.java, String::class.java,
                    String::class.java, Bundle::class.java,
                ).invoke(provider, source, KeyProvider.AUTHORITY, method, null, extras) as Bundle?
            } catch (e: Throwable) {
                AgentLog.w("key provider: call failed", cause(e))
                keyProvider = null
            }
        }
        return null
    }

    /**
     * Text no key events can type: replaces the focused field's selection (the cursor), and
     * the cursor goes after it, as an input method's commitText would. One accessibility
     * action, served on the app's main thread, so the text is in when it returns. False when
     * no editable field has the input focus.
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
        waitForTransitions()
        if (keysThroughField(KeyEvent.KEYCODE_DEL, count.coerceIn(0, 10_000))) return@timedAction
        val del = arrayOf(
            KeyEvent(0, 0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL, 0),
            KeyEvent(0, 0, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL, 0),
        )
        injectKeys(List(count.coerceIn(0, 10_000)) { del })
    }

    // ---- settle -----------------------------------------------------------------------

    private fun launched(pkg: String, timeoutMs: Int): Boolean {
        val end = SystemClock.uptimeMillis() + timeoutMs.coerceIn(0, 60_000)
        while (true) {
            val windows = try { ua.windows } catch (e: Exception) { emptyList() }
            // The root is read from the app: null while it starts, before it can answer.
            if (windows.any { w -> try { w.root?.packageName?.toString() == pkg } catch (e: Exception) { false } }) return true
            if (SystemClock.uptimeMillis() >= end) return false
            Thread.sleep(20)
        }
    }

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
            val root = ua.rootInActiveWindow
            root?.refresh() // refresh() bypasses the client-side node cache
            frontPackage = root?.packageName?.toString()
        } catch (e: Exception) {
            // Window went away mid-probe: treat as busy.
            return Long.MAX_VALUE / 1000
        }
        return (SystemClock.elapsedRealtimeNanos() - t) / 1000
    }

    /**
     * The active window's tree as SETTLE reads it while something keeps changing: a signature
     * of its visible nodes (what each is, where, what it says), restless nodes' frames and texts
     * left out (RESTLESS_NS), as the iOS agent's Screen.digest. Nodes are told apart by kind,
     * id and depth, and by their order when alike, so a counter whose text changes stays one
     * node. The reads go through UiAutomation's node cache, which accessibility events refresh:
     * a change the app reports is seen.
     */
    private inner class Restless {
        private val rect = Rect()
        private var lastState = HashMap<Long, Long>()
        private var movingSince = HashMap<Long, Long>()
        private var movedAt = HashMap<Long, Long>()
        private var lastSignature: Long? = null
        private val ids = ArrayList<Long>(256)
        private val states = ArrayList<Long>(256)

        fun reset() {
            lastState.clear()
            movingSince.clear()
            movedAt.clear()
            lastSignature = null
        }

        /** Reads the tree: whether its signature is the previous read's. */
        fun steady(now: Long): Boolean {
            freshNodes()
            val root = ua.rootInActiveWindow
            if (root == null) {
                lastSignature = null
                return false
            }
            ids.clear()
            states.clear()
            val alike = HashMap<Long, Int>()
            val nodes = ArrayDeque<AccessibilityNodeInfo>()
            val depths = ArrayDeque<Int>()
            nodes.addLast(root)
            depths.addLast(0)
            stalled = false
            while (nodes.isNotEmpty() && !stalled) {
                val n = nodes.removeLast()
                val depth = depths.removeLast()
                var id = (n.className?.toString()?.hashCode() ?: 0).toLong()
                id = id * 31 + (n.viewIdResourceName?.hashCode() ?: 0)
                id = id * 31 + depth
                val k = alike.getOrDefault(id, 0)
                alike[id] = k + 1
                if (k > 0) id = id * -7046029254386353131L + k
                n.getBoundsInScreen(rect)
                var st = rect.left.toLong()
                st = st * 31 + rect.top
                st = st * 31 + rect.right
                st = st * 31 + rect.bottom
                st = st * 31 + (n.text?.toString()?.hashCode() ?: 0)
                st = st * 31 + (n.contentDescription?.toString()?.hashCode() ?: 0)
                st = st * 31 + (if (n.isChecked) 1 else 0) + (if (n.isSelected) 2 else 0)
                ids.add(id)
                states.add(st)
                for (i in n.childCount - 1 downTo 0) {
                    val c = child(n, i) ?: continue
                    if (!c.isVisibleToUser) continue
                    nodes.addLast(c)
                    depths.addLast(depth + 1)
                }
            }
            val state = HashMap<Long, Long>(ids.size * 2)
            val moving = HashMap<Long, Long>()
            val moved = HashMap<Long, Long>()
            for (k in ids.indices) {
                val id = ids[k]
                state[id] = states[k]
                val was = lastState[id]
                if (was != null && was != states[k]) {
                    moving[id] = movingSince[id] ?: now
                    moved[id] = now
                } else {
                    val since = movingSince[id]
                    val at = movedAt[id]
                    if (since != null && at != null && now - at < RESTLESS_PAUSE_NS) { // paused: still moving
                        moving[id] = since
                        moved[id] = at
                    }
                }
            }
            lastState = state
            movingSince = moving
            movedAt = moved
            val few = moving.size * 3 <= ids.size
            var sig = ids.size.toLong()
            for (k in ids.indices) {
                sig = sig * 31 + ids[k]
                val since = moving[ids[k]]
                if (!(few && since != null && now - since >= RESTLESS_NS)) sig = sig * 31 + states[k]
            }
            val same = sig == lastSignature
            lastSignature = sig
            return same
        }
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
        var method = 0

        val restless = Restless()
        var restlessFrom = start    // changes since: the action, or the last window switch
        var nextTreeRead = 0L
        var steadyReads = 0         // tree reads in a row that agreed with the one before
        var jsFrom = 0L             // when a busy JavaScript thread first held this settle off
        var jsLast = 0L             // and last did
        val jsStart = js.runtime()  // the JavaScript threads' CPU time so far (-1: none known)

        fun poll(): Boolean { // returns true if something changed
            val w = activeWindowId()
            if (w != window) {
                window = w
                seen = Long.MIN_VALUE
                lastWasEvent = false
                switched = true
                restlessFrom = SystemClock.elapsedRealtimeNanos()
                restless.reset()
                steadyReads = 0
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

        fun jsBusy(now: Long): Boolean {
            if (jsFrom != 0L && now - jsFrom >= JS_WAIT_MAX_NS) return false
            js.follow(frontPackage, now)
            if (!js.busy(now)) { js.pegged = false; return false }
            if (js.pegged) return false
            if (jsFrom == 0L) jsFrom = now
            else if (now - jsFrom >= JS_WAIT_MAX_NS) { js.pegged = true; return false }
            jsLast = now
            return true
        }

        while (true) {
            now = SystemClock.elapsedRealtimeNanos()
            if (poll()) { changed = true; last = now }
            js.sample(now)

            val quietReached = changed && now - last >= if (lastWasEvent && !switched) eventQuiet else quiet
            val noChangeReached = !changed && now - start >= noChange
            if (quietReached || noChangeReached) {
                if (jsFrom != 0L && jsBusy(now)) {
                    // JavaScript still busy (no need to probe again): wait for it, then a quiet.
                    if (changed) last = now
                } else {
                    val p = probeMainThread()
                    probes++
                    probeMaxUs = maxOf(probeMaxUs, p)
                    now = SystemClock.elapsedRealtimeNanos()
                    val busy = p > busyUs
                    if (poll() || busy) {
                        // App was working or drew during the probe: not settled, keep watching.
                        changed = true
                        last = now
                    } else if (jsBusy(now)) {
                        // The UI holds still, but React Native's JavaScript is still at work: the
                        // screen the tree shows may not take touches yet (see JsThread).
                        if (changed) last = now
                    } else {
                        status = if (changed) 0 else 1
                        break
                    }
                }
            } else if (changed && now - restlessFrom >= RESTLESS_START_NS && now >= nextTreeRead) {
                // Still changing: maybe an animation that never ends (see Settle).
                steadyReads = if (restless.steady(now)) steadyReads + 1 else 0
                nextTreeRead = SystemClock.elapsedRealtimeNanos() + RESTLESS_READ_NS
                if (steadyReads >= 2) {
                    val p = probeMainThread()
                    probes++
                    probeMaxUs = maxOf(probeMaxUs, p)
                    now = SystemClock.elapsedRealtimeNanos()
                    if (p <= busyUs && activeWindowId() == window && !jsBusy(now)) {
                        status = 0
                        method = 3
                        last = now
                        break
                    }
                    steadyReads = 0
                }
            }
            if (now - start >= timeout) { status = 2; break }
            Thread.sleep(5)
        }

        body.writeByte(status)
        body.writeInt(if (changed) ((last - start) / 1000).toInt() else 0)
        body.writeInt(((now - start) / 1000).toInt())
        body.writeByte(method)
        body.writeInt(frames)
        body.writeInt(probes)
        body.writeInt(minOf(probeMaxUs, Int.MAX_VALUE.toLong()).toInt())
        body.writeInt(events)
        body.writeInt(if (jsFrom != 0L) ((jsLast - jsFrom) / 1000).toInt() else 0)
        val jsEnd = js.runtime()
        body.writeInt(if (jsStart >= 0 && jsEnd >= jsStart) ((jsEnd - jsStart) / 1000).toInt() else 0)
    }

    /** Fallback: Android coalesces content-change events (~100 ms), hence the larger window. */
    private fun settleEvents(quietMs: Int, noChangeMs: Int, timeoutMs: Int) {
        val start = lastAction
        val quiet = quietMs * 1_000_000L
        val noChange = noChangeMs * 1_000_000L
        val timeout = timeoutMs * 1_000_000L
        var status = 2
        var now = start
        var method = 1
        val restless = Restless()
        var nextTreeRead = 0L
        var steadyReads = 0
        while (true) {
            now = SystemClock.elapsedRealtimeNanos()
            val last = lastChange.get()
            if (last > start) {
                if (now - last >= quiet) { status = 0; break }
                if (now - start >= RESTLESS_START_NS && now >= nextTreeRead) {
                    // Still changing: maybe an animation that never ends (see Settle).
                    steadyReads = if (restless.steady(now)) steadyReads + 1 else 0
                    nextTreeRead = SystemClock.elapsedRealtimeNanos() + RESTLESS_READ_NS
                    if (steadyReads >= 2) {
                        if (probeMainThread() <= 10_000L) { // an idle main thread answers in ~1 ms
                            now = SystemClock.elapsedRealtimeNanos()
                            status = 0
                            method = 3
                            break
                        }
                        steadyReads = 0
                    }
                }
            } else if (now - start >= noChange) {
                status = 1; break
            }
            if (now - start >= timeout) { status = 2; break }
            Thread.sleep(1)
        }
        val last = if (method == 3) now else lastChange.get()
        body.writeByte(status)
        body.writeInt(if (last > start) ((last - start) / 1000).toInt() else 0)
        body.writeInt(((now - start) / 1000).toInt())
        body.writeByte(method)
        body.writeInt(0)
        body.writeInt(0)
        body.writeInt(0)
        body.writeInt(0)
        body.writeInt(0)
        body.writeInt(0)
    }
}
