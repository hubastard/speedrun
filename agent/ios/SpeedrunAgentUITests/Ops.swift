// The agent's operations (documented in Agent.swift). XCUIApplication work runs on the main
// thread; event synthesis does not (its completion may need the main queue).
import XCTest

final class Ops {
    let screen = Screen()
    let input = Input()
    lazy var settle = Settle(screen: screen, input: input)
    lazy var spike = Spike(screen: screen, input: input)

    func handle(op: UInt8, conn: Conn, out: inout Writer) throws {
        switch op {
        case 1: // PING
            break
        case 3: // TAP
            let x = try conn.readI32(), y = try conn.readI32()
            try input.tap(x: x, y: y, out: &out)
        case 4: // KEY
            try input.key(try conn.readI32(), out: &out)
        case 5: // SETTLE
            let quiet = try conn.readI32(), noChange = try conn.readI32(), timeout = try conn.readI32()
            try onMain { try settle.run(quietMs: Int(quiet), noChangeMs: Int(noChange), timeoutMs: Int(timeout), out: &out) }
        case 7: // SWIPE
            let x1 = try conn.readI32(), y1 = try conn.readI32(), x2 = try conn.readI32(), y2 = try conn.readI32()
            let duration = try conn.readI32(), _ /* flags */ = try conn.readI32()
            try input.swipe(from: (x1, y1), to: (x2, y2), durationMs: duration, out: &out)
        case 8: // TYPE
            let text = try conn.readStr()
            try input.type(text, screen: screen, out: &out)
            out.u32(0) // skipped: none, any character can be typed
        case 9: // ERASE
            let count = try conn.readI32()
            try input.type(String(repeating: "\u{8}", count: Int(max(0, min(count, 10_000)))), screen: screen, out: &out)
        case 10: // SCREEN
            try onMain { try screen.read(lastActionNs: input.lastActionNs, out: &out) }
        case 12: // MARK
            input.mark()
        case 13: // PRESS
            let x = try conn.readI32(), y = try conn.readI32(), hold = try conn.readI32()
            try input.tap(x: x, y: y, holdMs: hold, out: &out)
        case 14: // SCREENSHOT
            out.bytes(onMain { XCUIScreen.main.screenshot().pngRepresentation })
        case 40...49:
            try spike.handle(op: op, conn: conn, out: &out)
        default:
            throw AgentError(message: "unknown op \(op)")
        }
    }
}

func micros(since ns: UInt64) -> UInt32 {
    UInt32(clamping: (DispatchTime.now().uptimeNanoseconds &- ns) / 1000)
}

func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
}
