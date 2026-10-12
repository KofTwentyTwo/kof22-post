/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI
   import UIKit

   /// The composer's bottom bar: photo, camera, link and location buttons, the options
   /// menu and the Post (or Save) button.
   struct ComposeActionBar: View {
      /// The post being written.
      @Bindable var model: ComposeModel
      /// Whether the composer is presented modally, which keeps the options menu available
      /// even for an empty post.
      let isModal: Bool
      /// The composer's keyboard focus.
      var focus: FocusState<ComposeView.Field?>.Binding
      /// Presents the photo picker.
      @Binding var showPhotoPicker: Bool
      /// Presents the "allow full photo access" alert.
      @Binding var photoAccessPrompt: Bool
      /// Presents the camera.
      @Binding var showCamera: Bool
      /// Expands the link and location section.
      @Binding var showDetails: Bool
      /// Presents the schedule sheet.
      @Binding var showSchedule: Bool
      /// Shows the discard confirmation.
      @Binding var confirmDiscard: Bool
      /// Queues the post with the given status.
      let onSubmit: (PostStatus) -> Void

      /// The attachment buttons on the left, the menu and Post on the right.
      var body: some View {
         HStack(spacing: Theme.Spacing.xLarge) {
            photosButton
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
               Button {
                  showCamera = true
               } label: {
                  Image(systemName: "camera")
               }
               .accessibilityLabel("Take photo")
            }
            Button {
               showDetails.toggle()
               if showDetails { focus.wrappedValue = .link }
            } label: {
               Image(systemName: "link")
            }
            .accessibilityLabel("Add link")
            Button {
               showDetails = true
               Task { await model.useCurrentLocation() }
            } label: {
               Image(systemName: "location")
            }
            .accessibilityLabel("Add current location")
            Spacer()
            if !model.composition.isEmpty || isModal {
               optionsMenu
            }
            postButton
         }
         .font(.title3)
         .foregroundStyle(Theme.accent)
         .padding(.horizontal)
         .padding(.vertical, Theme.Spacing.regular)
         .background(.bar)
      }

      /// Asks for photo access first; with full access opens the picker, otherwise explains
      /// why full access helps.
      private var photosButton: some View {
         Button {
            Task {
               let status = await Permissions.shared.requestPhotos()
               if status == .authorized {
                  showPhotoPicker = true
               }
               else {
                  photoAccessPrompt = true
               }
            }
         } label: {
            Image(systemName: "photo.on.rectangle.angled")
         }
         .accessibilityLabel("Add photos")
         .accessibilityIdentifier("compose.addPhotos")
      }

      /// Title toggle, save as draft, schedule and discard.
      private var optionsMenu: some View {
         Menu {
            Toggle("Title", isOn: $model.showTitle)
            if !model.isEditing || model.composition.status != .published {
               Button("Save as draft", systemImage: "doc") { onSubmit(.draft) }
            }
            Button("Schedule…", systemImage: "calendar.badge.clock") { showSchedule = true }
            if !model.isEditing {
               Button("Discard", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            }
         } label: {
            Image(systemName: "ellipsis.circle")
         }
         .accessibilityLabel("More options")
         .accessibilityIdentifier("compose.more")
      }

      /// Publishes a new post, or saves an edit with its current status (published when it
      /// already is). Dimmed and disabled while the post is empty or being queued.
      private var postButton: some View {
         Button {
            onSubmit(model.isEditing && model.composition.status != .published ? model.composition.status : .published)
         } label: {
            Text(model.isEditing ? "Save" : "Post")
               .font(Theme.mono(.body, weight: .bold))
               .padding(.horizontal, Theme.Spacing.buttonHorizontal)
               .padding(.vertical, Theme.Spacing.medium)
               .background(Theme.accent, in: Capsule())
               .foregroundStyle(Color.black)
         }
         .disabled(model.composition.isEmpty || model.isSubmitting)
         .opacity(model.composition.isEmpty ? Theme.Opacity.disabled : 1)
         .accessibilityIdentifier("compose.post")
      }
   }

   /// Picks the publish date for a scheduled post.
   struct ComposeScheduleSheet: View {
      /// Seconds in a day.
      private static let secondsPerDay: TimeInterval = 86_400
      /// Days ahead a post can be scheduled.
      private static let schedulingHorizonDays: TimeInterval = 365
      /// Default lead time for a new schedule: one hour.
      static let defaultLead: TimeInterval = 3600
      /// Shortest lead time accepted, so the post is not already due when it is sent.
      private static let minimumLead: TimeInterval = 120

      /// The chosen publish date.
      @Binding var date: Date
      /// Whether the sheet is shown.
      @Binding var isPresented: Bool
      /// Called with the chosen date when Schedule is tapped.
      let onSchedule: (Date) -> Void

      /// A graphical date picker from two minutes to a year ahead, with Cancel and Schedule.
      var body: some View {
         NavigationStack {
            Form {
               DatePicker("Publish at", selection: $date, in: Self.allowedRange)
                  .datePickerStyle(.graphical)
                  .tint(Theme.accent)
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
               ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } }
               ToolbarItem(placement: .confirmationAction) {
                  Button("Schedule") {
                     isPresented = false
                     onSchedule(date)
                  }
               }
            }
         }
         .presentationDetents([.large])
      }

      /// Dates a post can be scheduled for, measured from now.
      private static var allowedRange: ClosedRange<Date> {
         Date.now.addingTimeInterval(minimumLead)...Date.now.addingTimeInterval(schedulingHorizonDays * secondsPerDay)
      }
   }

   /// A compact card for a link's title, description and host.
   struct LinkPreviewCard: View {
      /// The preview to show.
      let preview: LinkPreview

      /// Title (or URL), up to three lines of description, and the host in link colour.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(preview.title ?? preview.url).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.heading)
            if let description = preview.description {
               Text(description).font(.caption).foregroundStyle(Theme.body).lineLimit(Theme.LineLimit.linkDescription)
            }
            Text(URL(string: preview.url)?.host() ?? preview.url).font(Theme.mono(.caption2)).foregroundStyle(Theme.link)
         }
         .frame(maxWidth: .infinity, alignment: .leading)
         .padding(Theme.Spacing.regular)
         .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border))
         .accessibilityElement(children: .combine)
      }
   }
#endif
