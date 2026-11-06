package com.speedrun.agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.InputMethod
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.EditorInfo
import java.util.concurrent.Executors

/**
 * Keys sent as a keyboard sends them (Android 13+): an accessibility service that asks for the
 * input method APIs, so a key press goes through the focused field's input connection, as a
 * soft keyboard's does, rather than in as a hardware key. A hardware Backspace deletes, but
 * React Native's onKeyPress only hears the input connection: it fired only when the keyboard
 * app turned the key into an input connection call (Gboard 18 does, Gboard 15 does not).
 * UiAutomation gets no input connection: the system hands one only to bound services that
 * ask for it. speedrun installs the agent's APK and turns the service on for a run, and back
 * off after; the shell agent asks it through [KeyProvider].
 * The service also hears when input starts on a field, as the keyboard app does: typed keys
 * wait for it ([awaitInput]).
 */
class KeyService : AccessibilityService() {
    // The field the system last started input on ([fieldOf] its node), or one of FIELD_*.
    // Guarded by [lock], which is notified when it changes.
    private val lock = Object()
    private var started = FIELD_NONE
    private var starts = 0
    private var previous = FIELD_NONE // the field input last started on
    private val lookups = Executors.newSingleThreadExecutor()

    // Input starts on a field when it takes the focus: the system tells the keyboard app and
    // this service together (the field's editor info, a connection to it). Which field it was
    // is looked up right away, off the main thread: the field holding the input focus then.
    override fun onCreateInputMethod(): InputMethod = object : InputMethod(this) {
        override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
            super.onStartInput(attribute, restarting)
            // A window that takes the focus with no text field in it starts an empty editor.
            val editor = attribute.inputType != InputType.TYPE_NULL
            val n = synchronized(lock) {
                started = if (editor) FIELD_LOOKING else FIELD_NONE
                lock.notifyAll()
                ++starts
            }
            if (editor) lookups.execute { lookUp(n) }
        }

