// Speedrun's iOS agent: an XCUITest runner whose single test serves the agent protocol over
// TCP until it is stopped. Only an XCTest runner may drive other apps on iOS; on a simulator
// it listens on the Mac's own loopback, so no port forwarding is needed.
// Starting it (xcodebuild test-without-building) takes seconds, so it outlives a run: the
// next one reuses it. It stops on QUIT, or after SPEEDRUN_IDLE_S seconds (default 600)
// without a client. Each new client starts from fresh state (no cached screen).
//
// Wire protocol (big-endian), the Android agent's framing:
//   request  = u8 op, then op-specific fields
//   response = u32 length, u32 agent_us, body[length - 4]
//   str = u16 len + utf8; bytes = u32 len + data
//
// The Android agent's ops, same numbers and responses (see Agent.kt), as iOS does them:
//   1 PING                                  -> (empty)
//  10 SCREEN                                -> u32 count, count * node, u8 changed since SETTLE (Screen.swift)
//        the foreground app, then SpringBoard's status bars, each a root at depth 0; the
//        iOS attribute mapping flows match against; frames in points
//   3 TAP    i32 x, i32 y                   -> u32 prep_us, u32 inject_us, u8 inject_path (3)
//  13 PRESS  i32 x, i32 y, i32 hold_ms      -> same
//  23 TAPS   i32 x, i32 y, i32 count, i32 interval_ms -> same
//        count taps, interval_ms apart, as one gesture (doubleTapOn)
//  24 HIT    i32 x, i32 y                   -> i32 index
//        the node of the last SCREEN response that a touch at the point reaches (the
//        accessibility hit test, as XCUIElement.isHittable), -1 for none
//   7 SWIPE  i32 x1, y1, x2, y2, duration_ms, flags -> same
//        flags & 1 (fling): a swipe gliding over duration_ms; otherwise a drag that stops when
//        the touch lifts (Input.drag; duration_ms unused)
//   8 TYPE   str text                       -> same, u32 skipped (always 0)
//   9 ERASE  i32 count                      -> same   (count deletes, at most the focused
//                                                     field's length; inject_path 255: none)
//   4 KEY    i32 android_keycode            -> same   (ENTER, DEL, HOME, POWER; others no-op)
//  12 MARK                                  -> (empty)
//   5 SETTLE i32 quiet_ms, i32 no_change_ms, i32 timeout_ms -> as on Android (Settle.swift)
//  14 SCREENSHOT                            -> bytes png
//  15 QUIT                                  -> (empty), then the runner stops
//  17 LAUNCHED str bundle_id, i32 timeout_ms -> u8 ok
//        after `simctl launch`: the app runs in the foreground and its UI can be read
//  16 INFO                                  -> str simulator udid, str description, str build
//        description: "<model> - iOS <version> - <udid>"
//        build = SPEEDRUN_BUILD as given at launch: the host restarts a runner of another build
// Measurement ops from the spike (Spike.swift; agent/ios/README.md):
//  40 APP    str bundle_id                  -> u8 state               (target of 41-43)
//  41 SNAP   u8 mode                        -> u32 count, u32 snapshot_us, u32 walk_us, count * node
//        mode 0: snapshot() walked through children; 1: snapshot().dictionaryRepresentation
//        node = u16 depth, i32 l, i32 t, i32 r, i32 b, u8 flags, str value, str label,
//               str identifier, str type, str placeholder, str title
//  42 QUERY  str text, u8 mode              -> u8 found, i32 l, i32 t, i32 r, i32 b
//        the first element whose label, value or identifier equals text (ignoring case).
//        mode 0: firstMatch.frame; 1: firstMatch.snapshot().frame; 2: firstMatch.exists only
//  43 IDLE   u8 mode, i32 timeout_ms        -> u8 ok, u32 since_tap_us, u32 waited_us, u32 checks,
//                                              u32 changes, u32 top_row, u32 bottom_row, u32 first_change_us
//        mode 0: XCTest's quiescence wait; 1: a static-screen check, repeated (two
//        screenshots, equal hashes); 2: reference: raw screenshots for timeout_ms
//  44 METHODS str class                     -> str selectors, one per line ("+" for class methods)
//  45 TAP_NOWAIT i32 x, i32 y, i32 hold_ms  -> u32 dispatch_us        (no wait for delivery)
//  46 TAP_HOLD   i32 x, i32 y, i32 hold_ms  -> u32 inject_us          (until delivered)
//  47 TYPE_RATE  str text, i32 chars_per_s  -> u32 inject_us          (_XCT_sendString)
//  48 FOREGROUND                          -> str: what each way of listing the active apps returns
//  49 TYPE_TEST  str text, i32 first_rate, i32 rest_rate, i32 wait_cap_ms -> u32 total_us
//  50 DRAG_TEST  i32 n, n * (i32 x, i32 y, i32 offset_ms, i32 duration_ms), i32 lift_ms, i32 wait
//                                         -> u32 inject_us
//        down at the first point, a move to each next one (Private.drag), up at lift_ms;
//        wait 0: returns once sent (spike/swipe.py traces the content meanwhile)
//  51 HITTABLE   str identifier             -> u8 exists, u8 hittable, u32 us
//        XCUIElement.isHittable of the first element with that identifier
import XCTest
import Darwin

