// Speedrun's iOS agent: an XCUITest runner whose single test serves the agent protocol over
// TCP until it is stopped. Only an XCTest runner may drive other apps on iOS; on a simulator
// it listens on the Mac's own loopback, so no port forwarding is needed.
//
// Wire protocol (big-endian), the Android agent's framing:
//   request  = u8 op, then op-specific fields
//   response = u32 length, u32 agent_us, body[length - 4]
//   str = u16 len + utf8; bytes = u32 len + data
//
// This is the measurement spike (step 2): each op times one building block.
//   1 PING                                  -> (empty)
//   3 TAP    i32 x, i32 y, i32 hold_ms      -> u32 inject_us          (points; synthesized event)
//   8 TYPE   str text, i32 chars_per_s      -> u32 inject_us
//  14 SCREENSHOT                            -> bytes png
//  40 APP    str bundle_id                  -> u8 state               (XCUIApplication.State)
//  41 SNAP   u8 mode                        -> u32 count, u32 snapshot_us, u32 walk_us, count * node
//        mode 0: snapshot() walked through children; 1: snapshot().dictionaryRepresentation
//        node = u16 depth, i32 l, i32 t, i32 r, i32 b, u8 flags, str value, str label,
//               str identifier, str type, str placeholder, str title
//        flags: 2 enabled, 4 focused, 64 selected
//  42 QUERY  str text, u8 mode              -> u8 found, i32 l, i32 t, i32 r, i32 b
//        the first element whose label, value or identifier equals text (ignoring case).
//        mode 0: firstMatch.frame; 1: firstMatch.snapshot().frame; 2: firstMatch.exists only
//  43 IDLE   u8 mode, i32 timeout_ms        -> u8 ok, u32 since_tap_us, u32 waited_us, u32 checks,
//                                              u32 changes, u32 top_row, u32 bottom_row, u32 first_change_us (mode 2)
//  45 TAP_NOWAIT i32 x, i32 y, i32 hold_ms -> u32 dispatch_us         (TAP without waiting for delivery)
//        mode 0: XCTest's quiescence wait (event loop and animations idle; private API)
//        mode 1: Maestro's isScreenStatic, repeated: two screenshots, equal hashes
//        mode 2: reference: screenshots for timeout_ms; since_tap_us = the last change
//  44 METHODS str class                     -> str selectors, one per line ("+" for class methods)
import XCTest
import Darwin

final class SpeedrunAgentUITests: XCTestCase {
    func testServe() throws {
        let port = UInt16(ProcessInfo.processInfo.environment["SPEEDRUN_PORT"] ?? "") ?? 7778
        let server = try Server(port: port)
        Thread.detachNewThread { server.run() }
        NSLog("speedrun: listening on 127.0.0.1:\(port)")
        // XCTest APIs belong on the main thread: requests hop here, so keep its run loop going.
        while true { RunLoop.current.run(until: Date(timeIntervalSinceNow: 1)) }
    }
}

struct AgentError: Error { let message: String }

/// One client at a time, requests handled in order.
final class Server {
    private let listener: Int32
    private let ops = Ops()

    init(port: UInt16) throws {
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
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { continue }
            var one: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            serve(Conn(fd: fd))
            close(fd)
        }
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
