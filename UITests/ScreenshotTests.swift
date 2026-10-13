/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import XCTest

/// Captures the main screens as test attachments for visual review
/// (`xcrun xcresulttool export attachments`).
final class ScreenshotTests: XCTestCase {
   /// Upper bound on swipes while looking for a control.
   private static let maxScrolls = 5
   /// Wait for the composer after sign-in.
   private static let composerTimeout: TimeInterval = 10
   /// Wait for the mock backend to finish sending the post.
   private static let sendTimeout: TimeInterval = 15
   /// Seconds to let suggestions and detail screens animate in before a capture.
   private static let shortSettle: UInt32 = 1
   /// Seconds to let the Posts list load before a capture.
   private static let listSettle: UInt32 = 2

   /// Walks sign-in, compose, preview, outbox, posts, detail and settings, attaching a
   /// screenshot of each; it also pins down that the main path works end to end.
   func testCaptureScreens() {
      let app = XCUIApplication()
      app.launchArguments = ["-uitest"]
      app.launch()
      snap(app, "1-sign-in")
      app.buttons["signIn.button"].tap()
      let body = app.textViews["compose.body"]
      XCTAssertTrue(body.waitForExistence(timeout: Self.composerTimeout))
      body.typeText(
         "Shipped **offline posting** today.\n\n- write anywhere, it sends when you're back online\n- photos with alt text\n- schedule for later")
      let tags = app.textFields["compose.tags"]
      reveal(tags, in: app)
      tags.tap()
      ///////////////////////////////////////////////////////////////
      // A trailing comma turns the text into a tag; the keyboard  //
      // would cover a suggestion row under the bottom bar.        //
      ///////////////////////////////////////////////////////////////
      tags.typeText("Swift,")
      ///////////////////////////////////////////////////////////////
      // Preview drops focus, so the keyboard is gone for both the //
      // preview shot and the write shot that follows.             //
      ///////////////////////////////////////////////////////////////
      app.buttons["Preview"].tap()
      sleep(Self.shortSettle)
      snap(app, "3-preview")
      app.buttons["Write"].tap()
      sleep(Self.shortSettle)
      snap(app, "2-compose")
      app.buttons["compose.post"].tap()
      XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: Self.sendTimeout))
      snap(app, "4-outbox")
      app.tabBars.buttons["Posts"].tap()
      sleep(Self.listSettle)
      snap(app, "5-posts")
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Shipped offline posting today")).firstMatch.tap()
      sleep(Self.shortSettle)
      snap(app, "6-detail")
      app.navigationBars.buttons.firstMatch.tap()
      let site = app.buttons["posts.site"]
      XCTAssertTrue(site.waitForExistence(timeout: Self.composerTimeout))
      site.tap()
      let blog = app.staticTexts["Quick Bits"]
      XCTAssertTrue(blog.waitForExistence(timeout: Self.composerTimeout))
      blog.tap()
      sleep(Self.listSettle)
      snap(app, "7-site")
      app.tabBars.buttons["Settings"].tap()
      snap(app, "8-settings")
   }

   /// Attaches a screenshot of the current screen under `name`, kept even on success.
   private func snap(_ app: XCUIApplication, _ name: String) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
   }

   /// Dismisses the keyboard and scrolls until `element` can be tapped: the composer is
   /// taller than the screen, and a tap on a covered element lands on the bottom bar.
   private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
      let done = app.buttons["keyboard.done"]
      if done.exists { done.tap() }
      for _ in 0..<Self.maxScrolls where !element.isHittable { app.swipeUp() }
   }
}
