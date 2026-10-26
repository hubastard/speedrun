// SETTLE on iOS: XCTest's own quiescence (the app's event loop, then its animations, idle),
// checked against the screen, because quiescence alone was seen to report idle before a push
// transition had begun:
//   1. wait for quiescence, then take the foreground app's signature (Screen.signature);
//   2. while it still equals the screen the flow last read, nothing has happened yet: poll
//      until it differs, or report "no change" once no_change_ms have passed since the action;
//   3. once it differs, settled when two signatures in a row, each after quiescence, agree.
// After a swipe, quiescence leaves out animations: the content stops at lift-up, and what is
// left (the scroll indicator fading) does not matter to a flow; content still moving shows up
// as differing signatures.
// Typing and drags return before testmanagerd confirms their events: settle checks the
// screen meanwhile, but concludes (settled or no change) only once they are confirmed.
// An animation that never ends (under an open context menu) would hold quiescence for
// XCTest's 60 s: a wait is cut at quiescenceCapS, and once one was, the settle waits for the
// event loop only, the signatures telling whether the screen still changes.
// Times are measured from the last action. quiet_ms is unused: quiescence is the quiet signal.
import XCTest

final class Settle {
    private let screen: Screen
    private let input: Input
    private static let pollMs = 30
    /// Longer than UIKit's transitions, the keyboard's and SpringBoard's (~0.5 s).
    private static let quiescenceCapS = 2.0

    init(screen: Screen, input: Input) {
        self.screen = screen
        self.input = input
    }

    /// Response: u8 status (0 settled, 1 no change, 2 timeout), u32 ui_done_us, u32 waited_us,
    /// u8 method (2: quiescence + signature), u32 quiescence waits, u32 signatures,
    /// u32 longest quiescence wait in us, u32 events (0). Main thread.
    func run(quietMs: Int, noChangeMs: Int, timeoutMs: Int, out: inout Writer) throws {
        let start = input.lastActionNs
        let deadline = start + UInt64(max(timeoutMs, 0)) * 1_000_000
        let noChangeUntil = start + UInt64(max(noChangeMs, 0)) * 1_000_000
        let before = screen.lastSignature
        var waits: UInt32 = 0, signatures: UInt32 = 0, longest: UInt32 = 0
        var changed = before == nil // nothing to compare with: require two equal signatures
        var previous: Int?
        var doneAt = start
        var status: UInt8 = 2
        var animations = !input.lastWasSwipe

        while true {
            let q = DispatchTime.now().uptimeNanoseconds
            let cap = min(Self.quiescenceCapS, max(Double(deadline &- min(q, deadline)) / 1e9, 0.1))
            try Private.waitForQuiescence(screen.foregroundApp(), animations: animations, timeout: cap)
            waits += 1
            longest = max(longest, micros(since: q))
            if Double(micros(since: q)) >= cap * 0.95e6 { animations = false }
            let sig = try screen.signature()
            signatures += 1
            let now = DispatchTime.now().uptimeNanoseconds
            if !changed && sig != before { changed = true }
            if changed {
                if sig == previous, try Private.pendingConfirmed() {
                    status = 0
                    break
                }
                previous = sig
                doneAt = now
            } else if now >= noChangeUntil, try Private.pendingConfirmed() {
                status = 1
                doneAt = start
                break
            } else {
                Thread.sleep(forTimeInterval: Double(Self.pollMs) / 1000)
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
        }

        out.u8(status)
        out.u32(doneAt > start ? UInt32(clamping: (doneAt - start) / 1000) : 0)
        out.u32(micros(since: start))
        out.u8(2)
        out.u32(waits)
        out.u32(signatures)
        out.u32(longest)
        out.u32(0)
    }
}
