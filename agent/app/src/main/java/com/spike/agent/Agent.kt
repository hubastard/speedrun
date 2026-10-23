package com.spike.agent

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.graphics.Rect
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
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
import java.util.concurrent.atomic.AtomicLong

internal const val TAG = "SpikeAgent"

/**
 * Logcat, tag SpikeAgent. The shell entry point also echoes to stdout: that is what
 * `adb shell` shows, and run.sh watches it to know when the agent is up.
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
 *   request  = u8 op, then op-specific fixed fields
 *   response = u32 length, u32 agent_us, body[length - 4]
 *
 *   1 PING                                   -> (empty)
 *   2 TREE                                   -> u32 count, count * node
 *        node = u16 depth, i32 l, i32 t, i32 r, i32 b, u8 flags,
 *               str text, str desc, str id, str class   (str = u16 len + utf8)
 *   3 TAP    i32 x, i32 y                    -> u32 prep_us, u32 inject_us, u8 inject_path
 *   4 KEY    i32 keycode                     -> u32 prep_us, u32 inject_us, u8 inject_path
 *        prep = active-window lookup + frame-stats clear; inject_path = see InjectPath
 *        (formerly fast_inject: 0 and 1 keep their meaning, 2 = shell-uid InputManager).
 *   5 SETTLE i32 quiet_ms, i32 no_change_ms, i32 timeout_ms
 *                                            -> u8 status, u32 ui_done_us, u32 waited_us,
 *                                               u8 method, u32 frames, u32 probes, u32 probe_max_us
 *        status: 0 = UI changed then went quiet, 1 = nothing changed, 2 = timeout
 *        method: 0 = window frame stats, 1 = accessibility-event fallback
 *        times are measured from the moment the last TAP/KEY was injected.
 *
 * Settle (frame method): the UI is settled when
 *   1. the active window id is stable,
 *   2. that window has presented no new frame for quiet_ms, and
 *   3. an accessibility round trip to the app (served on its main thread) returns fast,
 *      which means the main thread is idle and not about to produce more frames.
 */
private object Op {
    const val PING = 1
    const val TREE = 2
    const val TAP = 3
    const val KEY = 4
    const val SETTLE = 5
}

/**
 * Shared by both entry points: AgentInstrumentation (UiAutomation from the instrumentation,
 * UiAutomation injection) and ShellMain (UiAutomation built in a shell-uid process,
 * InputManager injection).
 */
class Agent(private val ua: UiAutomation, private val injector: Injector) {
    // elapsedRealtimeNanos of the most recent UI-change accessibility event.
    private val lastChange = AtomicLong(0L)
    // elapsedRealtimeNanos of the most recent injected action.
    @Volatile private var lastAction = 0L
    // Active window when the last action was injected (its frame stats are cleared then).
    private var actionWindow = -1

    private val bodyBuf = ByteArrayOutputStream(256 * 1024)
    private val body = DataOutputStream(bodyBuf)
    private val treeBuf = ByteArrayOutputStream(256 * 1024)
    private val tree = DataOutputStream(treeBuf)
    private val bounds = Rect()

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
                AccessibilityEvent.TYPE_VIEW_SCROLLED ->
                    lastChange.set(SystemClock.elapsedRealtimeNanos())
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
            else -> throw IOException("unknown op $op")
        }
        body.flush()
        val agentUs = ((SystemClock.elapsedRealtimeNanos() - t0) / 1000).toInt()
        out.writeInt(4 + bodyBuf.size())
        out.writeInt(agentUs)
        bodyBuf.writeTo(out)
    }

    // ---- tree -------------------------------------------------------------------------

    private fun writeTree() {
        var root: AccessibilityNodeInfo? = null
        for (i in 0 until 20) {
            root = ua.rootInActiveWindow
            if (root != null) break
            Thread.sleep(5)
        }
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
            tree.writeByte(f)
            str(n.text)
            str(n.contentDescription)
            str(n.viewIdResourceName)
            str(n.className)
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

    private fun injectMotion(e: MotionEvent) {
        e.source = InputDevice.SOURCE_TOUCHSCREEN
        injector.inject(e)
        e.recycle()
    }

    private fun key(code: Int) = timedAction {
        val t = SystemClock.uptimeMillis()
        injector.inject(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0))
        injector.inject(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0))
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
        else settleEvents(maxOf(quietMs, 120), noChangeMs, timeoutMs)
    }

    private fun settleFrames(quietMs: Int, noChangeMs: Int, timeoutMs: Int) {
        val start = lastAction
        val quiet = quietMs * 1_000_000L
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

        var eventsSeen = start      // for windows whose frame stats are unavailable

        fun poll(): Boolean { // returns true if something changed
            val w = activeWindowId()
            if (w != window) {
                window = w
                seen = Long.MIN_VALUE
                if (w >= 0) try { ua.clearWindowContentFrameStats(w) } catch (e: Exception) { }
                return true
            }
            if (w < 0) return false
            val f = latestFrame(w)
            if (f == null) {
                // No frame stats for this window: use accessibility events as the change signal.
                val ev = lastChange.get()
                if (ev > eventsSeen) { eventsSeen = ev; return true }
                return false
            }
            if (f > seen) {
                seen = f
                frames++
                return true
            }
            return false
        }

        while (true) {
            now = SystemClock.elapsedRealtimeNanos()
            if (poll()) { changed = true; last = now }

            val quietReached = changed && now - last >= quiet
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
    }
}
