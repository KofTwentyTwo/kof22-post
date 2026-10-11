#if os(iOS)
import SwiftData
import SwiftUI

/// Everything not yet confirmed by the server, plus recent successes.
public struct OutboxView: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \OutboxItem.updatedAt, order: .reverse) private var items: [OutboxItem]
    @State private var editingDraft: OutboxItem?

    public init() {}

    private func items(_ states: Set<OutboxState>) -> [OutboxItem] { items.filter { states.contains($0.state) } }

    public var body: some View {
        NavigationStack {
            List {
                section("In progress", items([.queued, .sending]))
                section("Needs attention", items([.failed]))
                section("Drafts on this phone", items([.localDraft]))
                section("Sent", items([.sent]))
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView("Outbox empty", systemImage: "tray",
                                           description: Text("Queued posts wait here until they reach kof22.com."))
                }
            }
            .refreshable { await app.processor.drain() }
            .navigationTitle("Outbox")
            .toolbar {
                if !items([.queued, .failed]).isEmpty {
                    Button("Send now") {
                        Task {
                            try? await app.store.retryAll()
                            await app.processor.drain()
                        }
                    }.accessibilityIdentifier("outbox.sendNow")
                }
            }
            .sheet(item: $editingDraft) { draft in
                NavigationStack {
                    ComposeView(model: ComposeModel(app: app, composition: draft.composition, draftID: draft.id)) {
                        editingDraft = nil
                    }
                    .navigationTitle("Draft")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { editingDraft = nil } } }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [OutboxItem]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { item in
                    OutboxRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { if item.state == .localDraft { editingDraft = item } }
                        .swipeActions {
                            if item.state != .sending {
                                Button("Delete", role: .destructive) { Task { try? await app.store.delete(item.id) } }
                            }
                            if item.state == .failed {
                                Button("Retry") { retry(item) }.tint(Theme.accent)
                            }
                        }
                }
            }
        }
    }

    private func retry(_ item: OutboxItem) {
        let id = item.id
        Task {
            try? await app.store.retry(id)
            app.kickOutbox()
        }
    }
}

struct OutboxRow: View {
    @Environment(AppModel.self) private var app
    let item: OutboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                icon
                Text(item.summary).font(.body.weight(.medium)).foregroundStyle(Theme.heading).lineLimit(2)
                Spacer()
                Text(item.updatedAt, style: .relative).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
            }
            detail
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("outbox.row")
    }

    private var operationLabel: String {
        switch item.operation {
        case .create: let c = item.composition; return c.status == .published ? "post" : c.status.label.lowercased()
        case .update: return "edit"
        case .delete: return "delete"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .queued: Image(systemName: "clock").foregroundStyle(Theme.muted)
        case .sending: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
        case .sent: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
        case .localDraft: Image(systemName: "doc").foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let photos = item.composition.photos.count
        HStack(spacing: 8) {
            Text(operationLabel).font(Theme.mono(.caption2)).foregroundStyle(Theme.accent)
            if photos > 0 { Label("\(photos)", systemImage: "photo").font(.caption2).foregroundStyle(Theme.muted) }
            switch item.state {
            case .sending:
                Text(item.phase ?? "Sending").font(.caption).foregroundStyle(Theme.body)
            case .queued:
                if let next = item.nextAttemptAt, next > .now {
                    Text("Retrying \(next, style: .relative)").font(.caption).foregroundStyle(Theme.muted)
                } else {
                    Text("Waiting to send").font(.caption).foregroundStyle(Theme.muted)
                }
            case .sent:
                if let url = item.resultURL.flatMap(URL.init(string:)) {
                    Link("Open", destination: url).font(.caption)
                }
            default:
                EmptyView()
            }
        }
        if item.state == .sending, item.progress > 0 {
            ProgressView(value: item.progress).tint(Theme.accent)
        }
        if item.state == .failed || (item.state == .queued && item.lastError != nil), let error = item.lastError {
            Text(error).font(.caption).foregroundStyle(item.state == .failed ? Theme.danger : Theme.muted)
        }
        if item.state == .failed {
            HStack {
                Button("Retry") {
                    let id = item.id
                    Task {
                        try? await app.store.retry(id)
                        app.kickOutbox()
                    }
                }
                if item.isConflict {
                    Button("Overwrite server copy") {
                        let id = item.id
                        Task { await app.processor.overwrite(id) }
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .tint(Theme.accent)
        }
    }
}
#endif
