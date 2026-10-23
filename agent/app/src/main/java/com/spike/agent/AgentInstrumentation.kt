package com.spike.agent

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle

/**
 * Fallback entry point (ShellMain is the fast one). Launched with:
 *   adb shell am instrument -w --no-hidden-api-checks -e port 7777 com.spike.agent/.AgentInstrumentation
 * (--no-hidden-api-checks lets it use the injection call that skips the animation wait.)
 *
 * Runs as an instrumentation so it gets a UiAutomation connection (global tree access +
 * input injection) without the user enabling an accessibility service by hand. Injection
 * goes through UiAutomation, which syncs input transactions around DOWN/UP (~63 ms per tap).
 * The wire protocol is documented in Agent.kt.
 */
class AgentInstrumentation : Instrumentation() {
    private var port = 7777

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        port = arguments?.getString("port")?.toIntOrNull() ?: 7777
        start() // spawns a thread that calls onStart()
    }

    override fun onStart() {
        super.onStart()
        try {
            val ua = uiAutomation
            val injector = UiAutomationInjector(ua)
            AgentLog.i("injection path: ${InjectPath.describe(injector.path)}")
            Agent(ua, injector).serve(port)
        } catch (t: Throwable) {
            AgentLog.e("agent crashed", t)
        }
        finish(Activity.RESULT_OK, Bundle())
    }
}
