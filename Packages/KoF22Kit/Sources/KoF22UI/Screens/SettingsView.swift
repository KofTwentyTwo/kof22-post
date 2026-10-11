#if os(iOS)
import SwiftData
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmReset = false
    private let permissions = Permissions.shared
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let me = app.me {
                        LabeledContent("Name", value: me.name ?? me.author?.name ?? "—")
                        LabeledContent("Email", value: me.email)
                        LabeledContent("Can post", value: me.canPost ? "Yes" : "No")
                        if !me.groups.isEmpty { LabeledContent("Groups", value: me.groups.joined(separator: ", ")) }
                    } else {
                        Text("Account details unavailable").foregroundStyle(Theme.muted)
                    }
                    Button("Sign out", role: .destructive) { Task { await app.signOut() } }
                        .accessibilityIdentifier("settings.signOut")
                }

                Section {
                    LabeledContent("Photos", value: photoStatus)
                    if permissions.photos == .notDetermined {
                        Button("Allow full photo access") { Task { await permissions.requestPhotos() } }
                    } else if !permissions.hasFullPhotoAccess {
                        Button("Change in Settings") { permissions.openSettings() }
                    }
                    LabeledContent("Location", value: locationStatus)
                    if permissions.location == .notDetermined {
                        Button("Allow location") { Task { _ = try? await permissions.currentPlaceLabel() } }
                    } else if !permissions.hasLocationAccess || !permissions.preciseLocation {
                        Button("Change in Settings") { permissions.openSettings() }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Full photo access lets the app upload originals and keep their location when you ask. Location fills in where you are posting from.")
                }
                .onAppear { permissions.refresh() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { permissions.refresh() } }

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

                Section {
                    Picker("Backend", selection: Binding(get: { app.mode }, set: { mode in Task { await app.setMode(mode) } })) {
                        Text("Mock").tag(BackendMode.mock)
                        Text("api.kof22.com").tag(BackendMode.live)
                    }
                    LabeledContent("API version", value: app.apiVersion ?? "—")
                } header: {
                    Text("Backend")
                } footer: {
                    Text(app.mode == .mock
                         ? "Mock mode runs the Site API v1 contract on this phone. Posts never leave the device."
                         : "Live mode posts to https://api.kof22.com with your KoF22 (Authentik) account.")
                }

                if app.mode == .mock {
                    Section("Mock tools") {
                        Toggle("Simulate offline", isOn: Binding(get: { app.simulateOffline },
                                                                 set: { value in Task { await app.setSimulateOffline(value) } }))
                            .tint(Theme.accent)
                            .accessibilityIdentifier("settings.offline")
                        Button("Reset mock data", role: .destructive) { confirmReset = true }
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    Link("kof22.com", destination: URL(string: "https://www.kof22.com")!)
                    Link("API docs", destination: URL(string: "https://api.kof22.com/v1/")!)
                } footer: {
                    Text("No analytics or tracking. Tokens are stored in the Keychain only.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Erase all mock posts and photos?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { Task { await app.resetMockData() } }
            }
        }
    }
}

extension SettingsView {
    var photoStatus: String {
        switch permissions.photos {
        case .authorized: "Full access"
        case .limited: "Selected photos only"
        case .denied, .restricted: "Off"
        default: "Not asked yet"
        }
    }

    var locationStatus: String {
        switch permissions.location {
        case .authorizedWhenInUse, .authorizedAlways: permissions.preciseLocation ? "Precise" : "Approximate"
        case .denied, .restricted: "Off"
        default: "Not asked yet"
        }
    }
}

public struct SignInView: View {
    @Environment(AppModel.self) private var app
    let authenticator: any WebAuthenticator
    @State private var busy = false

    public init(authenticator: any WebAuthenticator) { self.authenticator = authenticator }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            TerminalPanel("kof22 — post") {
                VStack(alignment: .leading, spacing: 8) {
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
            .padding(.horizontal)

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
                .padding(.vertical, 14)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color.black)
            }
            .disabled(busy)
            .padding(.horizontal)
            .accessibilityIdentifier("signIn.button")

            if let error = app.lastError {
                Text(error).font(.footnote).foregroundStyle(Theme.danger).padding(.horizontal)
            }
            Spacer()
            Picker("Backend", selection: Binding(get: { app.mode }, set: { mode in Task { await app.setMode(mode) } })) {
                Text("Mock API").tag(BackendMode.mock)
                Text("api.kof22.com").tag(BackendMode.live)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)
            .padding(.bottom)
        }
        .background(Theme.background)
    }
}

/// Signed-in shell: Compose first, then Outbox, Posts and Settings.
public struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var composer: ComposeModel?
    @Query private var outbox: [OutboxItem]

    public init() {}

    private var outboxBadge: Int {
        outbox.filter { [.queued, .sending, .failed].contains($0.state) }.count
    }

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

public struct RootView: View {
    @Environment(AppModel.self) private var app
    let authenticator: any WebAuthenticator

    public init(authenticator: any WebAuthenticator) { self.authenticator = authenticator }

    public var body: some View {
        Group {
            if app.isSignedIn {
                MainView()
            } else {
                SignInView(authenticator: authenticator)
            }
        }
        .fontDesign(nil)
    }
}
#endif