final class SpeedrunAgentUITests: XCTestCase {
    func testServe() throws {
        let env = ProcessInfo.processInfo.environment
        let port = UInt16(env["SPEEDRUN_PORT"] ?? "") ?? 7778
        let idle = TimeInterval(env["SPEEDRUN_IDLE_S"] ?? "") ?? 600
        let ax = Private.setAXTimeout(Screen.axTimeoutSeconds)
        NSLog("speedrun: accessibility timeout \(ax ? "\(Screen.axTimeoutSeconds) s" : "unchanged (no setter in this Xcode)")")
        let server = try Server(port: port, idleSeconds: idle)
        Thread.detachNewThread { server.run() }
        NSLog("speedrun: listening on 127.0.0.1:\(port)")
        // XCTest APIs belong on the main thread: requests hop here, so keep its run loop going.
        while !server.stopped { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        NSLog("speedrun: stopped")
    }
}

struct AgentError: Error { let message: String }

/// One client at a time, requests handled in order.
final class Server {
    private let listener: Int32
    private let ops = Ops()
    private let idleNs: UInt64
    /// Set by the server thread (QUIT, idle), read by the main thread.
    private(set) var stopped = false

    init(port: UInt16, idleSeconds: TimeInterval) throws {
        idleNs = UInt64(max(idleSeconds, 1) * 1_000_000_000)
        listener = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            throw AgentError(message: "cannot listen on port \(port): errno \(errno)")
        }
    }

    func run() {
        var lastClient = DispatchTime.now().uptimeNanoseconds
        while !stopped {
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 1000) <= 0 {
                if DispatchTime.now().uptimeNanoseconds - lastClient > idleNs {
                    NSLog("speedrun: idle for \(idleNs / 1_000_000_000) s, stopping")
                    stopped = true
                }
                continue
            }
            let fd = accept(listener, nil, nil)
            if fd < 0 { continue }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            onMain { ops.reset() }
            serve(Conn(fd: fd))
            close(fd)
            lastClient = DispatchTime.now().uptimeNanoseconds
        }
        close(listener)
    }

    private func serve(_ conn: Conn) {
        while let op = conn.readU8() {
            let start = DispatchTime.now().uptimeNanoseconds
            var body = Writer()
            do {
                try ops.handle(op: op, conn: conn, out: &body)
            } catch {
                NSLog("speedrun: op \(op) failed: \(error)")
                return // the host sees the connection close
            }
            let us = UInt32(min((DispatchTime.now().uptimeNanoseconds - start) / 1000, UInt64(UInt32.max)))
            var head = Writer()
            head.u32(UInt32(body.data.count + 4))
            head.u32(us)
            guard conn.write(head.data + body.data) else { return }
            if ops.quitRequested {
                stopped = true
                return
            }
        }
    }
}

/// Blocking reads and writes on a connected socket.
final class Conn {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }

    func read(_ n: Int) -> Data? {
        var data = Data(count: n)
        var got = 0
        while got < n {
            let r = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { return nil }
            got += r
        }
        return data
    }

    func readU8() -> UInt8? { read(1)?.first }

    func readI32() throws -> Int32 {
        guard let d = read(4) else { throw AgentError(message: "connection closed") }
        return Int32(bitPattern: d.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    func readStr() throws -> String {
        guard let l = read(2) else { throw AgentError(message: "connection closed") }
        let n = Int(l[l.startIndex]) << 8 | Int(l[l.startIndex + 1])
        guard let d = read(n) else { throw AgentError(message: "connection closed") }
        return String(decoding: d, as: UTF8.self)
    }

    func write(_ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let r = data.withUnsafeBytes { send(fd, $0.baseAddress! + sent, data.count - sent, 0) }
            if r <= 0 { return false }
            sent += r
        }
        return true
    }
}

struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xff)) }
    mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { data.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func str(_ s: String) {
        var b = Data(s.utf8)
        if b.count > 0xffff { b = b.prefix(0xffff) }
        u16(UInt16(b.count))
        data.append(b)
    }
    mutating func bytes(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
}
