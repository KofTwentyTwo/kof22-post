/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI

   /// When the post goes live (draft, now, or a scheduled time), whether it is featured,
   /// and the author it is posted as.
   struct ComposePublishSection: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The post being written.
      @Bindable var model: ComposeModel

      /// Seconds in a day.
      private static let secondsPerDay: TimeInterval = 86_400
      /// Days ahead a post can be scheduled.
      private static let schedulingHorizonDays: TimeInterval = 365
      /// A new schedule starts one hour ahead.
      static let defaultLead: TimeInterval = 3_600
      /// Shortest lead time offered, so the post is not already due when it is sent.
      private static let minimumLead: TimeInterval = 120

      /// The status picker, the schedule date, the featured switch and the author.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            Picker("Publish", selection: status) {
               Text("Draft").tag(PostStatus.draft)
               Text("Publish now").tag(PostStatus.published)
               Text("Schedule").tag(PostStatus.scheduled)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("compose.status")
            if model.composition.status == .scheduled {
               DatePicker("Publish at", selection: publishAt, in: Self.allowedRange)
                  .tint(Theme.accent)
                  .accessibilityIdentifier("compose.publishAt")
            }
            Toggle("Featured on kof22.com", isOn: featured)
               .tint(Theme.accent)
               .accessibilityIdentifier("compose.featured")
            authorRow
         }
         .padding(Theme.Spacing.large)
         .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      }

      /// "Posting as" with a menu of the authors the account may choose.
      @ViewBuilder private var authorRow: some View {
         let choices = app.authorChoices
         let selected = model.composition.authorId ?? app.me?.author?.id
         let name = choices.first { $0.id == selected }?.name ?? app.me?.author?.name ?? "Your author profile"
         HStack {
            Text("Posting as").foregroundStyle(Theme.muted)
            Spacer()
            if choices.count > 1 {
               Menu {
                  ForEach(choices) { author in
                     Button {
                        model.composition.authorId = author.id == app.me?.author?.id ? nil : author.id
                        model.changed()
                     } label: {
                        if author.id == selected {
                           Label(author.name, systemImage: "checkmark")
                        }
                        else {
                           Text(author.name)
                        }
                     }
                  }
               } label: {
                  Text(name).foregroundStyle(Theme.link)
               }
               .accessibilityIdentifier("compose.author")
            }
            else {
               Text(name).foregroundStyle(Theme.heading)
            }
         }
         .font(.subheadline)
      }

      /// The status; choosing Schedule starts an hour ahead when no time is set yet.
      private var status: Binding<PostStatus> {
         Binding(
            get: { model.composition.status },
            set: { value in
               model.composition.status = value
               if value == .scheduled, model.composition.publishAt.map({ $0 > Date.now }) != true {
                  model.composition.publishAt = Date.now.addingTimeInterval(Self.defaultLead)
               }
               model.changed()
            })
      }

      /// The scheduled time.
      private var publishAt: Binding<Date> {
         Binding(
            get: { model.composition.publishAt ?? Date.now.addingTimeInterval(Self.defaultLead) },
            set: { value in
               model.composition.publishAt = value
               model.changed()
            })
      }

      /// The featured switch.
      private var featured: Binding<Bool> {
         Binding(
            get: { model.composition.isFeatured },
            set: { value in
               model.composition.isFeatured = value
               model.changed()
            })
      }

      /// Dates a post can be scheduled for, measured from now.
      private static var allowedRange: ClosedRange<Date> {
         Date.now.addingTimeInterval(minimumLead)...Date.now.addingTimeInterval(schedulingHorizonDays * secondsPerDay)
      }
   }

   /// Name, short name, slug, description and SEO fields, filled by the on-device model
   /// (or simple rules) and editable. Blank fields are filled when the post is sent.
   struct ComposeDetailsSEOSection: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The post being written.
      @Bindable var model: ComposeModel
      /// Whether the fields are shown.
      @State private var expanded = false

      /// The line limit of a one-line field.
      private static let singleLine = 1...1

      /// A header with Suggest, then the fields when expanded.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            header
            if let reason = model.suggestionUnavailableReason {
               Text(reason).font(.caption).foregroundStyle(Theme.muted)
            }
            if let error = model.suggestionError {
               Text(error).font(.caption).foregroundStyle(Theme.warning)
            }
            if expanded { fields }
         }
         .padding(Theme.Spacing.large)
         .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      }

      /// "Details & SEO", a summary of the title, Suggest and the expand chevron.
      private var header: some View {
         HStack(alignment: .firstTextBaseline) {
            Button {
               withAnimation { expanded.toggle() }
            } label: {
               VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                  Text("Details & SEO").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.heading)
                  Text(summary).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
               }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("compose.details")
            Spacer()
            if model.isSuggesting {
               ProgressView().controlSize(.small)
            }
            else {
               Button {
                  Task { await model.suggest(overwrite: true) }
               } label: {
                  Label("Suggest", systemImage: "sparkles").font(.subheadline)
               }
               .accessibilityIdentifier("compose.suggest")
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(Theme.muted)
         }
      }

      /// What the post will be called, or a hint when nothing is filled in yet.
      private var summary: String {
         let draft = model.composition.draft()
         return model.composition.isEmpty ? "Filled in from your post" : "\(draft.title) · /\(draft.slug)"
      }

      /// The editable fields with their length counters.
      private var fields: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            field("Title", .title, \.title, limit: PostFieldLimits.title)
            field("Name", .name, \.name, limit: PostFieldLimits.name)
            field("Short name", .shortName, \.shortName, limit: PostFieldLimits.shortName)
            field("Slug", .slug, \.slug, limit: PostFieldLimits.slug)
               .textInputAutocapitalization(.never)
               .autocorrectionDisabled()
            Text(slugPreview).font(Theme.mono(.caption2)).foregroundStyle(Theme.link).lineLimit(1)
            field("Description", .description, \.description, limit: PostFieldLimits.description, multiline: true)
            field("SEO title", .metaTitle, \.metaTitle, limit: PostFieldLimits.seoTitleTarget)
            field("SEO description", .metaDescription, \.metaDescription, limit: PostFieldLimits.seoDescriptionTarget, multiline: true)
            field("Keywords", .metaKeywords, \.metaKeywords, limit: PostFieldLimits.metaKeywords)
            Text("Read time: \(model.composition.draft().readTime) min").font(.caption).foregroundStyle(Theme.muted)
         }
      }

      /// The address the post will have on kof22.com.
      private var slugPreview: String {
         "kof22.com/blogs/\(model.composition.blog)/\(model.composition.draft().slug)"
      }

      /// One labelled text field with a counter that turns to a warning past `limit`.
      /// Typing marks the field as edited, so automatic suggestions leave it alone.
      private func field(
         _ label: String, _ detail: PostDetailField, _ keyPath: WritableKeyPath<PostComposition, String>, limit: Int, multiline: Bool = false
      ) -> some View {
         let binding = Binding(
            get: { model.composition[keyPath: keyPath] },
            set: { value in
               model.composition[keyPath: keyPath] = value
               model.detailEdited(detail)
            })
         let count = model.composition[keyPath: keyPath].count
         return VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack {
               Text(label).font(.caption).foregroundStyle(Theme.muted)
               Spacer()
               Text("\(count)/\(limit)").font(Theme.mono(.caption2)).foregroundStyle(count > limit ? Theme.warning : Theme.muted)
            }
            TextField(label, text: binding, axis: multiline ? .vertical : .horizontal)
               .lineLimit(multiline ? Theme.LineLimit.captionField : Self.singleLine)
               .accessibilityIdentifier("compose.detail.\(detail.rawValue)")
         }
      }
   }
#endif
