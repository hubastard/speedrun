package com.speedrun.agent

import android.os.SystemClock
import java.io.File
import java.io.RandomAccessFile

// JavaScript busier than JS_BUSY_SHARE of the last JS_WINDOW_NS is still working on the last
// action. A JavaScript-driven animation (Animated without the native driver) takes ~10% of a
// frame on an emulator; a render or a handler, all of it. The kernel adds a running thread's
// time at each scheduler tick (4 to 10 ms), hence a window of several ticks.
private const val JS_WINDOW_NS = 40_000_000L
private const val JS_MIN_SPAN_NS = 12_000_000L
private const val JS_BUSY_SHARE = 0.4
// An app in front without a JavaScript thread is looked up again after this long: React
// Native starts its thread after the app's first frames.
private const val JS_LOOKUP_AGAIN_NS = 1_000_000_000L

/**
 * The JavaScript threads of the React Native app in front (mqt_js, or mqt_v_js with the new
 * architecture; an Expo dev client runs two, its launcher's and the app's), their CPU time
 * read from /proc and added up. React Native's tree shows the next screen as
 * soon as JavaScript commits it, while the screen it replaces can stay mounted and take the
 * touches (React Navigation's JavaScript stack before version 7 removes a closing card only
 * when its animation's end reaches JavaScript) and the next one ignore them, until JavaScript
 * runs again: a busy JavaScript thread means a tap may not reach what the tree shows.
 * Only the shell agent can see another app's processes: as the instrumentation, nothing is
 * found and busy() is always false.
 */
internal class JsThread {
    private var pkg: String? = null
    private var files: List<RandomAccessFile> = emptyList()
    private var lookedUp = 0L
    private val buf = ByteArray(64)
    private val times = LongArray(16)
    private val runs = LongArray(16)
    private var count = 0
    private var next = 0
    // JavaScript stayed busy through a whole wait (JS_WAIT_MAX_NS): not waited for again until
    // it has been seen idle.
    var pegged = false

    /** Follows the app in front (its package, from the active window's root). */
    fun follow(packageName: String?, now: Long) {
        if (packageName == null) return
        if (packageName == pkg && (files.isNotEmpty() || now - lookedUp < JS_LOOKUP_AGAIN_NS)) return
        drop()
        pkg = packageName
        lookedUp = now
        files = lookUp(packageName)
    }

    /** The threads' CPU time so far in nanoseconds, -1 when there are none. */
    fun runtime(): Long {
        if (files.isEmpty()) return -1
        var total = 0L
        for (f in files) {
            val run = runtime(f)
            if (run < 0) { drop(); return -1 }
            total += run
        }
        return total
    }

    /** Records the threads' CPU time now, when there are some. */
    fun sample(now: Long) {
        val run = runtime()
        if (run < 0) return
        times[next] = now
        runs[next] = run
        next = (next + 1) % times.size
        if (count < times.size) count++
    }

    /** JavaScript ran for more than JS_BUSY_SHARE of the last JS_WINDOW_NS. */
    fun busy(now: Long): Boolean {
        sample(now)
        if (files.isEmpty()) return false
        var k = newestBefore(now - JS_WINDOW_NS) ?: oldestSince(now - JS_MIN_SPAN_NS)
        var at = now
        if (k == null) { // not enough history: measure over JS_MIN_SPAN_NS
            Thread.sleep(JS_MIN_SPAN_NS / 1_000_000)
            at = SystemClock.elapsedRealtimeNanos()
            k = (next - 1 + times.size) % times.size
            sample(at)
            if (files.isEmpty()) return false
        }
        val last = (next - 1 + times.size) % times.size
        val span = times[last] - times[k]
        return span > 0 && (runs[last] - runs[k]).toDouble() / span > JS_BUSY_SHARE
    }

    private fun newestBefore(t: Long): Int? {
        for (i in 1..count) {
            val k = (next - i + times.size) % times.size
            if (times[k] <= t) return k
        }
        return null
    }

    private fun oldestSince(t: Long): Int? {
        if (count < 2) return null
        val k = (next - count + times.size) % times.size
        return if (times[k] <= t) k else null
    }

    private fun drop() {
        for (f in files) try { f.close() } catch (e: Exception) { }
        files = emptyList()
        count = 0
    }

    /** Nanoseconds the thread has run (schedstat's first field), -1 once it is gone. */
    private fun runtime(f: RandomAccessFile): Long = try {
        f.seek(0)
        val n = f.read(buf)
        var v = 0L
        var i = 0
        while (i < n && buf[i] in '0'.code.toByte()..'9'.code.toByte()) { v = v * 10 + (buf[i] - '0'.code.toByte()); i++ }
        if (i == 0) -1 else v
    } catch (e: Exception) { -1 }

    /** The package's main process (its command line is the package name), then its threads. */
    private fun lookUp(packageName: String): List<RandomAccessFile> {
        val procs = File("/proc").listFiles() ?: return emptyList()
        val want = packageName.toByteArray()
        for (p in procs) {
            val name = p.name
            if (name.isEmpty() || !name[0].isDigit()) continue
            val cmd = try { File(p, "cmdline").readBytes() } catch (e: Exception) { continue }
            if (cmd.size < want.size || !(0 until want.size).all { cmd[it] == want[it] }) continue
            if (cmd.size > want.size && cmd[want.size] != 0.toByte()) continue
            val found = ArrayList<RandomAccessFile>()
            for (t in File(p, "task").listFiles() ?: emptyArray()) {
                val comm = try { File(t, "comm").readText().trim() } catch (e: Exception) { continue }
                if (comm == "mqt_js" || comm == "mqt_v_js") {
                    try { found += RandomAccessFile(File(t, "schedstat"), "r") } catch (e: Exception) { }
                }
            }
            return found
        }
        return emptyList()
    }
}
