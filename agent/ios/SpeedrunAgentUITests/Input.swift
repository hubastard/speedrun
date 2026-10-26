// Taps, swipes, typing and keys, synthesized through testmanagerd as Maestro's runner does
// (no XCTest waits for the app to go idle around them). Every action sets lastActionNs before
// its event is sent: SETTLE measures from there.
import XCTest

final class Input {
    /// Maestro's tap: a touch held for EventRecord.defaultTapDuration (100 ms).
    static let tapHoldMs: Int32 = 100
    /// After the first character, iOS can drop the next ones while the keyboard reacts to it
    /// (Maestro: "characters after the first one are often skipped"). Maestro waits 500 ms;
    /// this waits until the focused field shows a change, at most that long.
    static let firstCharacterWaitMs = 500
    /// Typing rate after the first character. Maestro types at 30/s; 100/s (and up to 300/s)
    /// lost no character in Settings' search field (agent/ios/spike/typing.py).
    static let charactersPerSecond = 100
    static let maestroCharactersPerSecond = 30
    /// Response field inject_path: XCTest-synthesized event (Android uses 0-2), or nothing
    /// sent (deleting from an empty field).
    static let injectPath: UInt8 = 3
    static let injectNone: UInt8 = 255

    private(set) var lastActionNs = DispatchTime.now().uptimeNanoseconds
    /// The last action was a swipe: its content stops at lift-up (no fling).
    private(set) var lastWasSwipe = false

    func mark() {
        lastActionNs = DispatchTime.now().uptimeNanoseconds
        lastWasSwipe = false
    }

    func tap(x: Int32, y: Int32, holdMs: Int32 = tapHoldMs, out: inout Writer) throws {
        mark()
        let t = DispatchTime.now().uptimeNanoseconds
        try Private.tap(at: CGPoint(x: Int(x), y: Int(y)), hold: TimeInterval(max(holdMs, 0)) / 1000)
        Self.action(inject: micros(since: t), out: &out)
    }

    /// Maestro's swipe (EventRecord.addSwipeEvent): a touch that rests 100 ms, glides to the
    /// end over the duration and lifts there still moving, so content flings on at the glide's
    /// speed (scrollUntilVisible's 601 ms over 350 points: ~540 points, still after ~2.6 s,
    /// UIKit and React Native alike).
    func swipe(from a: (Int32, Int32), to b: (Int32, Int32), durationMs: Int32, out: inout Writer) throws {
        mark()
        lastWasSwipe = true
        let t = DispatchTime.now().uptimeNanoseconds
        try Private.swipe(from: CGPoint(x: Int(a.0), y: Int(a.1)), to: CGPoint(x: Int(b.0), y: Int(b.1)),
                          duration: TimeInterval(max(durationMs, 0)) / 1000)
        Self.action(inject: micros(since: t), out: &out)
    }

    /// The drag that does not fling: content stops when the touch lifts. Momentum comes from
    /// the speed of the touch's last moves (a touch that rests sends no events, so resting
    /// before the lift does not help), so the drag ends slowly: dragKick points in dragKickMs
    /// (at full speed the list starts following ~100 points late), the rest but the last
    /// dragTail points in dragFastMs, those at 200 points/s (UIKit flung once in three tries
    /// at 250, React Native at 333 and with a 125 ms tail). 350 points scroll 250-340 in
    /// 390 ms. The content is still ~50 ms after the lift, testmanagerd confirms ~250 ms
    /// after it: the drag returns dragDoneMs after the lift (Private.confirmPending).
    static let dragKick = 12.0, dragKickMs = 40.0, dragFastMs = 150.0, dragTail = 40.0, dragTailMs = 200.0
    static let dragDoneMs = 100.0

    func drag(from a: (Int32, Int32), to b: (Int32, Int32), out: inout Writer) throws {
        mark()
        lastWasSwipe = true
        let t = DispatchTime.now().uptimeNanoseconds
        let start = CGPoint(x: Int(a.0), y: Int(a.1)), end = CGPoint(x: Int(b.0), y: Int(b.1))
        let dx = end.x - start.x, dy = end.y - start.y, length = max(hypot(dx, dy), 1)
        let kick = min(Self.dragKick, length / 10), tail = min(Self.dragTail, length / 4)
        func along(_ d: Double) -> CGPoint { CGPoint(x: start.x + dx * d / length, y: start.y + dy * d / length) }
        let kickS = Self.dragKickMs / 1000, fastS = Self.dragFastMs / 1000, tailS = Self.dragTailMs / 1000
        let points: [(point: CGPoint, offset: TimeInterval, duration: TimeInterval)] = [
            (start, 0, 0), (along(kick), 0, kickS), (along(length - tail), kickS, fastS), (end, kickS + fastS, tailS),
        ]
        let liftAt = kickS + fastS + tailS
        if try Private.drag(through: points, liftAt: liftAt, wait: false) {
            Thread.sleep(until: Date(timeIntervalSinceNow: liftAt + Self.dragDoneMs / 1000 - Double(micros(since: t)) / 1e6))
        } else {
            // An Xcode without explicit move events: Maestro's swipe, slow enough not to fling.
            try Private.swipe(from: start, to: end, duration: length / 250)
        }
        Self.action(inject: micros(since: t), out: &out)
    }

