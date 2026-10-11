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

    func testSignInOpensComposer() {
        signIn()
        XCTAssertTrue(app.buttons["compose.post"].exists)
    }

    func testPostAppearsInOutboxAndPosts() {
        signIn()
        let body = app.textViews["compose.body"]
        body.tap()
        body.typeText("Hello from the UI test")
        app.buttons["compose.post"].tap()

        // Lands on the Outbox and is sent by the mock backend.
        let sent = app.staticTexts["Sent"]
        XCTAssertTrue(sent.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Hello from the UI test"].exists)

        app.tabBars.buttons["Posts"].tap()
        XCTAssertTrue(app.staticTexts["Hello from the UI test"].waitForExistence(timeout: 10))
    }

    func testOfflinePostIsQueuedThenSent() {
        signIn()
        app.tabBars.buttons["Settings"].tap()
        let offline = app.switches["settings.offline"]
        XCTAssertTrue(offline.waitForExistence(timeout: 5))
        offline.switches.firstMatch.tap()

        app.tabBars.buttons["Compose"].tap()
        let body = app.textViews["compose.body"]
        body.tap()
        body.typeText("Written on a plane")
        app.buttons["compose.post"].tap()
        XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Offline"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Settings"].tap()
        offline.switches.firstMatch.tap()
        app.tabBars.buttons["Outbox"].tap()
        app.buttons["outbox.sendNow"].tap()
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 15))
    }

    func testSignOutReturnsToSignIn() {
        signIn()
        app.tabBars.buttons["Settings"].tap()
        let signOut = app.buttons["settings.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.buttons["signIn.button"].waitForExistence(timeout: 5))
    }
}
