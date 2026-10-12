/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import XCTest

/// Main flows against the in-process mock API (`-uitest` launch argument):
/// fresh mock data, in-memory store, nothing leaves the simulator.
final class KoF22PostUITests: XCTestCase {
   /// Launch argument that switches the app to the mock backend and in-memory store.
   private static let uiTestArgument = "-uitest"
   /// Wait for a screen or control that appears without network work.
   private static let shortTimeout: TimeInterval = 5
   /// Wait for sign-in, navigation and queueing to settle.
   private static let standardTimeout: TimeInterval = 10
   /// Wait for the mock backend to finish sending a post.
   private static let sendTimeout: TimeInterval = 15
   /// Brief wait for the optional "Send now" button after going back online.
   private static let sendNowTimeout: TimeInterval = 3
   /// Upper bound on swipes while looking for a control in a lazy Form.
   private static let maxScrolls = 5

   /// Proxy for the app under test. Every `XCUIApplication()` refers to the same target
   /// app, so a computed property avoids an implicitly unwrapped stored one.
   private var app: XCUIApplication { XCUIApplication() }

   /// Launches a fresh app on the mock backend before each test.
   override func setUpWithError() throws {
      continueAfterFailure = false
      let launched = XCUIApplication()
      launched.launchArguments = [Self.uiTestArgument]
      launched.launch()
   }

   /// Taps the mock sign-in and waits for the composer.
   private func signIn() {
      let button = app.buttons["signIn.button"]
      XCTAssertTrue(button.waitForExistence(timeout: Self.standardTimeout))
      button.tap()
      XCTAssertTrue(app.textViews["compose.body"].waitForExistence(timeout: Self.standardTimeout))
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
      for _ in 0..<Self.maxScrolls where !offline.exists { app.swipeUp() }
      XCTAssertTrue(offline.waitForExistence(timeout: Self.shortTimeout))
      let control = offline.switches.firstMatch
      (control.exists ? control : offline).tap()
   }

   /// Switches the editor back to Write if needed and types `text` into the body.
   private func write(_ text: String) {
      if app.buttons["Write"].exists { app.buttons["Write"].tap() }
      let body = app.textViews["compose.body"]
      XCTAssertTrue(body.waitForExistence(timeout: Self.shortTimeout))
      body.tap()
      body.typeText(text)
   }

   /// Signing in lands on the composer with its Post button.
   func testSignInOpensComposer() {
      signIn()
      XCTAssertTrue(app.buttons["compose.post"].exists)
   }

   /// A post is shown in the Outbox, sent by the mock backend and then listed in Posts.
   func testPostAppearsInOutboxAndPosts() {
      signIn()
      write("Hello from the UI test")
      app.buttons["compose.post"].tap()

      ///////////////////////////////////////////////////////////
      // Lands on the Outbox and is sent by the mock backend.  //
      ///////////////////////////////////////////////////////////
      let sent = app.staticTexts["Sent"]
      XCTAssertTrue(sent.waitForExistence(timeout: Self.sendTimeout))
      XCTAssertTrue(app.staticTexts["Hello from the UI test"].exists)

      tab("Posts")
      XCTAssertTrue(app.staticTexts["Hello from the UI test"].waitForExistence(timeout: Self.standardTimeout))
   }

   /// A post written offline stays queued and is sent once the connection returns.
   func testOfflinePostIsQueuedThenSent() {
      signIn()
      toggleOffline()

      tab("Compose")
      write("Written on a plane")
      app.buttons["compose.post"].tap()
      XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: Self.standardTimeout))
      XCTAssertTrue(app.staticTexts["Offline"].waitForExistence(timeout: Self.standardTimeout))

      toggleOffline()
      tab("Outbox")
      let sendNow = app.buttons["outbox.sendNow"]
      if sendNow.waitForExistence(timeout: Self.sendNowTimeout) { sendNow.tap() }
      XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: Self.sendTimeout))
   }

   /// The Posts tab opens the published blogs (anonymous reads, served by the mock here)
   /// and a blog's published posts.
   func testSiteBlogsListPublishedPosts() {
      signIn()
      tab("Posts")
      let site = app.buttons["posts.site"]
      XCTAssertTrue(site.waitForExistence(timeout: Self.standardTimeout))
      site.tap()
      let quickBits = app.staticTexts["Quick Bits"]
      XCTAssertTrue(quickBits.waitForExistence(timeout: Self.standardTimeout))
      quickBits.tap()
      XCTAssertTrue(
         app.staticTexts["Welcome to the mock Site API. Posts you write here stay on this device."]
            .waitForExistence(timeout: Self.standardTimeout))
   }

   /// Signing out from Settings returns to the sign-in screen.
   func testSignOutReturnsToSignIn() {
      signIn()
      tab("Settings")
      let signOut = app.buttons["settings.signOut"]
      XCTAssertTrue(signOut.waitForExistence(timeout: Self.shortTimeout))
      signOut.tap()
      XCTAssertTrue(app.buttons["signIn.button"].waitForExistence(timeout: Self.shortTimeout))
   }
}
