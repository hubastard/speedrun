// Measurement-only operations from the spike (agent/ios/README.md), kept to re-time the
// building blocks. Documented in Agent.swift (ops 40-47).
import XCTest
import CryptoKit

final class Spike {
    private let screen: Screen
    private let input: Input
    private var app = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    init(screen: Screen, input: Input) {
        self.screen = screen
        self.input = input
    }

    func handle(op: UInt8, conn: Conn, out: inout Writer) throws {
        switch op {
        case 40: // APP
            let id = try conn.readStr()
            out.u8(UInt8(onMain { () -> UInt in
                self.app = XCUIApplication(bundleIdentifier: id)
                return self.app.state.rawValue
            }))
        case 41: // SNAP
            let mode = conn.readU8() ?? 0
            try onMain { try snap(mode: mode, out: &out) }
        case 42: // QUERY
            let text = try conn.readStr(), mode = conn.readU8() ?? 0
            onMain { query(text, mode: mode, out: &out) }
        case 43: // IDLE
            let mode = conn.readU8() ?? 0, timeout = try conn.readI32()
            try onMain { try idle(mode: mode, timeoutMs: Int(timeout), out: &out) }
        case 44: // METHODS
            out.str(Private.methods(of: try conn.readStr()).joined(separator: "\n"))
        case 45, 46: // TAP_NOWAIT, TAP_HOLD
            let x = try conn.readI32(), y = try conn.readI32(), hold = try conn.readI32()
            input.mark()
            let t = DispatchTime.now().uptimeNanoseconds
            try Private.tap(at: CGPoint(x: Int(x), y: Int(y)), hold: TimeInterval(hold) / 1000, wait: op == 46)
            out.u32(micros(since: t))
        case 47: // TYPE_RATE
            let text = try conn.readStr(), rate = try conn.readI32()
            input.mark()
            let t = DispatchTime.now().uptimeNanoseconds
            try Private.type(text, charsPerSecond: Int(rate))
            out.u32(micros(since: t))
        case 49: // TYPE_TEST
            let text = try conn.readStr(), first = try conn.readI32(), rest = try conn.readI32(), cap = try conn.readI32()
            let t = DispatchTime.now().uptimeNanoseconds
            try input.type(text, screen: screen, firstRate: Int(first), restRate: Int(rest), waitCapMs: Int(cap))
            out.u32(micros(since: t))
        case 50: // DRAG_TEST
            var points: [(point: CGPoint, offset: TimeInterval, duration: TimeInterval)] = []
            for _ in 0..<Int(max(try conn.readI32(), 0)) {
                let x = try conn.readI32(), y = try conn.readI32(), offset = try conn.readI32(), duration = try conn.readI32()
                points.append((CGPoint(x: Int(x), y: Int(y)), TimeInterval(offset) / 1000, TimeInterval(duration) / 1000))
            }
            let lift = try conn.readI32(), wait = try conn.readI32()
            guard !points.isEmpty else { throw AgentError(message: "DRAG_TEST without points") }
            let t = DispatchTime.now().uptimeNanoseconds
            input.mark()
            guard try Private.drag(through: points, liftAt: TimeInterval(lift) / 1000, wait: wait != 0) else {
                throw AgentError(message: "this Xcode has no explicit move events")
            }
            out.u32(micros(since: t))
        case 48: // FOREGROUND
            out.str(onMain { Private.foregroundReport() })
        case 51: // HITTABLE
            let id = try conn.readStr()
            let t = DispatchTime.now().uptimeNanoseconds
            let (exists, hittable) = onMain { () -> (Bool, Bool) in
                let e = self.app.descendants(matching: .any).matching(identifier: id).firstMatch
                let exists = e.exists
                return (exists, exists && e.isHittable)
            }
            out.u8(exists ? 1 : 0)
            out.u8(hittable ? 1 : 0)
            out.u32(micros(since: t))
        case 52: // ISSUE
            // Makes XCTest record an issue, as an accessibility error inside its calls does: 0 an
            // XCTFail, 1 an automation failure (the frame of an element that is not there).
            let kind = try conn.readI32()
            onMain {
                if kind == 0 {
                    XCTFail("speedrun: a test issue (ISSUE op)")
                } else {
                    _ = self.app.descendants(matching: .any).matching(identifier: "speedrun-none").firstMatch.frame
                }
            }
        default:
            throw AgentError(message: "unknown op \(op)")
        }
    }

