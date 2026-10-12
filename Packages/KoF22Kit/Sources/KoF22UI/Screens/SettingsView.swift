/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI

   /// Account, permissions, blogs, backend choice, mock tools and app information.
   public struct SettingsView: View {
      /// The site, linked from the About section.
      private static let siteURL = URL(literal: "https://www.kof22.com")
      /// The API documentation, linked from the About section.
      private static let apiDocsURL = URL(literal: "https://api.kof22.com/v1/")
      /// Shown for values that are not known.
      private static let unknownValue = "—"

      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// Whether the mock-data reset confirmation is shown.
      @State private var confirmReset = false
      /// Photo and location authorization.
      private let permissions = Permissions.shared
      /// Re-reads permissions when the app returns from the Settings app.
      @Environment(\.scenePhase) private var scenePhase

      /// Creates the Settings screen.
      public init() {}

      /// The settings form.
      public var body: some View {
         NavigationStack {
            Form {
               accountSection
               permissionsSection
               blogsSection
               backendSection
               if app.mode == .mock {
                  mockToolsSection
               }
               aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog("Erase all mock posts and photos?", isPresented: $confirmReset, titleVisibility: .visible) {
               Button("Reset", role: .destructive) { Task { await app.resetMockData() } }
            }
         }
      }

      /// Name, email, posting rights and groups, with Sign out.
      private var accountSection: some View {
         Section("Account") {
            if let account = app.me {
               LabeledContent("Name", value: account.name ?? account.author?.name ?? Self.unknownValue)
               LabeledContent("Email", value: account.email)
               LabeledContent("Can post", value: account.canPost ? "Yes" : "No")
               if !account.groups.isEmpty { LabeledContent("Groups", value: account.groups.joined(separator: ", ")) }
            }
            else {
               Text("Account details unavailable").foregroundStyle(Theme.muted)
            }
            Button("Sign out", role: .destructive) { Task { await app.signOut() } }
               .accessibilityIdentifier("settings.signOut")
         }
      }

      /// Photo and location status, each with a button to grant or change access.
      private var permissionsSection: some View {
         Section {
            LabeledContent("Photos", value: photoStatus)
            if permissions.photos == .notDetermined {
               Button("Allow full photo access") { Task { await permissions.requestPhotos() } }
            }
            else if !permissions.hasFullPhotoAccess {
               Button("Change in Settings") { permissions.openSettings() }
            }
            LabeledContent("Location", value: locationStatus)
            if permissions.location == .notDetermined {
               Button("Allow location") { Task { await requestLocation() } }
            }
            else if !permissions.hasLocationAccess || !permissions.preciseLocation {
               Button("Change in Settings") { permissions.openSettings() }
            }
         } header: {
            Text("Permissions")
         } footer: {
            Text("Full photo access lets the app upload originals and keep their location when you ask. Location fills in where you are posting from.")
         }
         .onAppear { permissions.refresh() }
         .onChange(of: scenePhase) { _, phase in if phase == .active { permissions.refresh() } }
      }

      /// The account's blogs, with a check mark on the default.
      private var blogsSection: some View {
         Section("Blogs") {
            ForEach(app.blogs) { blog in
               HStack {
                  Text(blog.name)
                  Spacer()
                  Text(blog.slug).font(Theme.mono(.caption)).foregroundStyle(Theme.muted)
                  if blog.slug == app.defaultBlog { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
               }
            }
         }
      }

      /// Mock or live backend and the API version.
      private var backendSection: some View {
         Section {
            Picker("Backend", selection: Binding(get: { app.mode }, set: { mode in Task { await app.setMode(mode) } })) {
               Text("Mock").tag(BackendMode.mock)
               Text("api.kof22.com").tag(BackendMode.live)
            }
            LabeledContent("API version", value: app.apiVersion ?? Self.unknownValue)
         } header: {
            Text("Backend")
         } footer: {
            Text(
               app.mode == .mock
                  ? "Mock mode runs the Site API v1 contract on this phone. Posts never leave the device."
                  : "Live mode posts to https://api.kof22.com with your KoF22 (Authentik) account.")
         }
      }

      /// Offline simulation and the mock-data reset.
      private var mockToolsSection: some View {
         Section("Mock tools") {
            Toggle(
               "Simulate offline",
               isOn: Binding(
                  get: { app.simulateOffline },
                  set: { value in Task { await app.setSimulateOffline(value) } })
            )
            .tint(Theme.accent)
            .accessibilityIdentifier("settings.offline")
            Button("Reset mock data", role: .destructive) { confirmReset = true }
         }
      }

      /// App version and links to the site and the API docs.
      private var aboutSection: some View {
         Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? Self.unknownValue)
            Link("kof22.com", destination: Self.siteURL)
            Link("API docs", destination: Self.apiDocsURL)
         } footer: {
            Text("No analytics or tracking. Tokens are stored in the Keychain only.")
         }
      }

      /// Triggers the location prompt by asking for a place label. The label is not needed
      /// here and the outcome shows in the status row, so a failure is only logged.
      private func requestLocation() async {
         do {
            _ = try await permissions.currentPlaceLabel()
         }
         catch {
            Log.ui.notice("Location request from Settings ended without a place: \(error.localizedDescription, privacy: .public)")
         }
      }
   }

   extension SettingsView {
      /// Photo access in words.
      var photoStatus: String {
         switch permissions.photos {
         case .authorized: "Full access"
         case .limited: "Selected photos only"
         case .denied, .restricted: "Off"
         default: "Not asked yet"
         }
      }

      /// Location access and accuracy in words.
      var locationStatus: String {
         switch permissions.location {
         case .authorizedWhenInUse, .authorizedAlways: permissions.preciseLocation ? "Precise" : "Approximate"
         case .denied, .restricted: "Off"
         default: "Not asked yet"
         }
      }
   }
#endif