        override fun onFinishInput() {
            super.onFinishInput()
            synchronized(lock) {
                started = FIELD_NONE
                starts++
                lock.notifyAll()
            }
        }
    }

    // The field input start [n] is on. Compose reports the focus a frame or more after it
    // starts input: the field found can still be the one before, or none (the code field of
    // the lab's form was found as the password field before it). Looked up again until it is
    // another, [LOOK_UP_MS] at most, each find given out as it comes.
    private fun lookUp(n: Int) {
        val before = synchronized(lock) { previous }
        val end = SystemClock.uptimeMillis() + LOOK_UP_MS
        var field = focusedField()
        if (!publish(n, field)) return
        while ((field == before || field == FIELD_UNKNOWN) && SystemClock.uptimeMillis() < end) {
            Thread.sleep(LOOK_UP_EVERY_MS)
            val again = focusedField()
            if (again == field) continue
            field = again
            if (!publish(n, field)) return
        }
        AgentLog.i("key service: input started on ${java.lang.Long.toHexString(field)}")
    }

    // [field] as input start [n]'s, unless another start or a finish came since.
    private fun publish(n: Int, field: Long): Boolean = synchronized(lock) {
        if (starts != n) return false
        started = field
        if (field != FIELD_UNKNOWN) previous = field
        lock.notifyAll()
        true
    }

    private fun focusedField(): Long {
        // The node cache's input focus can be the field before (the app's focus events come
        // when they come): emptied first. Android 13 cannot empty it, and does not wait.
        if (Build.VERSION.SDK_INT < 34) return FIELD_UNKNOWN
        try { clearCache() } catch (e: Exception) { }
        val node = try { findFocus(AccessibilityNodeInfo.FOCUS_INPUT) } catch (e: Exception) { null }
        return if (node != null && node.isEditable) fieldOf(node) else FIELD_UNKNOWN
    }

    /**
     * Waits until the system has started input on [field] ([fieldOf] its node), [timeoutMs] at
     * most: until then, the keyboard app has not been told of the field, and keys typed into it
     * meet a keyboard that still takes the field as it was (on a slow emulator, the second
     * character of "sneaker" went in before the first: "nseaker"). Returns the milliseconds
     * waited, or -1 when it did not start. A field this service cannot tell (no input focus
     * found as input started) is taken as the one.
     */
    fun awaitInput(field: Long, timeoutMs: Long): Long {
        val start = SystemClock.uptimeMillis()
        synchronized(lock) {
            while (true) {
                val waited = SystemClock.uptimeMillis() - start
                if (started == field || started == FIELD_UNKNOWN) return waited
                if (waited >= timeoutMs) return -1
                lock.wait(timeoutMs - waited)
            }
        }
    }

    override fun onServiceConnected() {
        instance = this
    }

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        if (instance === this) instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    // A DOWN and an UP a press, flagged as a soft keyboard's (as Android's own keyboard sends
    // them), then a read the app answers once it has handled them: an input connection serves
    // its calls in order, so they are all in when this returns. The system hands the service a
    // field's connection a moment after the field takes the focus: input on [field] is waited
    // for (the connection held until then is the field before's), then the connection, up to
    // [CONNECTION_WAIT_MS], asked for again after [ASK_AGAIN_MS]. False with none.
    fun send(code: Int, count: Int, field: Long?): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        if (field != null && awaitInput(field, INPUT_WAIT_MS) < 0) {
            AgentLog.i("key service: no input started on the focused field in $INPUT_WAIT_MS ms")
        }
        val start = SystemClock.uptimeMillis()
        var ic = inputMethod?.currentInputConnection
        var asked = false
        while (ic == null && SystemClock.uptimeMillis() - start < CONNECTION_WAIT_MS) {
            if (!asked && SystemClock.uptimeMillis() - start >= ASK_AGAIN_MS) {
                asked = true
                askForInput()
            }
            Thread.sleep(10)
            ic = inputMethod?.currentInputConnection
        }
        if (ic == null) return false
        repeat(count) {
            val t = SystemClock.uptimeMillis()
            ic.sendKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, FLAGS))
            ic.sendKeyEvent(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, FLAGS))
        }
        ic.getSurroundingText(0, 0, 0)
        return true
    }

    // The input method APIs asked for again (the flag off, then on): the system then binds the
    // service to the input under way. Bound at the wrong moment, it can miss every input of a
    // run: no onStartInput, no connection.
    private fun askForInput() {
        val info = serviceInfo ?: return
        info.flags = info.flags and AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR.inv()
        serviceInfo = info
        info.flags = info.flags or AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR
        serviceInfo = info
        AgentLog.i("key service: no input connection, asked for it again")
    }

    companion object {
        @Volatile var instance: KeyService? = null

        /** A node's identity, the same from any accessibility client: its window and its id. */
        fun fieldOf(node: AccessibilityNodeInfo): Long =
            (node.windowId.toLong() shl 32) or (node.hashCode().toLong() and 0xffffffffL)

        private const val FIELD_NONE = Long.MIN_VALUE // no field's input started (or it finished)
        private const val FIELD_UNKNOWN = Long.MIN_VALUE + 1 // started, its field not found
        private const val FIELD_LOOKING = Long.MIN_VALUE + 2 // started, its field being looked up
        const val INPUT_WAIT_MS = 1000L
        private const val LOOK_UP_MS = 300L
        private const val LOOK_UP_EVERY_MS = 16L
        private const val FLAGS = KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
        private const val CONNECTION_WAIT_MS = 1000L
        private const val ASK_AGAIN_MS = 200L
    }
}

/**
 * The shell agent's way to [KeyService]: `call("keys", null, {code, count, field?})` -> {sent},
 * and `call("input", null, {field})` -> {waited} (milliseconds, -1: input did not start on the
 * field; absent: the service is not up, or Android 13). A call is a binder transaction, which SELinux lets the
 * shell user make into an app (as `content call` does); a local socket it does not. Only the
 * shell user and root may call.
 */
class KeyProvider : ContentProvider() {
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val uid = Binder.getCallingUid()
        if (uid != SHELL_UID && uid != 0) throw SecurityException("speedrun's agent only")
        if (extras == null) return null
        val service = KeyService.instance
        val field = if (extras.containsKey("field")) extras.getLong("field") else null
        return when (method) {
            "keys" -> {
                val sent = try {
                    service != null && service.send(extras.getInt("code"), extras.getInt("count").coerceIn(0, 10_000), field)
                } catch (e: Exception) {
                    AgentLog.w("key service: send failed", e)
                    false
                }
                Bundle().apply { putBoolean("sent", sent) }
            }
            "input" -> Bundle().apply { // Android 13 cannot tell the field (focusedField)
                if (service != null && field != null && Build.VERSION.SDK_INT >= 34) {
                    putLong("waited", service.awaitInput(field, KeyService.INPUT_WAIT_MS))
                }
            }
            else -> null
        }
    }

    override fun onCreate() = true
    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0

    companion object {
        const val AUTHORITY = "com.speedrun.agent.keys"
        private const val SHELL_UID = 2000
    }
}
