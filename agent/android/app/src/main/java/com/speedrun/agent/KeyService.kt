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
    // The field the system last started input on ([fieldOf] its node), or one of FIELD_*, when,
    // and how many starts and finishes there were. Guarded by [lock], notified when they change.
    private val lock = Object()
    private var started = FIELD_NONE
    private var startedAt = 0L
    private var starts = 0
    // The field speedrun is typing into ([typing]): input that starts again meanwhile is on it.
    // A field whose app changes what is typed (a length limit, upper case) restarts the
    // keyboard's input on each key: a look-up each, into the app, slowed typing in an app with
    // a large tree to ~0.8 s a key.
    private var typingInto = FIELD_NONE
    // Changes the system told of in the field with input: its selection moved (as a key went
    // in), or its input started again. Guarded by [lock].
    private var changes = 0
    // The keyboard app's word in progress (its composing text) in the field, as the system told
    // of it with the last change: start and end, -1 with none. Guarded by [lock].
    private var composingStart = -1
    private var composingEnd = -1
    private val lookups = Executors.newSingleThreadExecutor()

    // Input starts on a field when it takes the focus: the system tells the keyboard app and
    // this service together (the field's editor info, a connection to it). Which field it was
    // is looked up right away, off the main thread: the field holding the input focus then.
    override fun onCreateInputMethod(): InputMethod = object : InputMethod(this) {
        override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
            super.onStartInput(attribute, restarting)
            // A window that takes the focus with no text field in it starts an empty editor.
            val editor = attribute.inputType != InputType.TYPE_NULL
            var lookUp = 0
            synchronized(lock) {
                starts++
                changes++
                startedAt = SystemClock.uptimeMillis()
                composingStart = -1
                composingEnd = -1
                started = when {
                    !editor -> FIELD_NONE
                    typingInto != FIELD_NONE -> typingInto
                    else -> FIELD_LOOKING
                }
                if (started == FIELD_LOOKING) lookUp = starts
                lock.notifyAll()
            }
            if (lookUp != 0) lookups.execute { publish(lookUp, focusedField()) }
        }

        override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
            super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
            synchronized(lock) {
                changes++
                composingStart = candidatesStart
                composingEnd = candidatesEnd
                lock.notifyAll()
            }
        }

        override fun onFinishInput() {
            super.onFinishInput()
            synchronized(lock) {
                started = FIELD_NONE
                typingInto = FIELD_NONE
                starts++
                composingStart = -1
                composingEnd = -1
                lock.notifyAll()
            }
        }
    }

    // [field] as input start [n]'s, unless another start or a finish came since.
    private fun publish(n: Int, field: Long) = synchronized(lock) {
        if (starts == n) {
            started = field
            lock.notifyAll()
        }
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
     * found as input started) is taken as the one. Compose reports the focus a frame or more
     * after it starts input, so the field found then can be the one before (the lab's code
     * field was found as the password field): input that started on another field after
     * [since] (speedrun's last touch, uptime) is looked at again, every [LOOK_AGAIN_MS].
     */
    fun awaitInput(field: Long, since: Long, timeoutMs: Long): Long {
        val start = SystemClock.uptimeMillis()
        var lookedAt = 0L
        while (true) {
            var lookAgain = 0
            synchronized(lock) {
                val now = SystemClock.uptimeMillis()
                if (started == field || started == FIELD_UNKNOWN) return now - start
                if (now - start >= timeoutMs) return -1
                val another = started != FIELD_NONE && started != FIELD_LOOKING && startedAt >= since
                if (another && now - lookedAt >= LOOK_AGAIN_MS) lookAgain = starts
                else lock.wait(minOf(timeoutMs - (now - start), LOOK_AGAIN_MS))
            }
            if (lookAgain != 0) {
                lookedAt = SystemClock.uptimeMillis()
                publish(lookAgain, focusedField())
            }
        }
    }

    /**
     * The count of changes in the field with input once it is past [after] ([timeoutMs] at
     * most): typed keys go one at a time, each once the one before has changed the field. The
     * system tells the keyboard app of a change as it tells this service: a key the keyboard
     * app got before then met a keyboard behind the field, which lost it now and then (one
     * character in a word, on an emulator with a software GPU, the keyboard's suggestions on).
     */
    fun awaitChange(after: Int, timeoutMs: Long): Int {
        val end = SystemClock.uptimeMillis() + timeoutMs
        synchronized(lock) {
            while (changes <= after) {
                val left = end - SystemClock.uptimeMillis()
                if (left <= 0) break
                lock.wait(left)
            }
            return changes
        }
    }

    fun changes(): Int = synchronized(lock) { changes }

    /**
     * The text of the field with input, through its connection (the app answers it on its main
     * thread), with its selection and [changes] count: what typing is checked against. Without
     * them, why: no connection ("connection"), the app does not answer ("answer"), or the field
     * holds [TEXT_MAX] characters or more on either side of the cursor ("long").
     */
    fun fieldText(): Bundle {
        if (Build.VERSION.SDK_INT < 33) return Bundle()
        val count = changes()
        val ic = inputMethod?.currentInputConnection ?: return why("connection")
        val st = ic.getSurroundingText(TEXT_MAX, TEXT_MAX, 0) ?: return why("answer")
        // The whole text: less than asked for on both sides. Its offset in the field is 0, or
        // -1 (unknown) where the app answers with InputConnection's own (Compose).
        if (st.offset > 0 || st.selectionStart >= TEXT_MAX || st.text.length - st.selectionEnd >= TEXT_MAX) return why("long")
        return Bundle().apply {
            putString("text", st.text.toString())
            putInt("start", st.selectionStart)
            putInt("end", st.selectionEnd)
            putInt("changes", count)
            putLong("started", synchronized(lock) { startedAt })
        }
    }

    private fun why(reason: String) = Bundle().apply { putString("why", reason) }

    /**
     * The keyboard app's word in progress, committed as it is: an edit through this service's
     * connection while the keyboard app is composing a word goes behind its back, and it can put
     * its word back as it had it. Committed, the system tells it its word is done. (Letters out
     * of place in a team's fields after an erase were taken for that; they were the old text's
     * end, left after the cursor: toEnd.) The connection has no finishComposingText: its
     * commitText replaces the composing text.
     */
    private fun finishComposing(ic: InputMethod.AccessibilityInputConnection) {
        val (start, end) = synchronized(lock) { composingStart to composingEnd }
        if (start < 0 || end <= start) return
        val st = ic.getSurroundingText(TEXT_MAX, TEXT_MAX, 0) ?: return
        val offset = maxOf(st.offset, 0)
        val from = start - offset
        val to = end - offset
        if (from < 0 || to > st.text.length) return
        ic.commitText(st.text.subSequence(from, to), 1, null)
    }

    /**
     * [text] in place of the field's characters [start] to [end], the cursor after it, through
     * the field's connection: what typing missed put in at once, with no keys for the keyboard
     * app to lose again. False without a connection.
     */
    fun replace(start: Int, end: Int, text: String): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        val ic = inputMethod?.currentInputConnection ?: return false
        finishComposing(ic)
        ic.setSelection(start, end)
        ic.commitText(text, 1, null)
        ic.getSurroundingText(0, 0, 0) // answered once the app has handled the calls before it
        return true
    }

    /** speedrun types into [field] until [typed]. */
    fun typing(field: Long) = synchronized(lock) { typingInto = field }

    fun typed() = synchronized(lock) { typingInto = FIELD_NONE }

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
    fun send(code: Int, count: Int, field: Long?, since: Long, whole: Boolean = false): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        if (field != null && Build.VERSION.SDK_INT >= 34) {
            if (awaitInput(field, since, INPUT_WAIT_MS) < 0) {
                AgentLog.i("key service: no input started on the focused field in $INPUT_WAIT_MS ms")
            }
            typing(field)
        }
        try {
            return sendKeys(code, count, whole)
        } finally {
            typed()
        }
    }

    private fun sendKeys(code: Int, count: Int, whole: Boolean): Boolean {
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
        finishComposing(ic!!)
        if (whole) toEnd(ic!!, count)
        repeat(count) {
            // A field the app changes on each key restarts input, and with it the connection.
            ic = inputMethod?.currentInputConnection ?: ic
            val t = SystemClock.uptimeMillis()
            ic!!.sendKeyEvent(KeyEvent(t, t, KeyEvent.ACTION_DOWN, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, FLAGS))
            ic!!.sendKeyEvent(KeyEvent(t, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, FLAGS))
        }
        (inputMethod?.currentInputConnection ?: ic)!!.getSurroundingText(0, 0, 0)
        return true
    }

    /**
     * The cursor at the end of the field's text when it holds no more than [count] characters:
     * eraseText erases all of it, wherever the cursor is. A tap puts the cursor where it lands,
     * inside a text longer than half the field, and deletes from there left the text after it,
     * the next text typed in front of it (Compose Bench: a tap at
     * the center of a field holding "abcdefghijklmnopqrstuvwxyz", eraseText: 40, then
     * "new@example.com" typed, read "new@example.compqrstuvwxyz"). On the same connection as
     * the keys, after the keyboard app's word is committed: the field takes them in order.
     */
    private fun toEnd(ic: InputMethod.AccessibilityInputConnection, count: Int) {
        val st = ic.getSurroundingText(TEXT_MAX, TEXT_MAX, 0) ?: return
        if (st.offset > 0 || st.selectionStart >= TEXT_MAX || st.text.length - st.selectionEnd >= TEXT_MAX) return
        val n = st.text.length
        if (n == 0 || n > count || (st.selectionStart == n && st.selectionEnd == n)) return
        ic.setSelection(n, n)
        AgentLog.i("key service: the cursor at the end of the field's $n characters, to erase them all")
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
        private const val LOOK_AGAIN_MS = 50L
        private const val FLAGS = KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
        private const val CONNECTION_WAIT_MS = 1000L
        private const val ASK_AGAIN_MS = 200L
        private const val TEXT_MAX = 10_000
    }
}

