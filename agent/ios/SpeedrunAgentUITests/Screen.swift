// SCREEN: the hierarchy Maestro matches selectors against on iOS (its runner's
// ViewHierarchyHandler): the foreground app, then SpringBoard's status bars, each a root at
// depth 0, every node with Maestro's attribute mapping (IOSDriver.mapViewHierarchy):
//   text = title, or value when the title is empty; desc = label; id = identifier;
//   hint = placeholder; checked = a checkbox, switch or toggle whose value is "1".
// Frames are in points, as Maestro reports them. The status bars cost as much as the app's
// own snapshot and change with the clock or the battery only, so they are re-read every 5 s.
// The app's part comes from SETTLE's last snapshot when no action happened since and it is
// under 1 s old: settle has just seen the screen hold still, and the flow reads it right away. iOS has no "visible to user" attribute:
// every node is flagged visible and the host drops those mostly off screen, as Maestro does.
import XCTest

final class Screen {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var foregroundID = ""
    private var foreground: XCUIApplication?
    /// Signature of the foreground app's last snapshot.
    private(set) var lastSignature: Int?
    /// The app's nodes from the last signature, for the next read (see above).
    private var settled = (nodes: Writer(), count: UInt32(0), at: UInt64(0))
    private static let settledMaxAgeNs: UInt64 = 1_000_000_000
    private static let statusBarsMaxAgeNs: UInt64 = 5_000_000_000
    private var statusBars = (nodes: Writer(), count: UInt32(0), at: UInt64(0))

    /// Forgets every cached read (a new client). Main thread.
    func reset() {
        lastSignature = nil
        settled.at = 0
        statusBars.at = 0
    }

    /// lastActionNs: when the last action began (a settled snapshot older than it is stale).
    func read(lastActionNs: UInt64, out: inout Writer) throws {
        var nodes = Writer()
        var count: UInt32 = 0
        let now = DispatchTime.now().uptimeNanoseconds
        if settled.at > lastActionNs && now - settled.at < Self.settledMaxAgeNs {
            nodes = settled.nodes
            count = settled.count
            settled.at = 0 // once
        } else {
            let snapshot = try snapshotForeground()
            var hasher = Hasher()
            walk(snapshot, depth: 0, into: &nodes, count: &count, hasher: &hasher)
            lastSignature = hasher.finalize()
        }
        if statusBars.at == 0 || now - statusBars.at > Self.statusBarsMaxAgeNs {
            var bars = Writer(), barCount: UInt32 = 0, ignored = Hasher()
            for bar in (try? springboard.statusBars.allElementsBoundByIndex.map { try $0.snapshot() }) ?? [] {
                walk(bar, depth: 0, into: &bars, count: &barCount, hasher: &ignored)
            }
            statusBars = (bars, barCount, now)
        }
        out.u32(count + statusBars.count)
        out.data.append(nodes.data)
        out.data.append(statusBars.nodes.data)
    }

    /// A hash of the foreground app's elements (frames, labels, values, identifiers): equal
    /// hashes mean the screen did not change in any way a flow can see.
    func signature() throws -> Int {
        var hasher = Hasher()
        var nodes = Writer()
        var count: UInt32 = 0
        walk(try snapshotForeground(), depth: 0, into: &nodes, count: &count, hasher: &hasher)
        let sig = hasher.finalize()
        lastSignature = sig
        settled = (nodes, count, DispatchTime.now().uptimeNanoseconds)
        return sig
    }

    /// A snapshot of the foreground app. An app being relaunched (launchApp) can fail it
    /// ("Application ... is not running"): find the foreground app again and retry once, then
    /// fall back to SpringBoard rather than failing the read.
    private func snapshotForeground() throws -> XCUIElementSnapshot {
        if let s = try? foregroundApp().snapshot() { return s }
        foreground = nil
        foregroundID = ""
        if let s = try? foregroundApp().snapshot() { return s }
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

    /// The app in the foreground, SpringBoard when none is (home screen). The last one found
    /// is checked first (one state query); otherwise XCTest's accessibility client lists the
    /// active apps and testmanagerd names them.
    func foregroundApp() -> XCUIApplication {
        if let app = foreground, app.state == .runningForeground { return app }
        let ids = Private.activeBundleIDs().filter { $0 != "com.apple.springboard" }
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

    private func walk(_ s: XCUIElementSnapshot, depth: Int, into w: inout Writer, count: inout UInt32, hasher: inout Hasher) {
        let value = s.value as? String ?? ""
        let text = s.title.isEmpty ? value : s.title
        let checkable = s.elementType == .checkBox || s.elementType == .switch || s.elementType == .toggle
        var flags: UInt8 = 32 // visible
        if s.isEnabled { flags |= 2 }
        if s.hasFocus { flags |= 4 }
        if checkable && value == "1" { flags |= 16 }
        if s.isSelected { flags |= 64 }
        let f = s.frame
        let finite = f.origin.x.isFinite && f.origin.y.isFinite && f.width.isFinite && f.height.isFinite
        let r = finite ? f : .zero
        let l = Int32(clamping: Int(r.minX.rounded())), t = Int32(clamping: Int(r.minY.rounded()))
        let rr = Int32(clamping: Int(r.maxX.rounded())), b = Int32(clamping: Int(r.maxY.rounded()))

        w.u16(UInt16(min(depth, 0xffff)))
        w.i32(l); w.i32(t); w.i32(rr); w.i32(b)
        w.u8(flags)
        w.str(text); w.str(s.label); w.str(s.identifier); w.str(Self.typeName(s.elementType))
        w.str(s.placeholderValue ?? ""); w.str("")
        count += 1
        hasher.combine(depth); hasher.combine(l); hasher.combine(t); hasher.combine(rr); hasher.combine(b)
        hasher.combine(flags); hasher.combine(text); hasher.combine(s.label); hasher.combine(s.identifier)

        for c in s.children { walk(c, depth: depth + 1, into: &w, count: &count, hasher: &hasher) }
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
        default: return "ElementType\(t.rawValue)"
        }
    }
}