    private func snap(mode: UInt8, out: inout Writer) throws {
        let t = DispatchTime.now().uptimeNanoseconds
        let root = try app.snapshot()
        var nodes = Writer()
        var count: UInt32 = 0
        let t2: UInt64
        if mode == 1 {
            let dict = root.dictionaryRepresentation
            t2 = DispatchTime.now().uptimeNanoseconds
            walk(dict: dict, depth: 0, into: &nodes, count: &count)
        } else {
            t2 = DispatchTime.now().uptimeNanoseconds
            walk(root, depth: 0, into: &nodes, count: &count)
        }
        out.u32(count)
        out.u32(UInt32((t2 - t) / 1000))
        out.u32(micros(since: t2))
        out.data.append(nodes.data)
    }

    private func walk(_ s: XCUIElementSnapshot, depth: Int, into w: inout Writer, count: inout UInt32) {
        node(depth: depth, frame: s.frame, enabled: s.isEnabled, focused: s.hasFocus, selected: s.isSelected,
             value: s.value.map { "\($0)" } ?? "", label: s.label, identifier: s.identifier,
             type: s.elementType.rawValue, placeholder: s.placeholderValue ?? "", title: s.title, into: &w)
        count += 1
        for c in s.children { walk(c, depth: depth + 1, into: &w, count: &count) }
    }

    private func walk(dict d: [XCUIElement.AttributeName: Any], depth: Int, into w: inout Writer, count: inout UInt32) {
        let f = d[.frame] as? [String: Any]
        let frame = CGRect(x: f?["X"] as? Double ?? 0, y: f?["Y"] as? Double ?? 0,
                           width: f?["Width"] as? Double ?? 0, height: f?["Height"] as? Double ?? 0)
        node(depth: depth, frame: frame, enabled: d[.enabled] as? Bool ?? false, focused: d[.hasFocus] as? Bool ?? false,
             selected: d[.selected] as? Bool ?? false, value: d[.value].map { "\($0)" } ?? "",
             label: d[.label] as? String ?? "", identifier: d[.identifier] as? String ?? "",
             type: UInt(d[.elementType] as? Int ?? 0), placeholder: d[.placeholderValue] as? String ?? "",
             title: d[.title] as? String ?? "", into: &w)
        count += 1
        for c in d[.children] as? [[XCUIElement.AttributeName: Any]] ?? [] {
            walk(dict: c, depth: depth + 1, into: &w, count: &count)
        }
    }

    private func node(depth: Int, frame: CGRect, enabled: Bool, focused: Bool, selected: Bool, value: String,
                      label: String, identifier: String, type: UInt, placeholder: String, title: String,
                      into w: inout Writer) {
        w.u16(UInt16(min(depth, 0xffff)))
        let ok = frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
        let r = ok ? frame : .zero
        w.i32(Int32(clamping: Int(r.minX.rounded()))); w.i32(Int32(clamping: Int(r.minY.rounded())))
        w.i32(Int32(clamping: Int(r.maxX.rounded()))); w.i32(Int32(clamping: Int(r.maxY.rounded())))
        w.u8((enabled ? 2 : 0) | (focused ? 4 : 0) | (selected ? 64 : 0))
        w.str(value); w.str(label); w.str(identifier); w.str(String(type)); w.str(placeholder); w.str(title)
    }