    /// Text through the keyboard of the focused field ("\u{8}" deletes): the first character
    /// alone, then the rest at Maestro's rate once the field has taken the first one.
    func type(_ text: String, screen: Screen, out: inout Writer) throws {
        let typed = try type(text, screen: screen, firstRate: 30, restRate: Self.charactersPerSecond, waitCapMs: Self.firstCharacterWaitMs)
        Self.action(inject: typed ? micros(since: lastActionNs) : 0, path: typed ? Self.injectPath : Self.injectNone, out: &out)
    }

    /// The typing itself, with its knobs (the spike's TYPE_TEST tries other values). False when
    /// there was nothing to type: no action happened.
    @discardableResult
    func type(_ text: String, screen: Screen, firstRate: Int, restRate: Int, waitCapMs: Int) throws -> Bool {
        let field = onMain { Self.focusedField(screen) }
        var text = text
        // No more DELs than the field holds characters: its value's length (the placeholder's
        // when it shows one), an upper bound wherever the cursor is. None from an empty field.
        if text.allSatisfy({ $0 == "\u{8}" }), let field, field.elementType != .secureTextField,
           let value = field.value as? String {
            text = String(text.prefix(value.count))
        }
        guard let first = text.first else { return false }
        mark()
        let before = field.map(Self.shownValue)
        // Deleting from an empty field changes nothing: no change to wait for, so one event.
        if text.allSatisfy({ $0 == "\u{8}" }) && (before?.isEmpty ?? true) {
            try Private.typeText(text, charactersPerSecond: restRate)
            return true
        }
        try Private.typeText(String(first), charactersPerSecond: firstRate)
        let rest = String(text.dropFirst())
        guard !rest.isEmpty else { return true }
        guard before != nil else {
            // No focused element reports its value (React Native groups a field with its
            // label): nothing to watch, so Maestro's pacing, its fixed wait and its rate.
            Thread.sleep(forTimeInterval: Double(Self.firstCharacterWaitMs) / 1000)
            try Private.typeText(rest, charactersPerSecond: Self.maestroCharactersPerSecond)
            return true
        }
        let cap = waitCapMs
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(cap, 0)) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let now = onMain({ Self.focusedField(screen).map(Self.shownValue) }), now != before { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try Private.typeText(rest, charactersPerSecond: restRate)
        return true
    }

    /// Android key codes, mapped as Maestro's IOSDriver.pressKey does; other keys (back
    /// included) do nothing on iOS.
    func key(_ code: Int32, out: inout Writer) throws {
        try Private.confirmPending()
        mark()
        let t = DispatchTime.now().uptimeNanoseconds
        switch code {
        case 66: try Private.typeText("\n", charactersPerSecond: Self.charactersPerSecond) // ENTER: return
        case 67: try Private.typeText("\u{8}", charactersPerSecond: Self.charactersPerSecond) // DEL: delete
        case 3: onMain { XCUIDevice.shared.press(.home) } // HOME
        case 26: try onMain { try Private.pressLock() } // POWER: lock
        default: break
        }
        Self.action(inject: micros(since: t), out: &out)
    }

    /// The element with keyboard focus (nil when none reports it). `exists` first: a snapshot
    /// of a query that matches nothing retries for ~2.5 s. Main thread.
    private static func focusedField(_ screen: Screen) -> XCUIElementSnapshot? {
        let focused = screen.foregroundApp().descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == YES")).firstMatch
        guard focused.exists else { return nil }
        return try? focused.snapshot()
    }

    /// A field's value, "" when it only shows its placeholder.
    private static func shownValue(_ field: XCUIElementSnapshot) -> String {
        let value = field.value as? String ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// Action response: u32 prep_us, u32 inject_us, u8 inject_path.
    private static func action(inject: UInt32, path: UInt8 = injectPath, out: inout Writer) {
        out.u32(0)
        out.u32(inject)
        out.u8(path)
    }
}
