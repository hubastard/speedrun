// SCREEN: the hierarchy flows' selectors match against on iOS: the foreground app, then
// SpringBoard's status bars, each a root at depth 0, every node with this attribute mapping:
//   text = title, or value when the title is empty; desc = label; id = identifier;
//   hint = placeholder; checked = a checkbox, switch or toggle whose value is "1".
// Frames are in points. The status bars cost as much as the app's own snapshot and change
// with the clock or the battery only, so they are re-read every 5 s. The app's part comes
// from SETTLE's last snapshot when no action happened since and it is under 1 s old: settle
// has just seen the screen hold still, and the flow reads it right away. iOS has no "visible
// to user" attribute: every node is flagged visible and the host drops those mostly off
// screen.
// An endless animation moves a few elements on every read (a Reanimated or Animated loop, a
// marquee): the screen would never hold still. An element seen moving for restlessNs, while
// most of the screen holds still, is restless: the signature leaves its frame out, and its
// node carries the restless flag (128) so the host's hash does too. A pause of up to
// restlessPauseNs does not end its moving: a shimmer's highlight, clipped by its block,
// holds still while it is out of it (a skeleton's three highlights, one paused, kept a settle
// waiting 2.8 s instead of 1.1 s). A scroll or a screen transition moves most of the screen,
// and is waited for.
import XCTest

final class Screen {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var foregroundID = ""
    private var foreground: XCUIApplication?
    /// Signature of the foreground app's last snapshot.
    private(set) var lastSignature: Int?
    /// The signature SETTLE ended on: a read that differs (the screen changed after the settle,
    /// such as a popup presenting) says so, and the host settles before acting on it.
    var settledSignature: Int?
    /// The app's nodes from the last signature, for the next read (see above), and their
    /// accessibility elements (HIT).
    private var settled = (nodes: Writer(), count: UInt32(0), at: UInt64(0), elements: [NSObject?]())
    private static let settledMaxAgeNs: UInt64 = 1_000_000_000
    private static let statusBarsMaxAgeNs: UInt64 = 5_000_000_000
    private var statusBars = (nodes: Writer(), count: UInt32(0), at: UInt64(0), elements: [NSObject?]())
    /// The accessibility element of each node of the last SCREEN response, in its order (HIT).
    private var lastElements: [NSObject?] = []
    /// A hashed node of a walk: identity (what it is and says), frame, and where its flags byte is.
    struct Mark { var id: Int; var frame: SIMD4<Int32>; var flagsAt: Int }
    private static let restlessNs: UInt64 = 500_000_000
    private static let restlessPauseNs: UInt64 = 600_000_000
    private static let restlessFlag: UInt8 = 128
    /// The last digest's frames and, for each node moving on every read since, when it began.
    private var lastFrames: [Int: SIMD4<Int32>] = [:]
    private var movingSince: [Int: UInt64] = [:]
    /// For each node in movingSince, when its frame last changed.
    private var movedAt: [Int: UInt64] = [:]

    /// Forgets every cached read (a new client). Main thread.
    func reset() {
        lastSignature = nil
        settledSignature = nil
        settled.at = 0
        statusBars.at = 0
        lastFrames = [:]
        movingSince = [:]
        movedAt = [:]
    }

    /// lastActionNs: when the last action began (a settled snapshot older than it is stale).
    /// Response: u32 count, the nodes, then u8 1 when the app's part differs from what the
    /// last SETTLE ended on.
    func read(lastActionNs: UInt64, out: inout Writer) throws {
        var nodes = Writer()
        var count: UInt32 = 0
        var elements: [NSObject?] = []
        var changed = false
        let now = DispatchTime.now().uptimeNanoseconds
        if settled.at > lastActionNs && now - settled.at < Self.settledMaxAgeNs {
            nodes = settled.nodes
            count = settled.count
            elements = settled.elements
            settled.at = 0 // once
        } else {
            let snapshot = try snapshotForeground()
            Private.uiLandscape = snapshot.frame.width > snapshot.frame.height
            var marks: [Mark] = []
            walk(snapshot, depth: 0, into: &nodes, count: &count, marks: &marks, elements: &elements)
            lastSignature = digest(marks, nodes: &nodes)
            changed = settledSignature != nil && lastSignature != settledSignature
        }
        if statusBars.at == 0 || now - statusBars.at > Self.statusBarsMaxAgeNs {
            var bars = Writer(), barCount: UInt32 = 0, ignored: [Mark] = [], barElements: [NSObject?] = []
            for bar in (try? springboard.statusBars.allElementsBoundByIndex.map { try $0.snapshot() }) ?? [] {
                walk(bar, depth: 0, into: &bars, count: &barCount, marks: &ignored, elements: &barElements)
            }
            statusBars = (bars, barCount, now, barElements)
        }
        lastElements = elements + statusBars.elements
        out.u32(count + statusBars.count)
        out.data.append(nodes.data)
        out.data.append(statusBars.nodes.data)
        out.u8(changed ? 1 : 0)
    }

