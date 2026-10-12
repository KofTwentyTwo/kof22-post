/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import PhotosUI
   import SwiftUI

   /// The composer: opens with the keyboard up on the body field. The sections live in
   /// their own views; this view owns the focus, the sheets and the alerts.
   public struct ComposeView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The post being written.
      @Bindable var model: ComposeModel
      /// Called after a successful submit or discard when the composer is presented
      /// modally (drafts, edits, Share Extension); nil for the Compose tab.
      let onDone: (() -> Void)?

      /// The field with keyboard focus.
      @FocusState private var focus: Field?
      /// Whether the editor shows the rendered preview instead of the text.
      @State private var preview = false
      /// Items chosen in the photo picker, consumed as soon as they arrive.
      @State private var pickerItems: [PhotosPickerItem] = []
      /// Whether the camera is presented.
      @State private var showCamera = false
      /// Whether the schedule sheet is presented.
      @State private var showSchedule = false
      /// Date chosen in the schedule sheet; one hour ahead by default.
      @State private var scheduleDate = Date.now.addingTimeInterval(ComposeScheduleSheet.defaultLead)
      /// Photo whose alt-text sheet is open.
      @State private var editingPhoto: ComposedPhoto?
      /// Whether the arrange-photos sheet is presented.
      @State private var arranging = false
      /// Whether the link and location section is expanded.
      @State private var showDetails = false
      /// Whether the discard confirmation is shown.
      @State private var confirmDiscard = false
      /// Whether the photo picker is presented.
      @State private var showPhotoPicker = false
      /// Whether the "allow full photo access" alert is shown.
      @State private var photoAccessPrompt = false

      /// Fields that can hold keyboard focus.
      enum Field {
         /// The Markdown body.
         case body
         /// The optional title.
         case title
         /// The tag input.
         case tags
         /// The link URL.
         case link
         /// The location label.
         case location
      }

      /// Creates a composer for `model`; `onDone` makes it behave as a modal.
      public init(model: ComposeModel, onDone: (() -> Void)? = nil) {
         self.model = model
         self.onDone = onDone
      }

      /// The composer with its sheets, alerts and the discard confirmation attached.
      public var body: some View {
         composer
            .sheet(item: $editingPhoto) { photo in
               PhotoDetailSheet(photo: photo, onSave: model.update, onRemove: model.removePhoto)
            }
            .sheet(isPresented: $arranging) { ArrangePhotosSheet(model: model) }
            .sheet(isPresented: $showSchedule) {
               ComposeScheduleSheet(date: $scheduleDate, isPresented: $showSchedule) { date in submit(.scheduled, at: date) }
            }
            .fullScreenCover(isPresented: $showCamera) {
               CameraPicker { data in model.addPhoto(data: data, ext: CameraPicker.fileExtension) }.ignoresSafeArea()
            }
            .alert("Heads up", isPresented: messageIsPresented) {
               Button("OK", role: .cancel) {}
            } message: {
               Text(model.message ?? "")
            }
            .confirmationDialog("Discard this post?", isPresented: $confirmDiscard, titleVisibility: .visible) {
               Button("Discard", role: .destructive) {
                  Task {
                     await model.discard()
                     onDone?()
                  }
               }
            }
      }

      /// The scrolling form, the action bar, the keyboard toolbar and the photo picker.
      private var composer: some View {
         ScrollView {
            sections.padding()
         }
         .scrollDismissesKeyboard(.interactively)
         .background(Theme.background)
         .safeAreaInset(edge: .bottom) { actionBar }
         .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
               Spacer()
               Button("Done") { focus = nil }.accessibilityIdentifier("keyboard.done")
            }
         }
         .onAppear { if model.composition.body.isEmpty { focus = .body } }
         .onChange(of: preview) { _, isPreview in
            ///////////////////////////////////////////////////////////////
            // Reading the preview needs the whole screen: drop focus so //
            // the keyboard goes away from whichever field had it.       //
            ///////////////////////////////////////////////////////////////
            if isPreview { focus = nil }
         }
         .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
               await model.addPhotos(items)
               pickerItems = []
            }
         }
         .photosPicker(
            isPresented: $showPhotoPicker, selection: $pickerItems,
            maxSelectionCount: max(model.limits.maxPhotosPerPost - model.composition.photos.count, 1),
            matching: .images, photoLibrary: .shared()
         )
         .alert("Allow full photo access", isPresented: $photoAccessPrompt) {
            Button("Open Settings") { Permissions.shared.openSettings() }
            Button("Pick anyway") { showPhotoPicker = true }
            Button("Cancel", role: .cancel) {}
         } message: {
            Text(
               "KoF22 Postr works best with access to all photos, so it can upload originals and keep their location when you ask. Choose \"Full Access\" in Settings › Privacy › Photos."
            )
         }
      }

      /// Header, optional title, editor, photos, tags and, when used, link and location.
      private var sections: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            ComposeHeader(model: model, showsCursor: focus == nil && model.composition.isEmpty)
            if model.showTitle { titleField }
            ComposeEditor(model: model, preview: $preview, focus: $focus)
            ComposePhotoStrip(model: model, editingPhoto: $editingPhoto, arranging: $arranging)
            ComposeTagsSection(model: model, focus: $focus)
            if showDetails || !model.composition.linkURL.isEmpty || !model.composition.locationLabel.isEmpty {
               ComposeDetailsSection(model: model, focus: $focus)
            }
         }
      }

      /// The optional title; Return moves on to the body.
      private var titleField: some View {
         TextField("Title (optional)", text: $model.composition.title)
            .font(.title3.weight(.semibold))
            .focused($focus, equals: .title)
            .submitLabel(.next)
            .onSubmit { focus = .body }
            .onChange(of: model.composition.title) { model.changed() }
            .accessibilityIdentifier("compose.title")
      }

      /// The bottom bar with the attachment buttons, the options menu and Post.
      private var actionBar: some View {
         ComposeActionBar(
            model: model, isModal: onDone != nil, focus: $focus, showPhotoPicker: $showPhotoPicker,
            photoAccessPrompt: $photoAccessPrompt, showCamera: $showCamera, showDetails: $showDetails,
            showSchedule: $showSchedule, confirmDiscard: $confirmDiscard
         ) { status in
            submit(status)
         }
      }

      /// Presents the model's message as an alert and clears it when dismissed.
      private var messageIsPresented: Binding<Bool> {
         Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })
      }

      /// Queues the post. A modal composer then closes; the Compose tab clears itself and
      /// switches to the Outbox so the post can be followed.
      private func submit(_ status: PostStatus, at date: Date? = nil) {
         Task {
            if await model.submit(as: status, publishAt: date) {
               focus = nil
               if model.isEditing || onDone != nil {
                  onDone?()
               }
               else {
                  model.reset()
                  app.selectedTab = .outbox
               }
            }
         }
      }
   }
#endif
