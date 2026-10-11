import XCTest

/// Captures the main screens as test attachments for visual review
/// (`xcrun xcresulttool export attachments`).
final class ScreenshotTests: XCTestCase {
   func testCaptureScreens() {
      let app = XCUIApplication()
      app.launchArguments = ["-uitest"]
      app.launch()
      snap(app, "1-sign-in")
      app.buttons["signIn.button"].tap()
      let body = app.textViews["compose.body"]
      XCTAssertTrue(body.waitForExistence(timeout: 10))
      body.typeText("Trying the **new** app.\n\n- fast\n- terminal look")
      app.textFields["compose.tags"].tap()
      app.textFields["compose.tags"].typeText("Sw")
      sleep(1)
      snap(app, "2-compose")
      app.buttons["Preview"].tap()
      snap(app, "3-preview")
      app.buttons["compose.post"].tap()
      XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 15))
      snap(app, "4-outbox")
      app.tabBars.buttons["Posts"].tap()
      sleep(2)
      snap(app, "5-posts")
      app.staticTexts["Trying the new app."].firstMatch.tap()
      sleep(1)
      snap(app, "6-detail")
      app.tabBars.buttons["Settings"].tap()
      snap(app, "7-settings")
   }

   private func snap(_ app: XCUIApplication, _ name: String) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
   }
}
