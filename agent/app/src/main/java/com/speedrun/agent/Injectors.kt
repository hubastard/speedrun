package com.speedrun.agent

import android.app.UiAutomation
import android.view.InputEvent
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

/** The TAP/KEY response's inject_path byte. 0 and 1 keep the old fast_inject meaning. */
object InjectPath {
    /** Public UiAutomation API: syncs input transactions and waits for animations. */
    const val UI_AUTOMATION = 0
    /** Hidden UiAutomation overload: still syncs input transactions, no animation wait. */
    const val UI_AUTOMATION_FAST = 1
    /** Shell uid straight to the input manager: async, no transaction syncs. */
    const val INPUT_MANAGER = 2

    fun describe(path: Int) = when (path) {
        INPUT_MANAGER -> "InputManager as shell uid (async, no transaction syncs)"
        UI_AUTOMATION_FAST -> "UiAutomation, no animation wait (syncs input transactions)"
        else -> "UiAutomation public API (syncs input transactions, waits for animations)"
    }
}

/** How input events reach the system. Implementations fall back on their own, never throw. */
interface Injector {
    /** One of [InjectPath]; may change at runtime when a path falls back. */
    val path: Int
    /** sync = return only once the app has handled the event (async otherwise). */
    fun inject(e: InputEvent, sync: Boolean = false)
}

/** Unwraps reflection's InvocationTargetException so logs show the real error. */
internal fun cause(t: Throwable) = (t as? InvocationTargetException)?.targetException ?: t

/**
 * Through the UiAutomation connection. Before DOWN and after UP it calls
 * IWindowManager.syncInputTransactions, which waits for SurfaceFlinger to report window
 * infos to the input dispatcher: about 30 ms each on the emulator, ~63 ms per tap.
 */
class UiAutomationInjector(private val ua: UiAutomation) : Injector {
    // Hidden @TestApi overload injectInputEvent(event, sync, waitForAnimations) (Android 13+).
    // The public overload passes waitForAnimations = true, which makes the system wait for
    // window animations around DOWN/UP. Null when unavailable; we then use the public one.
    private var fastInject: Method? = try {
        UiAutomation::class.java.getMethod(
            "injectInputEvent", InputEvent::class.java, java.lang.Boolean.TYPE, java.lang.Boolean.TYPE,
        )
    } catch (t: Throwable) {
        AgentLog.w("UiAutomation.injectInputEvent(event, sync, waitForAnimations) missing, using public API: $t")
        null
    }

    override val path get() = if (fastInject != null) InjectPath.UI_AUTOMATION_FAST else InjectPath.UI_AUTOMATION

    override fun inject(e: InputEvent, sync: Boolean) {
        val m = fastInject
        if (m != null) {
            try {
                m.invoke(ua, e, sync, false)
                return
            } catch (t: Throwable) {
                AgentLog.w("fast injection unavailable, using public API: ${cause(t)}")
                fastInject = null
            }
        }
        ua.injectInputEvent(e, sync)
    }
}

/**
 * Straight to the hidden input manager, like scrcpy. Needs INJECT_EVENTS, which the shell
 * uid has (ShellMain). Async mode returns once the event is queued in the input dispatcher;
 * sync (wait-for-finish) once the app has handled it.
 * If the call throws (hidden method gone, permission denied) it logs once and hands this and
 * every later event to [fallback]. A refused event (false) is only logged: UiAutomation ends
 * up in the same InputManagerGlobal.injectInputEvent, so switching would not help.
 */
class InputManagerInjector private constructor(
    private val manager: Any,
    private val injectMethod: Method,
    private val fallback: Injector,
) : Injector {
    @Volatile private var failed = false

    override val path get() = if (failed) fallback.path else InjectPath.INPUT_MANAGER

    override fun inject(e: InputEvent, sync: Boolean) {
        if (!failed) {
            try {
                val mode = if (sync) INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH else INJECT_INPUT_EVENT_MODE_ASYNC
                if (!(injectMethod.invoke(manager, e, mode) as Boolean)) {
                    AgentLog.w("InputManager refused $e")
                }
                return
            } catch (t: Throwable) {
                AgentLog.w("InputManager injection failed; using UiAutomation injection from now on", cause(t))
            }
            failed = true
        }
        fallback.inject(e, sync)
    }

    companion object {
        private const val INJECT_INPUT_EVENT_MODE_ASYNC = 0
        private const val INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH = 2

        /** Null (with the reason logged) when the hidden API is not there. */
        fun create(fallback: Injector): InputManagerInjector? {
            // Android 14 moved injection from InputManager to InputManagerGlobal.
            val cls = try {
                Class.forName("android.hardware.input.InputManagerGlobal")
            } catch (t: ClassNotFoundException) {
                android.hardware.input.InputManager::class.java
            }
            return try {
                val manager = cls.getDeclaredMethod("getInstance").invoke(null)
                    ?: throw IllegalStateException("${cls.name}.getInstance() returned null")
                val method = cls.getMethod("injectInputEvent", InputEvent::class.java, Integer.TYPE)
                InputManagerInjector(manager, method, fallback)
            } catch (t: Throwable) {
                AgentLog.w("${cls.name} injection unavailable", cause(t))
                null
            }
        }
    }
}
