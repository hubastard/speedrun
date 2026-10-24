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

    /// A touch at point (screen points) held for hold seconds, played by testmanagerd; returns
    /// once it has been delivered (or right away when wait is false).
    static func tap(at point: CGPoint, hold: TimeInterval, wait: Bool = true) throws {
        let path = try touchPath(at: point)
        try call(path, "liftUpAtOffset:", hold)
        try synthesize(try record(with: path), wait: wait)
    }

    /// Down at start, at end 100 ms later, held there for duration, then up (Maestro's
    /// EventRecord.addSwipeEvent).
    static func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) throws {
        let path = try touchPath(at: start)
        let move = NSSelectorFromString("moveToPoint:atOffset:")
        guard path.responds(to: move) else { throw AgentError(message: "XCPointerEventPath.moveToPoint:atOffset: is missing") }
        typealias Move = @convention(c) (NSObject, Selector, CGPoint, TimeInterval) -> Void
        unsafeBitCast(path.method(for: move), to: Move.self)(path, move, end, 0.1)
        try call(path, "liftUpAtOffset:", 0.1 + duration)
        try synthesize(try record(with: path))
    }

    /// Text typed through the keyboard as key events (XCPointerEventPath typeText), at
    /// charactersPerSecond.
    static func typeText(_ text: String, charactersPerSecond: Int) throws {
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
        try synthesize(try record(with: path))
    }

    /// The side (lock) button. Main thread.
    static func pressLock() throws {
        let sel = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: sel) else { throw AgentError(message: "XCUIDevice.pressLockButton is missing") }
        XCUIDevice.shared.perform(sel)
    }

    private static func touchPath(at point: CGPoint) throws -> NSObject {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else {
            throw AgentError(message: "XCPointerEventPath is missing")
        }
        let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
        let alloc = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        guard alloc.responds(to: initPath) else { throw AgentError(message: "XCPointerEventPath.initForTouchAtPoint:offset: is missing") }
        typealias InitPath = @convention(c) (NSObject, Selector, CGPoint, TimeInterval) -> NSObject
        return unsafeBitCast(alloc.method(for: initPath), to: InitPath.self)(alloc, initPath, point, 0)
    }

    private static func record(with path: NSObject) throws -> NSObject {
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
        unsafeBitCast(record.method(for: add), to: Add.self)(record, add, path)
        return record
    }

    private static func synthesize(_ record: NSObject, wait: Bool = true) throws {
        try callWithCompletion(try daemonProxy(), "_XCT_synthesizeEvent:completion:", record, wait: wait)
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
    /// run on the main thread (it spins the run loop).
    static func waitForQuiescence(_ app: XCUIApplication, animations: Bool = true) throws {
        let process = try applicationProcess(app)
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
        var failure: Error?
        unsafeBitCast(target.method(for: sel), to: Call.self)(target, sel, arg) {
            failure = $0
            done.signal()
        }
        guard wait else { return }
        done.wait()
        if let failure { throw failure }
    }
}
