// SETTLE on iOS: XCTest's own quiescence (the app's event loop, then its animations, idle),
// checked against the screen, because quiescence alone was seen to report idle before a push
// transition had begun:
//   1. wait for quiescence, then take the foreground app's signature (Screen.signature);
//   2. while it still equals the screen the flow last read, nothing has happened yet: poll
//      until it differs, or report "no change" once no_change_ms have passed since the action;
//   3. once it differs, settled when two signatures in a row, each after quiescence, agree.
// After a swipe, quiescence leaves out animations: the content stops at lift-up, and what is
// left (the scroll indicator fading) does not matter to a flow; content still moving shows up
// as differing signatures.
// Typing and drags return before testmanagerd confirms their events: settle checks the
// screen meanwhile, but concludes (settled or no change) only once they are confirmed.
// An animation that never ends (under an open context menu) would hold quiescence for
// XCTest's 60 s: a wait is cut at quiescenceCapS, and once one was, the settle waits for the
// event loop only, the signatures telling whether the screen still changes.
// A React Native app's busy JavaScript thread holds the settle off too (JsThread), for at most
// jsWaitMaxNs: React Native's tree can show a screen that does not take touches yet.
// Times are measured from the last action. quiet_ms is unused: quiescence is the quiet signal.
import XCTest

final class Settle {
    private let screen: Screen
    private let input: Input
    private let js = JsThread()
    private static let pollMs = 30
    /// An app whose JavaScript stays busy this long is then not waited for again until it has
    /// been seen idle once.
    private static let jsWaitMaxNs: UInt64 = 2_000_000_000
    /// Longer than UIKit's transitions, the keyboard's and SpringBoard's (~0.5 s).
    private static let quiescenceCapS = 2.0

    init(screen: Screen, input: Input) {
        self.screen = screen
        self.input = input
    }

    /// Response: u8 status (0 settled, 1 no change, 2 timeout), u32 ui_done_us, u32 waited_us,
    /// u8 method (2: quiescence + signature), u32 quiescence waits, u32 signatures,
    /// u32 longest quiescence wait in us, u32 events (0), u32 how long a busy JavaScript thread
    /// held it off in us. Main thread.
    func run(quietMs: Int, noChangeMs: Int, timeoutMs: Int, out: inout Writer) throws {
        let start = input.lastActionNs
        let deadline = start + UInt64(max(timeoutMs, 0)) * 1_000_000
        let noChangeUntil = start + UInt64(max(noChangeMs, 0)) * 1_000_000
        let before = screen.lastSignature
        var waits: UInt32 = 0, signatures: UInt32 = 0, longest: UInt32 = 0
        var changed = before == nil // nothing to compare with: require two equal signatures
        var previous: Int?
        var doneAt = start
        var status: UInt8 = 2
        var animations = !input.lastWasSwipe
        var jsFrom: UInt64 = 0 // when a busy JavaScript thread first held this settle off
        var jsLast: UInt64 = 0 // and last did

        func jsBusy(_ now: UInt64) -> Bool {
            if jsFrom != 0 && now &- jsFrom >= Self.jsWaitMaxNs { return false }
            js.follow(pid: screen.foregroundPID, now: now)
            if !js.busy(now: now) { js.pegged = false; return false }
            if js.pegged { return false }
            if jsFrom == 0 { jsFrom = now } else if now &- jsFrom >= Self.jsWaitMaxNs { js.pegged = true; return false }
            jsLast = now
            return true
        }

        while true {
            let q = DispatchTime.now().uptimeNanoseconds
            let cap = min(Self.quiescenceCapS, max(Double(deadline &- min(q, deadline)) / 1e9, 0.1))
            try Private.waitForQuiescence(screen.foregroundApp(), animations: animations, timeout: cap)
            waits += 1
            longest = max(longest, micros(since: q))
            if Double(micros(since: q)) >= cap * 0.95e6 { animations = false }
            js.sample(now: DispatchTime.now().uptimeNanoseconds)
            let sig = try screen.signature()
            signatures += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if !changed && sig != before { changed = true }
            if changed {
                if sig == previous, try Private.pendingConfirmed(), !jsBusy(now) {
                    status = 0
                    break
                }
                previous = sig
                doneAt = now
            } else if now >= noChangeUntil, try Private.pendingConfirmed(), !jsBusy(now) {
                status = 1
                doneAt = start
                break
            } else {
                Thread.sleep(forTimeInterval: Double(Self.pollMs) / 1000)
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
        }

        screen.settledSignature = screen.lastSignature
        out.u8(status)
        out.u32(doneAt > start ? UInt32(clamping: (doneAt - start) / 1000) : 0)
        out.u32(micros(since: start))
        out.u8(2)
        out.u32(waits)
        out.u32(signatures)
        out.u32(longest)
        out.u32(0)
        out.u32(jsFrom != 0 ? UInt32(clamping: (jsLast &- jsFrom) / 1000) : 0)
    }
}

/// The JavaScript thread of the React Native app in front ("com.facebook.react.JavaScript", or
/// "com.facebook.react.runtime.JavaScript" without the bridge), its CPU time read with libproc:
/// a simulator's apps are processes of this Mac, as the agent is. React Native's tree shows the
/// next screen as soon as JavaScript commits it, while the one it replaces can stay mounted
/// (React Navigation's JavaScript stack before version 7 removes a closing card only when its
/// animation's end reaches JavaScript) and the next one ignore touches until JavaScript runs
/// again: a tap then reaches nothing. Busy = JavaScript ran for more than busyShare of the last
/// windowNs; a JavaScript-driven animation takes a small part of each frame. The Android agent
/// has the same (JsThread.kt).
final class JsThread {
    private static let windowNs: UInt64 = 40_000_000
    private static let minSpanNs: UInt64 = 12_000_000
    private static let busyShare = 0.4
    /// An app in front without a JavaScript thread is looked up again after this long: React
    /// Native starts its thread after the app's first frames.
    private static let lookUpAgainNs: UInt64 = 1_000_000_000
    private static let threadInfoSize = 112 // struct proc_threadinfo
    private var pid: Int32 = 0
    private var thread: UInt64 = 0 // its handle, as PROC_PIDLISTTHREADS lists it
    private var lookedUp: UInt64 = 0
    private var samples: [(at: UInt64, run: UInt64)] = [] // oldest first
    /// JavaScript stayed busy through a whole wait: not waited for again until seen idle.
    var pegged = false

