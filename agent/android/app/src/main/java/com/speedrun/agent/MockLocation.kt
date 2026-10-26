package com.speedrun.agent

import android.location.Location
import android.os.IBinder
import android.os.Process
import android.os.SystemClock
import java.lang.reflect.Method
import java.util.Timer
import java.util.TimerTask

/**
 * Test-provider locations set in-process, with a timer re-sending the location every 2 s.
 * `cmd location providers set-test-provider-location` costs a process per provider (~9 ms
 * each); this is one binder call per provider.
 *
 * Only as the shell user: com.android.shell holds the mock_location app op (speedrun sets it,
 * and adds and enables the providers, from the shell before the first location). Otherwise,
 * or when the hidden ILocationManager API is missing, set() returns 0 and speedrun falls back
 * to the shell commands.
 */
internal class MockLocation {
    private val service: Any? by lazy { connect() }
    private val setMethod: Method? by lazy { service?.let { findSet(it) } }
    private val timer by lazy { Timer("SpeedrunLocation", true) }
    private var task: TimerTask? = null

    /** Sets `lat,lon` on each provider now and every intervalMs after; the number set. */
    @Synchronized
    fun set(providers: List<String>, latitude: Double, longitude: Double, intervalMs: Long): Int {
        stop()
        if (providers.isEmpty()) return 0
        val count = providers.count { send(it, latitude, longitude) }
        if (count == 0 || intervalMs <= 0) return count
        task = object : TimerTask() {
            override fun run() {
                providers.forEach { send(it, latitude, longitude) }
            }
        }.also { timer.schedule(it, intervalMs, intervalMs) }
        return count
    }

    @Synchronized
    fun stop() {
        task?.cancel()
        task = null
    }

    private fun send(provider: String, latitude: Double, longitude: Double): Boolean {
        val m = setMethod ?: return false
        val location = Location(provider).apply {
            setLatitude(latitude)
            setLongitude(longitude)
            accuracy = 1f // Criteria.ACCURACY_FINE
            altitude = 0.0
            time = System.currentTimeMillis()
            elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
        }
        // (provider, location, packageName[, attributionTag]): the tag appeared in Android 11.
        val args = arrayOf<Any?>(provider, location, "com.android.shell", null).copyOf(m.parameterCount)
        return try {
            m.invoke(service, *args)
            true
        } catch (t: Throwable) {
            AgentLog.e("setTestProviderLocation($provider) failed", cause(t))
            false
        }
    }

    private fun connect(): Any? {
        if (Process.myUid() != 2000) return null // the mock_location op is granted to the shell only
        return try {
            val binder = Class.forName("android.os.ServiceManager")
                .getMethod("getService", String::class.java)
                .invoke(null, "location") as IBinder
            Class.forName("android.location.ILocationManager\$Stub")
                .getMethod("asInterface", IBinder::class.java)
                .invoke(null, binder)
        } catch (t: Throwable) {
            AgentLog.e("no ILocationManager (hidden API missing): falling back to the shell", cause(t))
            null
        }
    }

    private fun findSet(service: Any): Method? {
        val m = service.javaClass.methods.firstOrNull {
            it.name == "setTestProviderLocation" && it.parameterCount in 3..4 &&
                it.parameterTypes[0] == String::class.java &&
                it.parameterTypes[1] == Location::class.java &&
                it.parameterTypes.drop(2).all { p -> p == String::class.java }
        }
        if (m == null) AgentLog.e("ILocationManager.setTestProviderLocation not found: falling back to the shell")
        return m
    }
}
