// XCTest's private API, reached through the Objective-C runtime. Every entry point is looked
// up before use: a missing one is an error naming it, never a crash, so a new Xcode that
// renames something degrades into a clear message.
import XCTest

enum Private {
    /// Instance and class methods of an Objective-C class, for finding what an Xcode offers.
    static func methods(of className: String) -> [String] {
        guard let cls = NSClassFromString(className) else { return ["(no class \(className))"] }
        var out: [String] = []
        let classes: [(AnyClass, String)] = [(cls, "-"), (object_getClass(cls)!, "+")]
        for (target, prefix) in classes {
            var count: UInt32 = 0
            if let list = class_copyMethodList(target, &count) {
                for i in 0..<Int(count) { out.append(prefix + NSStringFromSelector(method_getName(list[i]))) }
                free(list)
            }
        }
        return out.sorted()
    }

    /// testmanagerd's proxy: it synthesizes events and types text without XCTest's waits for
    /// the app to go idle (XCUIElement.tap() and typeText() wait before and after).
    static func daemonProxy() throws -> NSObject {
        guard let cls = NSClassFromString("XCTRunnerDaemonSession") else {
            throw AgentError(message: "XCTRunnerDaemonSession is missing")
        }
        let shared = NSSelectorFromString("sharedSession")
        guard let session = (cls as AnyObject).perform(shared)?.takeUnretainedValue() as? NSObject,
              let proxy = session.perform(NSSelectorFromString("daemonProxy"))?.takeUnretainedValue() as? NSObject
        else { throw AgentError(message: "XCTRunnerDaemonSession.sharedSession.daemonProxy is missing") }
        return proxy
    }

    /// The device's orientation (ORIENTATION sets it) and whether the foreground app's UI is
    /// laid out in landscape (its last snapshot is wider than tall: an app that supports
    /// portrait only stays upright when the device turns). Touches come in the UI's points
    /// and are played in the hardware's, which are portrait.
    static var deviceOrientation: UIDeviceOrientation = .portrait
    static var uiLandscape = false

    /// The orientation the simulator is in now (it outlives the agent). Main thread.
    static func readOrientation() {
        let o = XCUIDevice.shared.orientation
        deviceOrientation = o == .unknown ? .portrait : o
    }

    private static func hardwarePoint(_ p: CGPoint) -> CGPoint {
        guard uiLandscape else { return p }
        let screen = UIScreen.main
        let w = screen.nativeBounds.width / screen.nativeScale, h = screen.nativeBounds.height / screen.nativeScale
        // The UI turns opposite to the device: home button (or bottom) on the right for
        // landscapeLeft.
        if deviceOrientation == .landscapeRight { return CGPoint(x: p.y, y: h - p.x) }
        return CGPoint(x: w - p.y, y: p.x)
    }

    /// A touch at point (screen points) held for hold seconds, played by testmanagerd; returns
    /// once it has been delivered (or right away when wait is false).
    static func tap(at point: CGPoint, hold: TimeInterval, wait: Bool = true) throws {
        let path = try touchPath(at: point)
        try call(path, "liftUpAtOffset:", hold)
        try synthesize(try record(with: path), wait: wait)
    }

    /// `count` taps at a point, one every `interval`, each held `hold`, as one event record with
    /// a finger per tap. One record per tap would wait ~230 ms between them for testmanagerd's
    /// confirmation (a second synthesis before it crashes the runner); a second press on one
    /// path does not land as a tap.
    static func taps(at point: CGPoint, count: Int, interval: TimeInterval, hold: TimeInterval) throws {
        var paths: [NSObject] = []
        for k in 0..<max(count, 1) {
            let offset = Double(k) * interval
            let path = try touchPath(at: point, offset: offset)
            try call(path, "liftUpAtOffset:", offset + hold)
            paths.append(path)
        }
        try synthesize(try record(with: paths))
    }

