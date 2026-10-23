// XCTest's private API, reached through the Objective-C runtime. Every entry point is looked
// up before use: a missing one is an error naming it, never a crash, so a new Xcode that
// renames something degrades into a clear message.
import XCTest

enum Private {
    /// Instance and class methods of an Objective-C class, for finding what an Xcode offers.
    static func methods(of className: String) -> [String] {
        guard let cls = NSClassFromString(className) else { return ["(no class \(className))"] }
        var out: [String] = []
        for (target, prefix) in [(cls, "-"), (object_getClass(cls)!, "+")] {
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
    /// once it has been delivered.
    static func tap(at point: CGPoint, hold: TimeInterval, wait: Bool = true) throws {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type
        else { throw AgentError(message: "XCSynthesizedEventRecord or XCPointerEventPath is missing") }

        let initPath = NSSelectorFromString("initForTouchAtPoint:offset:")
        typealias InitPath = @convention(c) (NSObject, Selector, CGPoint, TimeInterval) -> NSObject
        let pathAlloc = pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        let path = unsafeBitCast(pathAlloc.method(for: initPath), to: InitPath.self)(pathAlloc, initPath, point, 0)
        let lift = NSSelectorFromString("liftUpAtOffset:")
        typealias Lift = @convention(c) (NSObject, Selector, TimeInterval) -> Void
        unsafeBitCast(path.method(for: lift), to: Lift.self)(path, lift, hold)

        let initRecord = NSSelectorFromString("initWithName:interfaceOrientation:")
        typealias InitRecord = @convention(c) (NSObject, Selector, NSString, Int) -> NSObject
        let recordAlloc = recordClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue() as! NSObject
        let record = unsafeBitCast(recordAlloc.method(for: initRecord), to: InitRecord.self)(
            recordAlloc, initRecord, "Single-Finger Touch Action", UIInterfaceOrientation.portrait.rawValue)
        let add = NSSelectorFromString("addPointerEventPath:")
        typealias Add = @convention(c) (NSObject, Selector, NSObject) -> Void
        unsafeBitCast(record.method(for: add), to: Add.self)(record, add, path)

        try callWithCompletion(try daemonProxy(), "_XCT_synthesizeEvent:completion:", record, wait: wait)
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
    static func waitForQuiescence(_ app: XCUIApplication) throws {
        let process = try applicationProcess(app)
        let withPreEvent = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        let plain = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
        if process.responds(to: withPreEvent) {
            typealias Wait = @convention(c) (NSObject, Selector, Bool, Bool) -> Void
            unsafeBitCast(process.method(for: withPreEvent), to: Wait.self)(process, withPreEvent, true, false)
        } else if process.responds(to: plain) {
            typealias Wait = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(process.method(for: plain), to: Wait.self)(process, plain, true)
        } else {
            throw AgentError(message: "XCUIApplicationProcess.waitForQuiescenceIncludingAnimationsIdle: is missing")
        }
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
