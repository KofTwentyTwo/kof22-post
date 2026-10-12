/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftData
   import SwiftUI

   /// Everything not yet confirmed by the server, plus recent successes.
   public struct OutboxView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// Every outbox item, newest change first.
      @Query(sort: \OutboxItem.updatedAt, order: .reverse) private var items: [OutboxItem]
      /// Composer for the local draft being edited, if any.
      @State private var draftComposer: ComposeModel?
      /// A failed outbox action to report, or nil.
      @State private var errorMessage: String?

      /// Creates the Outbox screen.
      public init() {}

      /// Items in any of `states`, keeping the newest-first order.
      private func items(_ states: Set<OutboxState>) -> [OutboxItem] { items.filter { states.contains($0.state) } }

      /// Sections by state, pull to send, a Send now button and the draft composer sheet.
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
                  ContentUnavailableView(
                     "Outbox empty", systemImage: "tray",
                     description: Text("Queued posts wait here until they reach kof22.com."))
               }
            }
            .refreshable { await app.processor.drain() }
            .navigationTitle("Outbox")
            .toolbar {
               if !items([.queued, .failed]).isEmpty {
                  Button("Send now") { sendNow() }.accessibilityIdentifier("outbox.sendNow")
               }
            }
            ////////////////////////////////////////////////////////////////////////
            // The model is created once on tap; building it in the sheet body    //
            // would reset the composer every time the @Query above redraws.      //
            ////////////////////////////////////////////////////////////////////////
            .sheet(item: $draftComposer) { composer in
               NavigationStack {
                  ComposeView(model: composer) { draftComposer = nil }
                     .navigationTitle("Draft")
                     .navigationBarTitleDisplayMode(.inline)
                     .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { draftComposer = nil } } }
               }
            }
            .alert("Outbox", isPresented: errorIsPresented) {
               Button("OK", role: .cancel) {}
            } message: {
               Text(errorMessage ?? "")
            }
         }
      }

      /// A titled section of rows, omitted when `rows` is empty. Drafts open in the
      /// composer; swipe actions delete and retry.
      @ViewBuilder
      private func section(_ title: String, _ rows: [OutboxItem]) -> some View {
         if !rows.isEmpty {
            Section(title) {
               ForEach(rows) { item in
                  OutboxRow(item: item) { retry(item) }
                     .contentShape(Rectangle())
                     .onTapGesture {
                        if item.state == .localDraft {
                           draftComposer = ComposeModel(app: app, composition: item.composition, draftID: item.id)
                        }
                     }
                     .swipeActions {
                        if item.state != .sending {
                           Button("Delete", role: .destructive) { delete(item) }
                        }
                        if item.state == .failed {
                           Button("Retry") { retry(item) }.tint(Theme.accent)
                        }
                     }
               }
            }
         }
      }

      /// Shows `errorMessage` as an alert and clears it when dismissed.
      private var errorIsPresented: Binding<Bool> {
         Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
      }

      /// Makes every queued and failed item due now, then sends.
      private func sendNow() {
         Task {
            do {
               try await app.store.retryAll()
            }
            catch {
               report(error, doing: "Could not retry the queued posts")
            }
            await app.processor.drain()
         }
      }

      /// Makes one failed item due now and starts sending.
      private func retry(_ item: OutboxItem) {
         let id = item.id
         Task {
            do {
               try await app.store.retry(id)
            }
            catch {
               report(error, doing: "Could not retry the post")
            }
            app.kickOutbox()
         }
      }

      /// Removes an item from the outbox.
      private func delete(_ item: OutboxItem) {
         let id = item.id
         Task {
            do {
               try await app.store.delete(id)
            }
            catch {
               report(error, doing: "Could not delete the item")
            }
         }
      }

      /// Logs a failed outbox action and shows it to the user.
      private func report(_ error: any Error, doing action: String) {
         Log.outbox.warning("\(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
         errorMessage = "\(action): \(error.localizedDescription)"
      }
   }

   /// One outbox item: state icon, summary, age, and state-specific detail and actions.
   struct OutboxRow: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The item shown.
      let item: OutboxItem
      /// Retries the item; the Outbox screen owns error reporting.
      let onRetry: () -> Void

      /// Icon, summary and relative time, with the detail lines below.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline) {
               icon
               Text(item.summary).font(.body.weight(.medium)).foregroundStyle(Theme.heading).lineLimit(Theme.LineLimit.title)
               Spacer()
               Text(item.updatedAt.formatted(.relative(presentation: .named))).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
            }
            detail
         }
         .padding(.vertical, Theme.Spacing.xSmall)
         .accessibilityElement(children: .combine)
         .accessibilityIdentifier("outbox.row")
      }

      /// What the item does on the server: "post", "draft", "scheduled", "edit" or "delete".
      private var operationLabel: String {
         switch item.operation {
         case .create:
            let composition = item.composition
            return composition.status == .published ? "post" : composition.status.label.lowercased()
         case .update: return "edit"
         case .delete: return "delete"
         }
      }

      /// Clock, spinner, warning, check mark or document, by state.
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

      /// The status line, upload progress, the last error and, for failures, the actions.
      @ViewBuilder
      private var detail: some View {
         statusLine
         if item.state == .sending, item.progress > 0 {
            ProgressView(value: item.progress).tint(Theme.accent)
         }
         if item.state == .failed || (item.state == .queued && item.lastError != nil), let error = item.lastError {
            Text(error).font(.caption).foregroundStyle(item.state == .failed ? Theme.danger : Theme.muted)
         }
         if item.state == .failed {
            failureActions
         }
      }

      /// Operation, photo count and what is happening now (phase, retry time, Open link).
      private var statusLine: some View {
         HStack(spacing: Theme.Spacing.medium) {
            Text(item.state.displayName).font(Theme.mono(.caption2, weight: .medium)).foregroundStyle(Theme.heading)
            Text(operationLabel).font(Theme.mono(.caption2)).foregroundStyle(Theme.accent)
            if !item.composition.photos.isEmpty {
               Label("\(item.composition.photos.count)", systemImage: "photo").font(.caption2).foregroundStyle(Theme.muted)
            }
            stateText
         }
      }

      /// The state-specific part of the status line.
      @ViewBuilder
      private var stateText: some View {
         switch item.state {
         case .sending:
            Text(item.phase ?? "Sending").font(.caption).foregroundStyle(Theme.body)
         case .queued:
            if let next = item.nextAttemptAt, next > .now {
               Text("Retrying \(next.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(Theme.muted)
            }
            else {
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

      /// Retry and, for a version conflict, overwrite the server copy.
      private var failureActions: some View {
         HStack {
            Button("Retry", action: onRetry)
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
#endif