    /// The flow format's swipe: down at start, a move to end at 100 ms, up
    /// at 100 ms + duration. testmanagerd plays a move from its offset until the next event,
    /// so the touch rests 100 ms, then glides to end over the whole duration and lifts while
    /// still moving.
    static func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) throws {
        let path = try touchPath(at: start)
        let move = NSSelectorFromString("moveToPoint:atOffset:")
        guard path.responds(to: move) else { throw AgentError(message: "XCPointerEventPath.moveToPoint:atOffset: is missing") }
        typealias Move = @convention(c) (NSObject, Selector, CGPoint, TimeInterval) -> Void
        unsafeBitCast(path.method(for: move), to: Move.self)(path, move, hardwarePoint(end), 0.1)
        try call(path, "liftUpAtOffset:", 0.1 + duration)
        try synthesize(try record(with: path))
    }

    /// A touch down at points[0] that moves through the others, each move starting at its
    /// offset and lasting its duration (seconds), and lifts at the last point at liftAt. The
    /// moves are explicit XCPointerEvents: moveToPoint:atOffset: glides on until the next
    /// event, so a touch would never rest. False when this Xcode lacks the API.
    static func drag(through points: [(point: CGPoint, offset: TimeInterval, duration: TimeInterval)],
                     liftAt: TimeInterval, wait: Bool = true) throws -> Bool {
        let makeSel = NSSelectorFromString("moveEventWithStartPoint:destination:offset:duration:")
        let addSel = NSSelectorFromString("_addPointerEvent:")
        guard let eventClass = NSClassFromString("XCPointerEvent"), let make = class_getClassMethod(eventClass, makeSel),
              let first = points.first, let last = points.last else { return false }
        let path = try touchPath(at: first.point)
        guard path.responds(to: addSel) else { return false }
        typealias Make = @convention(c) (AnyClass, Selector, CGPoint, CGPoint, TimeInterval, TimeInterval) -> NSObject
        typealias Add = @convention(c) (NSObject, Selector, NSObject) -> Void
        let makeMove = unsafeBitCast(method_getImplementation(make), to: Make.self)
        let add = unsafeBitCast(path.method(for: addSel), to: Add.self)
        for (from, to) in zip(points, points.dropFirst()) {
            add(path, addSel, makeMove(eventClass, makeSel, hardwarePoint(from.point), hardwarePoint(to.point), to.offset, to.duration))
        }
        // The lift: liftUpAtOffset: lifts where the path's last moveToPoint went (here, the
        // start), so take it from a path that is at the end point.
        let liftPath = try touchPath(at: last.point)
        try call(liftPath, "liftUpAtOffset:", liftAt)
        let eventsSel = NSSelectorFromString("pointerEvents")
        guard liftPath.responds(to: eventsSel),
              let lift = (liftPath.perform(eventsSel)?.takeUnretainedValue() as? [NSObject])?.last else { return false }
        add(path, addSel, lift)
        try synthesize(try record(with: path), wait: wait)
        return true
    }

    /// Text typed through the keyboard as key events (XCPointerEventPath typeText), at
    /// charactersPerSecond; with wait false, returns once sent (see unconfirmed).
    static func typeText(_ text: String, charactersPerSecond: Int, wait: Bool = true) throws {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else {
            throw AgentError(message: "XCPointerEventPath is missing")
        }
        let initText = NSSelectorFromString("initForTextInput")
        let alloc = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        guard alloc.responds(to: initText) else { throw AgentError(message: "XCPointerEventPath.initForTextInput is missing") }
        let path = alloc.perform(initText).takeUnretainedValue() as! NSObject
        let type = NSSelectorFromString("typeText:atOffset:typingSpeed:shouldRedact:")
        guard path.responds(to: type) else {
            throw AgentError(message: "XCPointerEventPath.typeText:atOffset:typingSpeed:shouldRedact: is missing")
        }
        typealias TypeText = @convention(c) (NSObject, Selector, NSString, TimeInterval, UInt64, Bool) -> Void
        unsafeBitCast(path.method(for: type), to: TypeText.self)(path, type, text as NSString, 0, UInt64(max(charactersPerSecond, 1)), false)
        try synthesize(try record(with: path), wait: wait)
    }

    /// The side (lock) button. Main thread.
    static func pressLock() throws {
        let sel = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: sel) else { throw AgentError(message: "XCUIDevice.pressLockButton is missing") }
        XCUIDevice.shared.perform(sel)
    }

    private static func touchPath(at point: CGPoint, offset: TimeInterval = 0) throws -> NSObject {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else {
            throw AgentError(message: "XCPointerEventPath is missing")
        }
        let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
        let alloc = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        guard alloc.responds(to: initPath) else { throw AgentError(message: "XCPointerEventPath.initForTouchAtPoint:offset: is missing") }
        typealias InitPath = @convention(c) (NSObject, Selector, CGPoint, TimeInterval) -> NSObject
        return unsafeBitCast(alloc.method(for: initPath), to: InitPath.self)(alloc, initPath, hardwarePoint(point), offset)
    }

    private static func record(with path: NSObject) throws -> NSObject {
        try record(with: [path])
    }

    private static func record(with paths: [NSObject]) throws -> NSObject {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type else {
            throw AgentError(message: "XCSynthesizedEventRecord is missing")
        }
        let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        let alloc = recordClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        guard alloc.responds(to: initRecord) else {
            throw AgentError(message: "XCSynthesizedEventRecord.initWithName:interfaceOrientation: is missing")
        }
        typealias InitRecord = @convention(c) (NSObject, Selector, NSString, Int) -> NSObject
        let record = unsafeBitCast(alloc.method(for: initRecord), to: InitRecord.self)(
            alloc, initRecord, "Single-Finger Touch Action", UIInterfaceOrientation.portrait.rawValue)
        let add = NSSelectorFromString("addPointerEventPath:")
        guard record.responds(to: add) else { throw AgentError(message: "XCSynthesizedEventRecord.addPointerEventPath: is missing") }
        typealias Add = @convention(c) (NSObject, Selector, NSObject) -> Void
        for path in paths { unsafeBitCast(record.method(for: add), to: Add.self)(record, add, path) }
        return record
    }

    private static func synthesize(_ record: NSObject, wait: Bool = true) throws {
        try confirmPending()
        try callWithCompletion(try daemonProxy(), "_XCT_synthesizeEvent:completion:", record, wait: wait)
    }

    /// A synthesize not waited for: testmanagerd confirms one ~200-250 ms after its last
    /// event (on a background thread), once the app has had them all.
    private static var unconfirmed: (done: DispatchSemaphore, failure: Box)?
    private final class Box { var error: Error? }

    /// Waits for the synthesize not waited for, if any, and throws its error: before the next
    /// one, as events overlapping in time could mix.
    static func confirmPending() throws {
        guard let pending = unconfirmed else { return }
        unconfirmed = nil
        _ = pending.done.wait(timeout: .now() + 10)
        if let error = pending.failure.error { throw error }
    }

    /// Whether the synthesize not waited for, if any, is confirmed (its error thrown), without
    /// waiting: a settle concludes only once it is, so never before the last event played.
    static func pendingConfirmed() throws -> Bool {
        guard let pending = unconfirmed else { return true }
        guard pending.done.wait(timeout: .now()) == .success else { return false }
        unconfirmed = nil
        if let error = pending.failure.error { throw error }
        return true
    }

    /// target.selector(offset), for XCPointerEventPath's offset setters.
    private static func call(_ target: NSObject, _ selector: String, _ offset: TimeInterval) throws {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { throw AgentError(message: "\(String(describing: Swift.type(of: target))).\(selector) is missing") }
        typealias Call = @convention(c) (NSObject, Selector, TimeInterval) -> Void
        unsafeBitCast(target.method(for: sel), to: Call.self)(target, sel, offset)
    }

    /// Text through the focused field's keyboard, at most charsPerSecond.
    static func type(_ text: String, charsPerSecond: Int) throws {
        try confirmPending()
        let proxy = try daemonProxy()
        let sel = NSSelectorFromString("_XCT_sendString:maximumFrequency:completion:")
        guard proxy.responds(to: sel) else { throw AgentError(message: "_XCT_sendString:maximumFrequency:completion: is missing") }
        typealias Send = @convention(c) (NSObject, Selector, NSString, Int, @escaping (Error?) -> Void) -> Void
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        unsafeBitCast(proxy.method(for: sel), to: Send.self)(proxy, sel, text as NSString, charsPerSecond) {
            failure = $0
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
    }

    /// XCTest's own wait for the app to be idle: its event loop, then its animations. Must
    /// run on the main thread (it spins the run loop). XCTest gives up after 60 s, which an
    /// animation that never ends (an open context menu) takes whole: `timeout` sets XCTest's
    /// application-state timeout for this wait (_XCTSetApplicationStateTimeout, as
    /// WebDriverAgent does), restored after. Without those functions it is not bounded.
    static func waitForQuiescence(_ app: XCUIApplication, animations: Bool = true, timeout: TimeInterval? = nil) throws {
        let process = try applicationProcess(app)
        if let timeout, let set = setStateTimeout, let get = stateTimeout {
            let previous = get()
            set(timeout)
            defer { set(previous) }
            try waitForQuiescence(process, animations: animations)
        } else {
            try waitForQuiescence(process, animations: animations)
        }
    }

    private typealias SetStateTimeout = @convention(c) (Double) -> Void
    private typealias StateTimeout = @convention(c) () -> Double
    private static let setStateTimeout: SetStateTimeout? = function("_XCTSetApplicationStateTimeout")
    private static let stateTimeout: StateTimeout? = function("_XCTApplicationStateTimeout")

    /// A C function of the loaded frameworks, nil (with a log line) when missing.
    private static func function<T>(_ name: String) -> T? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { // RTLD_DEFAULT
            NSLog("speedrun: \(name) is missing")
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func waitForQuiescence(_ process: NSObject, animations: Bool) throws {
        let withPreEvent = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        let plain = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
        if process.responds(to: withPreEvent) {
            typealias Wait = @convention(c) (NSObject, Selector, Bool, Bool) -> Void
            unsafeBitCast(process.method(for: withPreEvent), to: Wait.self)(process, withPreEvent, animations, false)
        } else if process.responds(to: plain) {
            typealias Wait = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(process.method(for: plain), to: Wait.self)(process, plain, animations)
        } else {
            throw AgentError(message: "XCUIApplicationProcess.waitForQuiescenceIncludingAnimationsIdle: is missing")
        }
    }

    /// Bundle ids of the active apps: XCTest's accessibility client (XCAXClient_iOS, from
    /// XCUIDevice.accessibilityInterface) lists their accessibility elements, testmanagerd
    /// names each process (cached: a process keeps its bundle id). Empty, with a log line, if
    /// any of it is missing. (activeForegroundApplications exists too, but its elements carry
    /// no process id on Xcode 27.)
    static func activeBundleIDs() -> [String] {
        let interface = NSSelectorFromString("accessibilityInterface") // the XCAXClient_iOS
        guard XCUIDevice.shared.responds(to: interface),
              let client = XCUIDevice.shared.perform(interface)?.takeUnretainedValue() as? NSObject,
              client.responds(to: NSSelectorFromString("activeApplications")),
              let elements = client.perform(NSSelectorFromString("activeApplications"))?.takeUnretainedValue() as? [NSObject]
        else {
            NSLog("speedrun: XCAXClient_iOS.activeApplications is missing; only SpringBoard is seen")
            return []
        }
        let pidSel = NSSelectorFromString("processIdentifier")
        typealias Pid = @convention(c) (NSObject, Selector) -> Int32
        return elements.compactMap { element -> String? in
            guard element.responds(to: pidSel) else { return nil }
            let pid = unsafeBitCast(element.method(for: pidSel), to: Pid.self)(element, pidSel)
            return bundleID(pid: pid)
        }
    }

    /// Diagnostics (spike op FOREGROUND): what each way of listing apps returns.
    static func foregroundReport() -> String {
        let interface = NSSelectorFromString("accessibilityInterface")
        guard XCUIDevice.shared.responds(to: interface),
              let client = XCUIDevice.shared.perform(interface)?.takeUnretainedValue() as? NSObject
        else { return "no accessibility client" }
        var lines = ["client: \(Swift.type(of: client))"]
        for name in ["activeApplications", "activeForegroundApplications"] {
            let sel = NSSelectorFromString(name)
            guard client.responds(to: sel) else { lines.append("\(name): missing"); continue }
            let raw = client.perform(sel)?.takeUnretainedValue()
            let list = raw as? [NSObject] ?? []
            let pidSel = NSSelectorFromString("processIdentifier")
            typealias Pid = @convention(c) (NSObject, Selector) -> Int32
            let pids = list.map { $0.responds(to: pidSel) ? unsafeBitCast($0.method(for: pidSel), to: Pid.self)($0, pidSel) : -1 }
            lines.append("\(name): \(raw.map { String(describing: Swift.type(of: $0)) } ?? "nil"), \(list.count) elements, pids \(pids), bundles \(pids.map { bundleID(pid: $0) ?? "?" })")
        }
        return lines.joined(separator: "\n")
    }

    private static var bundleIDs: [Int32: String] = [:]

    private static func bundleID(pid: Int32) -> String? {
        if let id = bundleIDs[pid] { return id }
        guard let proxy = try? daemonProxy() else { return nil }
        let sel = NSSelectorFromString("_XCT_requestBundleIDForPID:reply:")
        guard proxy.responds(to: sel) else {
            NSLog("speedrun: _XCT_requestBundleIDForPID:reply: is missing")
            return nil
        }
        typealias Request = @convention(c) (NSObject, Selector, Int32, @escaping (NSString?, Error?) -> Void) -> Void
        let done = DispatchSemaphore(value: 0)
        var id: String?
        unsafeBitCast(proxy.method(for: sel), to: Request.self)(proxy, sel, pid) { bundle, _ in
            id = bundle as String?
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        if let id { bundleIDs[pid] = id }
        return id
    }

    /// The XCUIApplicationProcess behind app. Its accessor moved between Xcode versions; each
    /// step is checked (KVC on a missing key would throw an Objective-C exception and kill the
    /// runner).
    static func applicationProcess(_ app: XCUIApplication) throws -> NSObject {
        for path in [["currentProcess"], ["applicationProcess"], ["applicationImpl", "currentProcess"], ["applicationImpl", "applicationProcess"]] {
            var object: NSObject? = app
            for name in path {
                let sel = NSSelectorFromString(name)
                guard let current = object, current.responds(to: sel) else { object = nil; break }
                object = current.perform(sel)?.takeUnretainedValue() as? NSObject
            }
            if let object { return object }
        }
        throw AgentError(message: "no accessor for XCUIApplication's process (applicationProcess, applicationImpl.currentProcess)")
    }

    /// Calls `selector(arg, completion)` on target and waits for the completion (delivered on
    /// another queue, so this must not run on a queue the completion needs).
    private static func callWithCompletion(_ target: NSObject, _ selector: String, _ arg: NSObject, wait: Bool = true) throws {
        let sel = NSSelectorFromString(selector)
        guard target.responds(to: sel) else { throw AgentError(message: "\(selector) is missing") }
        typealias Call = @convention(c) (NSObject, Selector, NSObject, @escaping (Error?) -> Void) -> Void
        let done = DispatchSemaphore(value: 0)
        let failure = Box()
        unsafeBitCast(target.method(for: sel), to: Call.self)(target, sel, arg) {
            failure.error = $0
            done.signal()
        }
        guard wait else {
            unconfirmed = (done, failure)
            return
        }
        done.wait()
        if let error = failure.error { throw error }
    }
}