    private func query(_ text: String, mode: UInt8, out: inout Writer) {
        let predicate = NSPredicate(format: "label ==[c] %@ OR identifier ==[c] %@ OR value ==[c] %@", text, text, text)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        var frame = CGRect.zero
        var found = false
        switch mode {
        case 1:
            if let s = try? element.snapshot() { frame = s.frame; found = true }
        case 2:
            found = element.exists
        default:
            found = element.exists
            if found { frame = element.frame }
        }
        out.u8(found ? 1 : 0)
        out.i32(Int32(clamping: Int(frame.minX))); out.i32(Int32(clamping: Int(frame.minY)))
        out.i32(Int32(clamping: Int(frame.maxX))); out.i32(Int32(clamping: Int(frame.maxY)))
    }

    private func idle(mode: UInt8, timeoutMs: Int, out: inout Writer) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + UInt64(timeoutMs) * 1_000_000
        let lastActionNs = input.lastActionNs
        var ok = false
        var checks: UInt32 = 0
        var changedAt = lastActionNs
        var changes: UInt32 = 0, rows = (top: 0, bottom: 0)
        var firstChangeAt: UInt64 = 0
        switch mode {
        case 0:
            try Private.waitForQuiescence(app)
            ok = true
            checks = 1
            changedAt = DispatchTime.now().uptimeNanoseconds
        case 1:
            while DispatchTime.now().uptimeNanoseconds < deadline {
                checks += 1
                let a = SHA256.hash(data: XCUIScreen.main.screenshot().pngRepresentation)
                let b = SHA256.hash(data: XCUIScreen.main.screenshot().pngRepresentation)
                if a == b { ok = true; break }
            }
            changedAt = DispatchTime.now().uptimeNanoseconds
        default:
            var previous: Pixels?
            while DispatchTime.now().uptimeNanoseconds < deadline {
                checks += 1
                let pixels = rawPixels(XCUIScreen.main.screenshot())
                if let previous, let changed = changedRows(previous, pixels) {
                    changedAt = DispatchTime.now().uptimeNanoseconds
                    if firstChangeAt == 0 { firstChangeAt = changedAt }
                    changes += 1
                    rows = changed
                }
                previous = pixels
            }
            ok = true
        }
        out.u8(ok ? 1 : 0)
        out.u32(changedAt > lastActionNs ? UInt32(clamping: (changedAt - lastActionNs) / 1000) : 0)
        out.u32(micros(since: start))
        out.u32(checks)
        out.u32(changes)
        out.u32(UInt32(rows.top)); out.u32(UInt32(rows.bottom))
        out.u32(firstChangeAt > lastActionNs ? UInt32(clamping: (firstChangeAt - lastActionNs) / 1000) : 0)
    }

    /// First and last pixel rows that differ (screen pixels, from the top), nil if none. Only
    /// the image bytes of each row count: the padding after them is leftover memory.
    private func changedRows(_ a: Pixels, _ b: Pixels) -> (top: Int, bottom: Int)? {
        guard a.data.count == b.data.count, a.bytesPerRow == b.bytesPerRow, a.bytesPerRow > 0 else {
            return a.data == b.data ? nil : (0, 0)
        }
        var top = -1, bottom = -1
        a.data.withUnsafeBytes { pa in
            b.data.withUnsafeBytes { pb in
                for row in 0..<(a.data.count / a.bytesPerRow)
                where memcmp(pa.baseAddress! + row * a.bytesPerRow, pb.baseAddress! + row * a.bytesPerRow, a.rowBytes) != 0 {
                    if top < 0 { top = row }
                    bottom = row
                }
            }
        }
        return top < 0 ? nil : (top, bottom)
    }

    private struct Pixels {
        let data: Data
        let bytesPerRow: Int // row stride
        let rowBytes: Int // image bytes in a row
    }

    private func rawPixels(_ shot: XCUIScreenshot) -> Pixels {
        guard let image = shot.image.cgImage, let data = image.dataProvider?.data else {
            return Pixels(data: shot.pngRepresentation, bytesPerRow: 0, rowBytes: 0)
        }
        return Pixels(data: data as Data, bytesPerRow: image.bytesPerRow, rowBytes: image.width * image.bitsPerPixel / 8)
    }
}
