import XCTest

/// Main flows against the in-process mock API (`-uitest` launch argument):
/// fresh mock data, in-memory store, nothing leaves the simulator.
final class KoF22PostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()
    }

    private func signIn() {
        let button = app.buttons["signIn.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(app.textViews["compose.body"].waitForExistence(timeout: 10))
    }

    /// The composer opens with the keyboard up, covering the tab bar. Switching
    /// the editor to Preview drops focus, like a user would.
    private func tab(_ name: String) {
        if app.keyboards.count > 0, app.buttons["Preview"].exists {
            app.buttons["Preview"].tap()
        }
        app.tabBars.buttons[name].tap()
    }

    /// Settings is a lazy Form: scroll until the mock offline toggle exists, then flip it.
    private func toggleOffline() {
        tab("Settings")
        let offline = app.switches["settings.offline"]
        for _ in 0..<5 where !offline.exists { app.swipeUp() }
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        let control = offline.switches.firstMatch
        (control.exists ? control : offline).tap()
    }

    private func write(_ text: String) {
        if app.buttons["Write"].exists { app.buttons["Write"].tap() }
        let body = app.textViews["compose.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.tap()
        body.typeText(text)
    }

    func testSignInOpensComposer() {
        signIn()
        XCTAssertTrue(app.buttons["compose.post"].exists)
    }

    func testPostAppearsInOutboxAndPosts() {
        signIn()
        write("Hello from the UI test")
        app.buttons["compose.post"].tap()

        // Lands on the Outbox and is sent by the mock backend.
        let sent = app.staticTexts["Sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Hello from the UI test"].exists)

        tab("Posts")
        XCTAssertTrue(app.staticTexts["Hello from the UI test"].waitForExistence(timeout: 10))
    }

    func testOfflinePostIsQueuedThenSent() {
        signIn()
        toggleOffline()

        tab("Compose")
        write("Written on a plane")
        app.buttons["compose.post"].tap()
        XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Offline"].waitForExistence(timeout: 10))

        toggleOffline()
        tab("Outbox")
        let sendNow = app.buttons["outbox.sendNow"]
        if sendNow.waitForExistence(timeout: 3) { sendNow.tap() }
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 15))
    }

    func testSignOutReturnsToSignIn() {
        signIn()
        tab("Settings")
        let signOut = app.buttons["settings.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.buttons["signIn.button"].waitForExistence(timeout: 5))
    }
}
