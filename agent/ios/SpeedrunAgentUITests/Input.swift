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
    /// Response field inject_path: XCTest-synthesized event (Android uses 0-2).
    static let injectPath: UInt8 = 3

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

    /// Maestro's swipe (EventRecord.addSwipeEvent): down at the start, at the end 100 ms later,
    /// held there for the duration, then up. The hold is kept whole: how far content scrolls
    /// depends on it (a React Native list moved 510, 700 and 1200 points with 601, 300 and
    /// 100 ms holds; UIKit Settings 480 with each).
    func swipe(from a: (Int32, Int32), to b: (Int32, Int32), durationMs: Int32, out: inout Writer) throws {
        mark()
        lastWasSwipe = true
        let t = DispatchTime.now().uptimeNanoseconds
        try Private.swipe(from: CGPoint(x: Int(a.0), y: Int(a.1)), to: CGPoint(x: Int(b.0), y: Int(b.1)),
                          duration: TimeInterval(max(durationMs, 0)) / 1000)
        Self.action(inject: micros(since: t), out: &out)
    }

    /// Text through the keyboard of the focused field ("\u{8}" deletes): the first character
    /// alone, then the rest at Maestro's rate once the field has taken the first one.
    func type(_ text: String, screen: Screen, out: inout Writer) throws {
        try type(text, screen: screen, firstRate: 30, restRate: Self.charactersPerSecond, waitCapMs: Self.firstCharacterWaitMs)
        Self.action(inject: micros(since: lastActionNs), out: &out)
    }

    /// The typing itself, with its knobs (the spike's TYPE_TEST tries other values).
    func type(_ text: String, screen: Screen, firstRate: Int, restRate: Int, waitCapMs: Int) throws {
        mark()
        guard let first = text.first else { return }
        let before = onMain { Self.focusedValue(screen) }
        // Deleting from an empty field changes nothing: no change to wait for, so one event.
        if text.allSatisfy({ $0 == "\u{8}" }) && (before?.isEmpty ?? true) {
            try Private.typeText(text, charactersPerSecond: restRate)
            return
        }
        try Private.typeText(String(first), charactersPerSecond: firstRate)
        let rest = String(text.dropFirst())
        guard !rest.isEmpty else { return }
        guard before != nil else {
            // No focused element reports its value (React Native groups a field with its
            // label): nothing to watch, so Maestro's pacing, its fixed wait and its rate.
            Thread.sleep(forTimeInterval: Double(Self.firstCharacterWaitMs) / 1000)
            try Private.typeText(rest, charactersPerSecond: Self.maestroCharactersPerSecond)
            return
        }
        let cap = waitCapMs
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(cap, 0)) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let now = onMain({ Self.focusedValue(screen) }), now != before { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try Private.typeText(rest, charactersPerSecond: restRate)
    }

    /// Android key codes, mapped as Maestro's IOSDriver.pressKey does; other keys (back
    /// included) do nothing on iOS.
    func key(_ code: Int32, out: inout Writer) throws {
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

    /// The focused element's value, "" when it only shows its placeholder (nil when no element
    /// reports keyboard focus). `exists` first: a snapshot of a query that matches nothing
    /// retries for ~2.5 s. Main thread.
    private static func focusedValue(_ screen: Screen) -> String? {
        let focused = screen.foregroundApp().descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == YES")).firstMatch
        guard focused.exists, let snapshot = try? focused.snapshot() else { return nil }
        let value = snapshot.value as? String ?? ""
        return value == snapshot.placeholderValue ? "" : value
    }

    /// Action response: u32 prep_us, u32 inject_us, u8 inject_path.
    private static func action(inject: UInt32, out: inout Writer) {
        out.u32(0)
        out.u32(inject)
        out.u8(injectPath)
    }
}