/**
 * The shell agent's way to [KeyService]: `call("keys", null, {code, count, field?, since,
 * whole?})` -> {sent} (whole: eraseText's, the cursor first at the end of what it erases all of); `call("input", null, {field, since})` -> {waited, changes} (milliseconds, -1: input
 * did not start on the field; absent: the service is not up, or Android 13), then keys typed
 * into the field until `call("typed")`, each followed by `call("change", null, {after,
 * timeout})` -> {changes}; `call("text")` -> {text, start, end, changes, started}
 * (KeyService.fieldText; without them {why}, "service" when the service is not up); `call("replace", null, {start, end, text})` -> {done}
 * (KeyService.replace); `call("up")` -> {up}. A call is a binder transaction, which SELinux lets the
 * shell user make into an app (as `content call` does); a local socket it does not. Only the
 * shell user and root may call.
 */
class KeyProvider : ContentProvider() {
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val uid = Binder.getCallingUid()
        if (uid != SHELL_UID && uid != 0) throw SecurityException("speedrun's agent only")
        if (extras == null) return null
        val service = KeyService.instance ?: firstWait()
        val field = if (extras.containsKey("field")) extras.getLong("field") else null
        val since = extras.getLong("since")
        return when (method) {
            "keys" -> {
                val sent = try {
                    service != null && service.send(extras.getInt("code"), extras.getInt("count").coerceIn(0, 10_000), field, since,
                        extras.getBoolean("whole"))
                } catch (e: Exception) {
                    AgentLog.w("key service: send failed", e)
                    false
                }
                Bundle().apply { putBoolean("sent", sent) }
            }
            "input" -> Bundle().apply { // Android 13 cannot tell the field (focusedField)
                if (service != null && field != null && Build.VERSION.SDK_INT >= 34) {
                    putLong("waited", service.awaitInput(field, since, KeyService.INPUT_WAIT_MS))
                    service.typing(field)
                    putInt("changes", service.changes())
                }
            }
            "change" -> Bundle().apply {
                if (service != null) putInt("changes", service.awaitChange(extras.getInt("after"), extras.getLong("timeout")))
            }
            "typed" -> Bundle().apply { service?.typed() }
            "replace" -> Bundle().apply {
                val done = try {
                    service != null && service.replace(extras.getInt("start"), extras.getInt("end"), extras.getString("text") ?: "")
                } catch (e: Exception) {
                    AgentLog.w("key service: the field's text could not be replaced", e)
                    false
                }
                putBoolean("done", done)
            }
            "text" -> try {
                service?.fieldText() ?: Bundle().apply { putString("why", "service") }
            } catch (e: Exception) {
                AgentLog.w("key service: the field's text could not be read", e)
                Bundle()
            }
            "up" -> Bundle().apply { putBoolean("up", service != null) }
            else -> null
        }
    }

    // The service turned on as the run starts is bound a moment later, seconds on a slow
    // emulator: the first call waits for it, SERVICE_WAIT_MS at most; later ones do not.
    @Volatile private var waited = false

    private fun firstWait(): KeyService? {
        if (waited) return null
        waited = true
        val end = SystemClock.uptimeMillis() + SERVICE_WAIT_MS
        while (SystemClock.uptimeMillis() < end) {
            Thread.sleep(20)
            KeyService.instance?.let { return it }
        }
        AgentLog.w("key service: not up after $SERVICE_WAIT_MS ms")
        return null
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
        private const val SERVICE_WAIT_MS = 2000L
    }
}