    /// Follows the app in front (none: SpringBoard).
    func follow(pid: Int32?, now: UInt64) {
        guard let pid, pid > 0 else {
            self.pid = 0
            thread = 0
            samples.removeAll()
            return
        }
        if pid == self.pid && (thread != 0 || now &- lookedUp < Self.lookUpAgainNs) { return }
        self.pid = pid
        lookedUp = now
        samples.removeAll()
        thread = Self.lookUp(pid) ?? 0
    }

    /// Records the thread's CPU time now, when there is one.
    func sample(now: UInt64) {
        guard thread != 0 else { return }
        guard let run = Self.runtime(pid, thread) else {
            thread = 0
            samples.removeAll()
            return
        }
        samples.append((now, run))
        if samples.count > 16 { samples.removeFirst() }
    }

    func busy(now: UInt64) -> Bool {
        sample(now: now)
        guard thread != 0, var end = samples.last else { return false }
        // Over the last windowNs, or the shortest span past minSpanNs when the sample before
        // that is old (a long quiescence wait): a long span would hide work that just began.
        var ref = samples.last(where: { now &- $0.at >= Self.windowNs && now &- $0.at <= 3 * Self.windowNs })
            ?? samples.last(where: { now &- $0.at >= Self.minSpanNs && now &- $0.at < Self.windowNs })
        if ref == nil {
            ref = end
            Thread.sleep(forTimeInterval: Double(Self.minSpanNs) / 1e9)
            sample(now: DispatchTime.now().uptimeNanoseconds)
            guard thread != 0, let last = samples.last else { return false }
            end = last
        }
        guard let ref, end.at > ref.at else { return false }
        return Double(end.run &- ref.run) / Double(end.at - ref.at) > Self.busyShare
    }

    /// User and system time the thread has run, in nanoseconds; nil once it is gone.
    private static func runtime(_ pid: Int32, _ thread: UInt64) -> UInt64? {
        var info = [UInt8](repeating: 0, count: threadInfoSize)
        let n = info.withUnsafeMutableBytes { proc_pidinfo(pid, procPidThreadInfo, thread, $0.baseAddress, Int32(threadInfoSize)) }
        guard n >= 16 else { return nil }
        return info.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) &+ $0.load(fromByteOffset: 8, as: UInt64.self) }
    }

    private static func lookUp(_ pid: Int32) -> UInt64? {
        var threads = [UInt64](repeating: 0, count: 1024)
        let n = threads.withUnsafeMutableBytes { proc_pidinfo(pid, procPidListThreads, 0, $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }
        var info = [UInt8](repeating: 0, count: threadInfoSize)
        for thread in threads.prefix(Int(n) / 8) {
            let got = info.withUnsafeMutableBytes { proc_pidinfo(pid, procPidThreadInfo, thread, $0.baseAddress, Int32(threadInfoSize)) }
            guard got == Int32(threadInfoSize) else { continue }
            let name = info[48...].prefix(while: { $0 != 0 })
            let s = String(decoding: name, as: UTF8.self)
            if s == "com.facebook.react.JavaScript" || s == "com.facebook.react.runtime.JavaScript" { return thread }
        }
        return nil
    }
}

private let procPidListThreads: Int32 = 6 // PROC_PIDLISTTHREADS
private let procPidThreadInfo: Int32 = 5 // PROC_PIDTHREADINFO

// libproc (libsystem_kernel), whose header the iOS SDK leaves out.
@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
