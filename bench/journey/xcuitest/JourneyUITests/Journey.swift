// The journey (../journey.yaml) in XCUITest, Apple's UI testing framework, written as its
// tests usually are: queries by identifier or label, waitForExistence before acting, tap()
// and typeText(). Speedrun Bench is started by its bundle identifier; run.sh resets its data
// before each run.
import XCTest

final class JourneyUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "dev.speedrun.bench")
    let timeout: TimeInterval = 15

    override func setUp() {
        continueAfterFailure = false
    }

    /// The element with this accessibility identifier (a React Native testID).
    func id(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The element showing this text.
    func text(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func see(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "not found: \(element)", file: file, line: line)
    }

    func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        see(element, file: file, line: line)
        element.tap()
    }

    /// Waits until a touch would reach the element (a loading overlay may cover it).
    func tapWhenHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        see(element, file: file, line: line)
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [hittable], timeout: timeout)
        element.tap()
    }

    /// Swipes up until the element is on screen and can be tapped.
    func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<30 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "not reached: \(element)", file: file, line: line)
    }

    func testJourney() {
        let start = Date()

        // Sign in with a phone number and a code.
        app.launch()
        tap(id("onboarding-skip"))
        tap(id("phone-input"))
        app.typeText("5550101234")
        tap(id("next"))
        tap(id("code-input"))
        app.typeText("123456")
        tap(id("notify-later"))
        see(text("Hi, Alex"))

        // Search the shop, pick options, add to the cart.
        tap(id("tab-shop"))
        tap(id("search-input"))
        app.typeText("sneaker\n")
        see(text("6 products"))
        tap(text("City Sneaker"))
        tap(id("size-M"))
        tap(id("color-Blue"))
        tap(id("qty-plus"))
        see(text("Qty 2"))
        tap(id("qty-plus"))
        see(text("Qty 3"))
        tap(id("add-to-cart"))
        see(text("Cart (3)"))
        tap(id("go-to-cart"))
        see(text("Size M · Blue"))
        tap(id("header-back"))
        tap(id("header-back"))

        // Set a PIN on a keypad that a loading overlay covers for its first 1.5 s.
        tap(id("tab-profile"))
        tap(id("security"))
        tapWhenHittable(id("key-1"))
        tap(id("key-2"))
        tap(id("key-3"))
        tap(id("key-4"))
        see(text("Confirm your PIN"))
        tap(id("key-1"))
        tap(id("key-2"))
        tap(id("key-3"))
        tap(id("key-4"))
        see(text("PIN set"))

        // Scroll a long list to a row and pick it.
        tap(id("tab-lab"))
        tap(id("lab-drag"))
        tap(id("open-long-list"))
        scrollTo(text("Row 60"))
        tap(text("Row 60"))
        see(text("Picked row 60"))

        print(String(format: "JOURNEY_SECONDS %.1f", Date().timeIntervalSince(start)))
    }
}