    /// A hash of the foreground app's elements (frames, labels, values, identifiers): equal
    /// hashes mean the screen did not change in any way a flow can see.
    func signature() throws -> Int {
        var nodes = Writer()
        var count: UInt32 = 0
        var marks: [Mark] = []
        var elements: [NSObject?] = []
        let snapshot = try snapshotForeground()
        Private.uiLandscape = snapshot.frame.width > snapshot.frame.height
        walk(snapshot, depth: 0, into: &nodes, count: &count, marks: &marks, elements: &elements)
        let sig = digest(marks, nodes: &nodes)
        lastSignature = sig
        settled = (nodes, count, DispatchTime.now().uptimeNanoseconds, elements)
        return sig
    }

    /// The signature of a walk's marks, restless frames left out (see the top), and the
    /// restless flag set on their nodes in `nodes`.
    private func digest(_ marks: [Mark], nodes: inout Writer) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        var ids = [Int](repeating: 0, count: marks.count)
        var seen = [Int: Int](minimumCapacity: marks.count)
        var frames = [Int: SIMD4<Int32>](minimumCapacity: marks.count)
        var moving = [Int: UInt64]()
        var moved = [Int: UInt64]()
        for (k, m) in marks.enumerated() {
            // Same identity twice (rows alike): told apart by their order.
            let n = seen[m.id, default: 0]
            seen[m.id] = n + 1
            ids[k] = n == 0 ? m.id : m.id &+ n &* 0x9E37_79B9
            frames[ids[k]] = m.frame
            if let f = lastFrames[ids[k]], f != m.frame {
                moving[ids[k]] = movingSince[ids[k]] ?? now
                moved[ids[k]] = now
            } else if let since = movingSince[ids[k]], let at = movedAt[ids[k]], now - at < Self.restlessPauseNs {
                moving[ids[k]] = since // paused: still moving
                moved[ids[k]] = at
            }
        }
        lastFrames = frames
        movingSince = moving
        movedAt = moved
        let few = moving.count * 3 <= marks.count
        var hasher = Hasher()
        for (k, m) in marks.enumerated() {
            hasher.combine(ids[k])
            if few, let since = moving[ids[k]], now - since >= Self.restlessNs {
                nodes.data[m.flagsAt] |= Self.restlessFlag
            } else {
                hasher.combine(m.frame)
            }
        }
        return hasher.finalize()
    }

    /// How long a snapshot may wait for the app (Private.setAXTimeout): a stuck one is tried
    /// again rather than waited out (~15 s by XCTest's default).
    static let axTimeoutSeconds = 2.0

    /// A snapshot of the foreground app. An app being relaunched (launchApp) can fail it
    /// ("Application ... is not running"): find the foreground app again and retry, then fall
    /// back to SpringBoard rather than failing the read. One that timed out is tried again
    /// while the app is still in the foreground, for up to snapshotBudgetSeconds: a snapshot
    /// stuck in a transition gives way to the next after axTimeoutSeconds, and an app whose
    /// main thread is busy is read once it answers (with up to three tries, an app blocked
    /// ~2 s at a time failed them all on CI, and the read with them: the host saw the
    /// connection close).
    static let snapshotBudgetSeconds = 20.0

    private func snapshotForeground() throws -> XCUIElementSnapshot {
        if let s = try? foregroundApp().snapshot() { return s }
        foreground = nil
        foregroundID = ""
        let deadline = Date().addingTimeInterval(Self.snapshotBudgetSeconds)
        repeat {
            let app = foregroundApp()
            if let s = try? app.snapshot() { return s }
            if app == springboard || app.state != .runningForeground { break }
        } while Date() < deadline
        return try springboard.snapshot()
    }

    /// After `simctl launch`: waits until the app runs in the foreground, then snapshots it once
    /// (XCTest waits there until its UI can be read), and makes it the foreground app.
    func waitLaunched(_ id: String, timeoutMs: Int) -> Bool {
        let app = XCUIApplication(bundleIdentifier: id)
        guard app.wait(for: .runningForeground, timeout: TimeInterval(timeoutMs) / 1000) else { return false }
        foreground = app
        foregroundID = id
        _ = try? app.snapshot()
        return true
    }

    /// The app in the foreground, SpringBoard when none is: XCTest's accessibility client lists
    /// the active apps (~3 ms; testmanagerd names each process once). SpringBoard alone is the
    /// home screen, or one of its alerts over the app (a permission request): SpringBoard is
    /// read then, which shows the alert, and a notification request is answered there.
    /// The last app found is kept while it is listed.
    func foregroundApp() -> XCUIApplication {
        let active = Private.activeBundleIDs()
        if active == ["com.apple.springboard"] {
            foreground = nil
            foregroundID = ""
            return springboard
        }
        if let app = foreground {
            if active.contains(foregroundID) { return app }
            if active.isEmpty && app.state == .runningForeground { return app } // no list: as before
        }
        let ids = active.filter { $0 != "com.apple.springboard" }
        for id in ids {
            let app = XCUIApplication(bundleIdentifier: id)
            if ids.count > 1 && app.state != .runningForeground { continue }
            foregroundID = id
            foreground = app
            return app
        }
        foregroundID = ""
        foreground = nil
        return springboard
    }

    /// The keyboard's assistant bar (typing predictions): it updates on its own a few hundred
    /// ms after a key, so signatures leave it out (reads keep it) and a settle after typing
    /// does not wait for the suggestions.
    private static let unsettledID = "SystemInputAssistantView"

    /// React Native spells a checkbox's or radio button's role and state into its value
    /// ("checkbox, checked", "radio button, unchecked"): UIKit has no trait for them.
    private static func spelledChecked(_ value: String) -> Bool {
        let words = value.components(separatedBy: ", ")
        return words.count >= 2 && (words[0] == "checkbox" || words[0] == "radio button") && words[1] == "checked"
    }

    /// The field with the keyboard's focus. hasFocus is the focus engine's (tvOS); XCTest's
    /// snapshot keeps the keyboard's as hasKeyboardFocus. False where this Xcode lacks it.
    private static let keyboardFocusSel = NSSelectorFromString("hasKeyboardFocus")
    private static func keyboardFocused(_ s: XCUIElementSnapshot) -> Bool {
        switch s.elementType {
        case .textField, .secureTextField, .searchField, .textView: break
        default: return false
        }
        guard let o = s as? NSObject, o.responds(to: keyboardFocusSel) else { return false }
        typealias Get = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(o.method(for: keyboardFocusSel), to: Get.self)(o, keyboardFocusSel)
    }

    private static let accessibilityElementSel = NSSelectorFromString("accessibilityElement")

    private func walk(_ s: XCUIElementSnapshot, depth: Int, into w: inout Writer, count: inout UInt32, marks: inout [Mark],
                      elements: inout [NSObject?], hashed: Bool = true) {
        let value = s.value as? String ?? ""
        let text = s.title.isEmpty ? value : s.title
        let checkable = s.elementType == .checkBox || s.elementType == .switch || s.elementType == .toggle
        var flags: UInt8 = 32 // visible
        if s.isEnabled { flags |= 2 }
        if s.hasFocus || Self.keyboardFocused(s) { flags |= 4 }
        if (checkable && value == "1") || Self.spelledChecked(value) { flags |= 16 }
        if s.isSelected { flags |= 64 }
        let f = s.frame
        let finite = f.origin.x.isFinite && f.origin.y.isFinite && f.width.isFinite && f.height.isFinite
        let r = finite ? f : .zero
        let l = Int32(clamping: Int(r.minX.rounded())), t = Int32(clamping: Int(r.minY.rounded()))
        let rr = Int32(clamping: Int(r.maxX.rounded())), b = Int32(clamping: Int(r.maxY.rounded()))

        w.u16(UInt16(min(depth, 0xffff)))
        w.i32(l); w.i32(t); w.i32(rr); w.i32(b)
        let flagsAt = w.data.count
        w.u8(flags)
        w.str(text); w.str(s.label); w.str(s.identifier); w.str(Self.typeName(s.elementType))
        w.str(s.placeholderValue ?? ""); w.str("")
        count += 1
        let o = s as? NSObject
        elements.append(o?.responds(to: Self.accessibilityElementSel) == true ? o?.perform(Self.accessibilityElementSel)?.takeUnretainedValue() as? NSObject : nil)
        let hashed = hashed && s.identifier != Self.unsettledID
        if hashed {
            var id = Hasher()
            id.combine(depth); id.combine(s.elementType.rawValue); id.combine(flags)
            id.combine(text); id.combine(s.label); id.combine(s.identifier)
            marks.append(Mark(id: id.finalize(), frame: SIMD4(l, t, rr, b), flagsAt: flagsAt))
        }

        for c in s.children { walk(c, depth: depth + 1, into: &w, count: &count, marks: &marks, elements: &elements, hashed: hashed) }
    }

    /// HIT: the node of the last SCREEN response that a touch at the point reaches, as XCTest's
    /// isHittable finds out (the accessibility hit test): -1 when none of them (or the hit test
    /// failed). Main thread.
    func hit(x: Int32, y: Int32) -> Int32 {
        guard let app = lastElements.first ?? nil,
              let element = Private.elementAt(CGPoint(x: Int(x), y: Int(y)), in: app) else { return -1 }
        for (k, e) in lastElements.enumerated() where e?.isEqual(element) == true { return Int32(k) }
        return -1
    }

    private static func typeName(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .application: return "Application"
        case .window: return "Window"
        case .other: return "Other"
        case .group: return "Group"
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .searchField: return "SearchField"
        case .textView: return "TextView"
        case .image: return "Image"
        case .cell: return "Cell"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .scrollView: return "ScrollView"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .statusBar: return "StatusBar"
        case .switch: return "Switch"
        case .toggle: return "Toggle"
        case .checkBox: return "CheckBox"
        case .keyboard: return "Keyboard"
        case .key: return "Key"
        case .link: return "Link"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .webView: return "WebView"
        case .activityIndicator: return "ActivityIndicator"
        case .progressIndicator: return "ProgressIndicator"
        default: return "ElementType\(t.rawValue)"
        }
    }
}
