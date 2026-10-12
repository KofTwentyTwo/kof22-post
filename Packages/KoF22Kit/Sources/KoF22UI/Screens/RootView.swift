/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftData
   import SwiftUI

   /// Signed-in shell: Compose first, then Outbox, Posts and Settings.
   public struct MainView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The Compose tab's composer, replaced when a Shortcut or deep link hands over text.
      @State private var composer: ComposeModel?
      /// Every outbox item, for the tab badge.
      @Query private var outbox: [OutboxItem]

      /// Creates the signed-in shell.
      public init() {}

      /// Number of items still on their way or needing attention.
      private var outboxBadge: Int {
         outbox.filter { [.queued, .sending, .failed].contains($0.state) }.count
      }

      /// The four tabs, bound to `AppModel.selectedTab` so deep links can switch them.
      public var body: some View {
         @Bindable var app = app
         TabView(selection: $app.selectedTab) {
            Tab("Compose", systemImage: "square.and.pencil", value: AppTab.compose) {
               NavigationStack {
                  if let composer {
                     ComposeView(model: composer)
                        .navigationTitle("New post")
                        .navigationBarTitleDisplayMode(.inline)
                  }
               }
            }
            Tab("Outbox", systemImage: "tray.full", value: AppTab.outbox) { OutboxView() }
               .badge(outboxBadge)
            Tab("Posts", systemImage: "list.bullet.rectangle", value: AppTab.posts) { PostsView() }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) { SettingsView() }
         }
         .tint(Theme.accent)
         .onAppear { if composer == nil { composer = ComposeModel(app: app) } }
         .onChange(of: app.pendingComposition) { _, pending in
            guard let pending else { return }
            composer = ComposeModel(app: app, composition: pending)
            app.pendingComposition = nil
         }
      }
   }

   /// The app's root: the signed-in shell or the sign-in screen.
   public struct RootView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// Presents the browser sign-in.
      let authenticator: any WebAuthenticator

      /// Creates the root with the authenticator used by the sign-in screen.
      public init(authenticator: any WebAuthenticator) { self.authenticator = authenticator }

      /// Switches on `AppModel.isSignedIn`.
      public var body: some View {
         Group {
            if app.isSignedIn {
               MainView()
            }
            else {
               SignInView(authenticator: authenticator)
            }
         }
         .fontDesign(nil)
      }
   }
#endif
