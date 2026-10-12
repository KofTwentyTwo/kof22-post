/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI

   /// The signed-out screen: a terminal greeting, the sign-in button and the backend switch.
   public struct SignInView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// Presents the browser sign-in.
      let authenticator: any WebAuthenticator
      /// Whether a sign-in is in progress.
      @State private var busy = false

      /// Creates the screen with the authenticator that presents the browser sign-in.
      public init(authenticator: any WebAuthenticator) { self.authenticator = authenticator }

      /// Greeting panel, sign-in button, any error, and the backend picker at the bottom.
      public var body: some View {
         VStack(spacing: Theme.Spacing.xxLarge) {
            Spacer()
            greeting.padding(.horizontal)
            signInButton
            if let error = app.lastError {
               Text(error).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal)
            }
            Spacer()
            Picker("Backend", selection: Binding(get: { app.mode }, set: { mode in Task { await app.setMode(mode) } })) {
               Text("Mock API").tag(BackendMode.mock)
               Text("api.kof22.com").tag(BackendMode.live)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.pickerHorizontal)
            .padding(.bottom)
         }
         .background(Theme.background)
      }

      /// A terminal panel with a prompt, a sample command and a one-line explanation.
      private var greeting: some View {
         TerminalPanel("kof22 — post") {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
               PromptLabel("~", cursor: false)
               HStack(spacing: 0) {
                  Text("$ ").foregroundStyle(Theme.accent)
                  Text("post --to field-notes").foregroundStyle(Theme.heading)
                  BlinkingCursor()
               }
               .font(Theme.mono(.callout))
               Text("Sign in with your KoF22 account to publish.")
                  .font(Theme.mono(.footnote))
                  .foregroundStyle(Theme.body)
            }
         }
      }

      /// Full-width accent button that starts the sign-in, with a spinner while it runs.
      private var signInButton: some View {
         Button {
            busy = true
            Task {
               await app.signIn(using: authenticator)
               busy = false
            }
         } label: {
            HStack {
               if busy { ProgressView().tint(.black) }
               Text(app.mode == .mock ? "Sign in (mock)" : "Sign in with KoF22")
            }
            .font(Theme.mono(.body, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xLarge)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
            .foregroundStyle(Color.black)
         }
         .disabled(busy)
         .padding(.horizontal)
         .accessibilityIdentifier("signIn.button")
      }
   }
#endif
