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
      /// Shows the discard confirmation.
      @Binding var confirmDiscard: Bool
      /// Queues the post with the status chosen in the publish section.
      let onSubmit: () -> Void

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

      /// Title toggle and discard.
      private var optionsMenu: some View {
         Menu {
            Toggle("Title", isOn: $model.showTitle)
            if !model.isEditing {
               Button("Discard", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            }
         } label: {
            Image(systemName: "ellipsis.circle")
         }
         .accessibilityLabel("More options")
         .accessibilityIdentifier("compose.more")
      }

      /// Sends the post with the status chosen in the publish section; the label says
      /// what will happen. Dimmed and disabled while the post is empty or being queued.
      private var postButton: some View {
         Button {
            onSubmit()
         } label: {
            Text(postLabel)
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

   extension ComposeActionBar {
      /// "Save" for edits, else what the chosen status does.
      var postLabel: String {
         if model.isEditing { return "Save" }
         switch model.composition.status {
         case .draft: return "Save draft"
         case .scheduled: return "Schedule"
         case .published: return "Post"
         }
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
