package com.speedrun.agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent

/**
 * Keys sent as a keyboard sends them (Android 13+): an accessibility service that asks for the
 * input method APIs, so a key press goes through the focused field's input connection, as a
 * soft keyboard's does, rather than in as a hardware key. A hardware Backspace deletes, but
 * React Native's onKeyPress only hears the input connection: it fired only when the keyboard
 * app turned the key into an input connection call (Gboard 18 does, Gboard 15 does not).
 * UiAutomation gets no input connection: the system hands one only to bound services that
 * ask for it. speedrun installs the agent's APK and turns the service on for a run, and back
 * off after; the shell agent asks it through [KeyProvider].
 */
class KeyService : AccessibilityService() {
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
    // field's connection a moment after the field takes the focus: it is waited for, up to
    // [CONNECTION_WAIT_MS], and asked for again after [ASK_AGAIN_MS]. False with none.
    fun send(code: Int, count: Int): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
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
        private const val FLAGS = KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
        private const val CONNECTION_WAIT_MS = 1000L
        private const val ASK_AGAIN_MS = 200L
    }
}

/**
 * The shell agent's way to [KeyService]: `call("keys", null, {code, count})` -> {sent}. A call
 * is a binder transaction, which SELinux lets the shell user make into an app (as `content
 * call` does); a local socket it does not. Only the shell user and root may call.
 */
class KeyProvider : ContentProvider() {
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val uid = Binder.getCallingUid()
        if (uid != SHELL_UID && uid != 0) throw SecurityException("speedrun's agent only")
        if (method != "keys" || extras == null) return null
        val service = KeyService.instance
        val sent = try {
            service != null && service.send(extras.getInt("code"), extras.getInt("count").coerceIn(0, 10_000))
        } catch (e: Exception) {
            AgentLog.w("key service: send failed", e)
            false
        }
        return Bundle().apply { putBoolean("sent", sent) }
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
