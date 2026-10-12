/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI
   import Textual

   /// The prompt line and the blog picker at the top of the composer.
   struct ComposeHeader: View {
      /// The app's composition root, for the blog list.
      @Environment(AppModel.self) private var app
      /// The post being written.
      @Bindable var model: ComposeModel
      /// Whether the prompt shows a blinking cursor (empty post, no focus).
      let showsCursor: Bool

      /// The prompt above the blog picker.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            PromptLabel("~/blogs/\(model.composition.blog)", cursor: showsCursor)
            blogPicker
         }
      }

      /// Display name of the selected blog, or its slug when the account does not list it.
      private var blogName: String {
         app.blogs.first { $0.slug == model.composition.blog }?.name ?? model.composition.blog
      }

      /// Which blog this post goes to; changeable for new posts and edits.
      private var blogPicker: some View {
         HStack(spacing: Theme.Spacing.medium) {
            Text("Post to").font(Theme.mono(.caption)).foregroundStyle(Theme.muted)
            Menu {
               Picker("Blog", selection: $model.composition.blog) {
                  ForEach(app.blogs) { blog in
                     Text(blog.name).tag(blog.slug)
                  }
               }
            } label: {
               HStack(spacing: Theme.Spacing.xSmall) {
                  Text(blogName)
                  Image(systemName: "chevron.up.chevron.down").font(.caption2)
               }
               .font(Theme.mono(.callout, weight: .semibold))
               .foregroundStyle(Theme.accent)
               .padding(.horizontal, Theme.Spacing.regular)
               .padding(.vertical, Theme.Spacing.compact)
               .overlay(Capsule().stroke(Theme.accent.opacity(Theme.Opacity.outline)))
            }
            .onChange(of: model.composition.blog) { _, _ in
               model.changed()
               model.tagInputChanged()
            }
            .accessibilityLabel("Blog: \(blogName)")
            .accessibilityHint("Choose which blog to post to")
            .accessibilityIdentifier("compose.blogMenu")
            Spacer()
         }
      }
   }

   /// The Write/Preview switch with the Markdown editor or its rendered preview.
   struct ComposeEditor: View {
      /// The post being written.
      @Bindable var model: ComposeModel
      /// Whether the preview is shown instead of the editor.
      @Binding var preview: Bool
      /// The composer's keyboard focus.
      var focus: FocusState<ComposeView.Field?>.Binding

      /// The mode switch above the editor or the preview.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Picker("Mode", selection: $preview) {
               Text("Write").tag(false)
               Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: Theme.Size.modePickerMaxWidth)
            .accessibilityIdentifier("compose.previewToggle")

            if preview {
               renderedPreview
            }
            else {
               textEditor
            }
         }
      }

      /// The body rendered as Markdown, followed by the photos as they will appear.
      private var renderedPreview: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            if model.composition.body.isEmpty && model.composition.photos.isEmpty {
               Text("Nothing to preview").foregroundStyle(Theme.muted)
            }
            else {
               StructuredText(markdown: model.composition.body)
               ForEach(model.composition.photos) { photo in
                  PhotoPreview(photo: photo)
               }
            }
         }
         .frame(maxWidth: .infinity, minHeight: Theme.Size.editorMinHeight, alignment: .topLeading)
         .padding(Theme.Spacing.regular)
         .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      }

      /// The text editor with a placeholder, outlined in the accent while focused.
      private var textEditor: some View {
         ZStack(alignment: .topLeading) {
            if model.composition.body.isEmpty {
               Text("What's happening? Markdown works.")
                  .foregroundStyle(Theme.muted)
                  .padding(.top, Theme.Spacing.medium)
                  .padding(.leading, Theme.Spacing.compact)
                  .allowsHitTesting(false)
            }
            TextEditor(text: $model.composition.body)
               .focused(focus, equals: .body)
               .frame(minHeight: Theme.Size.editorMinHeight)
               .scrollContentBackground(.hidden)
               .onChange(of: model.composition.body) { model.changed() }
               .accessibilityLabel("Post text")
               .accessibilityIdentifier("compose.body")
         }
         .padding(Theme.Spacing.small)
         .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
         .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
               .stroke(focus.wrappedValue == .body ? Theme.accent.opacity(Theme.Opacity.focusRing) : Theme.border))
      }
   }

   /// Thumbnails of the attached photos with an ALT badge on those without alt text.
   struct ComposePhotoStrip: View {
      /// The post being written.
      @Bindable var model: ComposeModel
      /// Set to open a photo's alt-text sheet.
      @Binding var editingPhoto: ComposedPhoto?
      /// Set to open the arrange sheet.
      @Binding var arranging: Bool

      /// The strip, shown only when there are photos or some are loading.
      var body: some View {
         if !model.composition.photos.isEmpty || model.isLoadingPhotos {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
               ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: Theme.Spacing.medium) {
                     ForEach(model.composition.photos) { photo in
                        thumbnailButton(for: photo)
                     }
                     if model.isLoadingPhotos {
                        ProgressView().frame(width: Theme.Size.stripThumbnail, height: Theme.Size.stripThumbnail)
                     }
                  }
               }
               footer
            }
         }
      }

      /// A thumbnail that opens the photo's sheet, badged when alt text is missing.
      private func thumbnailButton(for photo: ComposedPhoto) -> some View {
         Button {
            editingPhoto = photo
         } label: {
            PhotoThumbnail(photo: photo, size: Theme.Size.stripThumbnail)
               .overlay(alignment: .bottomLeading) {
                  if photo.altText.isEmpty {
                     Text("ALT").font(Theme.mono(.caption2, weight: .bold))
                        .padding(Theme.Spacing.badgeInset)
                        .background(Theme.warning, in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                        .foregroundStyle(.black).padding(Theme.Spacing.xSmall)
                  }
               }
         }
         .accessibilityLabel(photo.altText.isEmpty ? "Photo without alt text" : "Photo: \(photo.altText)")
         .accessibilityHint("Edit alt text or remove")
      }

      /// The missing-alt-text count and, with two or more photos, the Arrange button.
      private var footer: some View {
         HStack {
            if model.photosMissingAltText > 0 {
               Label("\(model.photosMissingAltText) without alt text", systemImage: "text.below.photo")
                  .font(.caption).foregroundStyle(Theme.warning)
            }
            Spacer()
            if model.composition.photos.count > 1 {
               Button("Arrange") { arranging = true }.font(.caption)
            }
         }
      }
   }

   /// Tag chips, the tag field and, while it has focus, matching existing tags.
   struct ComposeTagsSection: View {
      /// The post being written.
      @Bindable var model: ComposeModel
      /// The composer's keyboard focus.
      var focus: FocusState<ComposeView.Field?>.Binding

      /// Chips above the field, suggestions below it.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if !model.composition.tags.isEmpty {
               FlowLayout(spacing: Theme.Spacing.small) {
                  ForEach(model.composition.tags, id: \.self) { tag in
                     TagChip(tag) { model.removeTag(tag) }
                  }
               }
            }
            tagField
            if focus.wrappedValue == .tags && !model.tagSuggestions.isEmpty {
               suggestions
            }
         }
      }

      /// The `#` prompt and the tag input; Return or a comma adds the tag.
      private var tagField: some View {
         HStack {
            Text("#").font(Theme.mono()).foregroundStyle(Theme.accent)
            TextField("Add tags", text: $model.tagInput)
               .font(Theme.mono(.callout))
               .textInputAutocapitalization(.never)
               .autocorrectionDisabled()
               .focused(focus, equals: .tags)
               .submitLabel(.done)
               .onSubmit { model.addTag(model.tagInput) }
               .onChange(of: model.tagInput) { model.tagInputChanged() }
               .onChange(of: focus.wrappedValue) { _, field in if field == .tags { model.tagInputChanged() } }
               .accessibilityIdentifier("compose.tags")
         }
      }

      /// A horizontal row of suggested tags; tapping one adds it.
      private var suggestions: some View {
         ScrollView(.horizontal, showsIndicators: false) {
            HStack {
               ForEach(model.tagSuggestions) { tag in
                  Button {
                     model.addTag(tag.name)
                  } label: {
                     TagChip(tag.name)
                  }
                  .buttonStyle(.plain)
               }
            }
         }
      }
   }

   /// The link field with its preview, the location label and the photo-location toggle.
   struct ComposeDetailsSection: View {
      /// The post being written.
      @Bindable var model: ComposeModel
      /// The composer's keyboard focus.
      var focus: FocusState<ComposeView.Field?>.Binding

      /// The details card.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.regular) {
            linkField
            if let preview = model.linkPreview {
               LinkPreviewCard(preview: preview)
            }
            else if let error = model.linkPreviewError {
               Text(error).font(.caption).foregroundStyle(Theme.muted)
            }
            locationField
            if !model.composition.photos.isEmpty {
               Text("Photo location (GPS) is removed unless you turn it on for a photo: tap the photo.")
                  .font(.caption).foregroundStyle(Theme.muted)
            }
         }
         .padding(Theme.Spacing.large)
         .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      }

      /// The URL field; edits refresh the preview.
      private var linkField: some View {
         HStack {
            Image(systemName: "link").foregroundStyle(Theme.muted)
            TextField("https://", text: $model.composition.linkURL)
               .keyboardType(.URL)
               .textInputAutocapitalization(.never)
               .autocorrectionDisabled()
               .focused(focus, equals: .link)
               .onChange(of: model.composition.linkURL) { model.linkChanged() }
               .accessibilityIdentifier("compose.link")
         }
      }

      /// The location label with a button that fills it from the current position.
      private var locationField: some View {
         HStack {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.muted)
            TextField("Location label (optional)", text: $model.composition.locationLabel)
               .focused(focus, equals: .location)
               .onChange(of: model.composition.locationLabel) { model.changed() }
            if model.isLocating {
               ProgressView().controlSize(.small)
            }
            else {
               Button {
                  Task { await model.useCurrentLocation() }
               } label: {
                  Image(systemName: "location.fill")
               }
               .accessibilityLabel("Use current location")
            }
         }
      }
   }
#endif
