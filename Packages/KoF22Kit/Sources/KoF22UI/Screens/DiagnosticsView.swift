/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI

   /// Checks whether sign-in and the API are reachable: Authentik discovery for the
   /// `kof22-post-ios` client, `/versions.json`, an anonymous read and the token
   /// endpoint. It shows when sign-in goes live without guessing from failures.
   struct DiagnosticsView: View {
      /// Results of the last run, in check order.
      @State private var checks: [DiagnosticCheck] = []
      /// True while the checks run.
      @State private var running = false
      /// The checker; uses the production configuration and a real URLSession.
      private let diagnostics = ServiceDiagnostics()

      /// One row per check with pass/fail and the detail text.
      var body: some View {
         List {
            Section {
               ForEach(checks) { check in
                  HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                     Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(check.passed ? Theme.accent : Theme.danger)
                     VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(check.title).font(.body.weight(.medium))
                        Text(check.detail).font(Theme.mono(.caption)).foregroundStyle(Theme.muted)
                     }
                  }
                  .accessibilityElement(children: .combine)
               }
               if running {
                  ProgressView().frame(maxWidth: .infinity)
               }
            } footer: {
               Text("If api.kof22.com does not resolve on home Wi-Fi, try cellular: it can be a local DNS cache.")
            }
         }
         .navigationTitle("Diagnostics")
         .toolbar { Button("Run again") { Task { await run() } }.disabled(running) }
         .task { await run() }
      }

      /// Runs every check once.
      private func run() async {
         running = true
         checks = await diagnostics.run()
         running = false
      }
   }

   /// Shown instead of the composer when the signed-in account may not publish, with the
   /// server's reason, a retry, diagnostics and sign-out.
   struct CannotPublishView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// Why publishing is not allowed.
      let reason: String

      /// The explanation and actions.
      var body: some View {
         NavigationStack {
            VStack(spacing: Theme.Spacing.xxLarge) {
               ContentUnavailableView(
                  "This account can't publish", systemImage: "lock.trianglebadge.exclamationmark",
                  description: Text(reason))
               Button("Try again") { Task { await app.refreshMe() } }
                  .buttonStyle(.borderedProminent)
                  .tint(Theme.accent)
               NavigationLink("Diagnostics") { DiagnosticsView() }
               Button("Sign out", role: .destructive) { Task { await app.signOut() } }
                  .accessibilityIdentifier("cannotPublish.signOut")
            }
            .padding()
            .background(Theme.background)
         }
      }
   }
#endif
