package com.speedrun.agent

import android.app.UiAutomation
import android.os.HandlerThread
import android.os.Looper
import kotlin.system.exitProcess

/**
 * Launched as the shell user (the scrcpy approach):
 *   adb push app-debug.apk /data/local/tmp/agent.apk
 *   adb shell CLASSPATH=/data/local/tmp/agent.apk app_process / com.speedrun.agent.ShellMain 7777
 * (speedrun adds --nice-name=speedrun-agent so it can find and stop the process.)
 *
 * The shell uid holds INJECT_EVENTS, so input goes straight to the input manager, without
 * the transaction syncs UiAutomation does around every DOWN/UP. Tree reads and frame stats
 * still need a UiAutomation, built here the way `uiautomator dump` does (AOSP
 * UiAutomationShellWrapper). Only one UiAutomation client can exist at a time, so the
 * instrumentation must not be running.
 *
 * Exits non-zero, with the reason logged, when it cannot get going; speedrun then falls back
 * to the instrumentation.
 */
object ShellMain {
    @JvmStatic
    fun main(args: Array<String>) {
        AgentLog.echoToStdout = true
        val port = args.firstOrNull()?.toIntOrNull() ?: 7777
        val token = args.getOrNull(1) ?: ""
        if (token.length != TOKEN_LENGTH) {
            AgentLog.e("no token: usage ShellMain <port> <token>", null)
            exitProcess(2)
        }

        // app_process has no main looper, but AccessibilityInteractionClient (created when
        // the UiAutomation connects) builds a Handler on it.
        @Suppress("DEPRECATION")
        Looper.prepareMainLooper()

        val ua = try {
            connectUiAutomation()
        } catch (t: Throwable) {
            AgentLog.e("could not connect a UiAutomation (another client running, or hidden API missing)", cause(t))
            exitProcess(2)
        }

        Thread({ serve(ua, port, token) }, "SpeedrunAgentServer").start()
        Looper.loop() // runs whatever the framework posts to the main looper
    }

    private fun serve(ua: UiAutomation, port: Int, token: String) {
        try {
            val uiAutomationInjector = UiAutomationInjector(ua)
            val injector = InputManagerInjector.create(fallback = uiAutomationInjector) ?: uiAutomationInjector
            AgentLog.i("injection path: ${InjectPath.describe(injector.path)}")
            Agent(ua, injector).serve(port, token)
        } catch (t: Throwable) {
            AgentLog.e("agent crashed", t)
        }
        // Main sits in Looper.loop() and the looper threads are not daemons: exit explicitly so
        // the UiAutomation is released (process death releases it too; disconnecting is tidier).
        try { UiAutomation::class.java.getMethod("disconnect").invoke(ua) } catch (t: Throwable) { }
        exitProcess(1)
    }

    /** new UiAutomation(looper, new UiAutomationConnection()).connect(): all hidden API. */
    private fun connectUiAutomation(): UiAutomation {
        val thread = HandlerThread("SpeedrunUiAutomation").apply { start() }
        val connection = Class.forName("android.app.UiAutomationConnection")
            .getDeclaredConstructor()
            .newInstance()
        val ua = UiAutomation::class.java
            .getConstructor(Looper::class.java, Class.forName("android.app.IUiAutomationConnection"))
            .newInstance(thread.looper, connection)
        UiAutomation::class.java.getMethod("connect").invoke(ua)
        AgentLog.i("UiAutomation connected")
        return ua
    }
}
