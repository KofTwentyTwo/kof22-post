/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI
   import UIKit

   /// Square thumbnail for a local (queued) or uploaded photo.
   struct PhotoThumbnail: View {
      /// The app's composition root, which resolves remote and mock photo URLs.
      @Environment(AppModel.self) private var app
      /// The photo to show.
      let photo: ComposedPhoto
      /// Edge length of the square.
      let size: CGFloat

      /// The local file if present, else the remote image, else a placeholder icon.
      var body: some View {
         Group {
            if let url = photo.localURL(), let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
               Image(uiImage: image).resizable().scaledToFill()
            }
            else if let url = app.photoURL(photo.remoteURL) {
               AsyncImage(url: url) { image in
                  image.resizable().scaledToFill()
               } placeholder: {
                  Theme.surface
               }
            }
            else {
               Theme.surface.overlay(Image(systemName: "photo").foregroundStyle(Theme.muted))
            }
         }
         .frame(width: size, height: size)
         .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
         .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.border))
      }
   }

   /// Full-width photo as it will appear in the post (used by Preview).
   struct PhotoPreview: View {
      /// The app's composition root, which resolves remote and mock photo URLs.
      @Environment(AppModel.self) private var app
      /// The photo to show.
      let photo: ComposedPhoto

      /// The photo at full width with its caption below.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Group {
               if let url = photo.localURL(), let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                  Image(uiImage: image).resizable().scaledToFit()
               }
               else if let url = app.photoURL(photo.remoteURL) {
                  AsyncImage(url: url) {
                     $0.resizable().scaledToFit()
                  } placeholder: {
                     Theme.surface.frame(height: Theme.Size.imagePlaceholder)
                  }
               }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .accessibilityLabel(photo.altText.isEmpty ? "Photo" : photo.altText)
            if !photo.caption.isEmpty { Text(photo.caption).font(.caption).foregroundStyle(Theme.muted) }
         }
      }
   }

   /// Alt text, caption and removal for one photo. Changes apply when Done is tapped.
   struct PhotoDetailSheet: View {
      /// Closes the sheet.
      @Environment(\.dismiss) private var dismiss
      /// A working copy of the photo, saved back on Done.
      @State var photo: ComposedPhoto
      /// Saves the edited photo.
      let onSave: (ComposedPhoto) -> Void
      /// Removes the photo from the post.
      let onRemove: (ComposedPhoto) -> Void

      /// The photo, the alt-text and caption fields and the remove button.
      var body: some View {
         NavigationStack {
            Form {
               Section {
                  HStack {
                     Spacer()
                     PhotoThumbnail(photo: photo, size: Theme.Size.detailThumbnail)
                     Spacer()
                  }
               }
               .listRowBackground(Color.clear)
               Section {
                  TextField("Describe the photo for screen readers", text: $photo.altText, axis: .vertical)
                     .lineLimit(Theme.LineLimit.altTextField)
                     .accessibilityIdentifier("photo.altText")
               } header: {
                  Text("Alt text")
               } footer: {
                  Text("Shown to people using VoiceOver and when images do not load.")
               }
               Section("Caption") {
                  TextField("Optional caption", text: $photo.caption, axis: .vertical).lineLimit(Theme.LineLimit.captionField)
               }
               Section {
                  Button("Remove photo", role: .destructive) {
                     onRemove(photo)
                     dismiss()
                  }
               }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
               ToolbarItem(placement: .confirmationAction) {
                  Button("Done") {
                     onSave(photo)
                     dismiss()
                  }
               }
            }
         }
      }
   }

   /// Reorders or deletes photos with the list's edit controls.
   struct ArrangePhotosSheet: View {
      /// Closes the sheet.
      @Environment(\.dismiss) private var dismiss
      /// The post being written.
      @Bindable var model: ComposeModel

      /// A list in edit mode with a thumbnail and the alt text for each photo.
      var body: some View {
         NavigationStack {
            List {
               ForEach(model.composition.photos) { photo in
                  HStack {
                     PhotoThumbnail(photo: photo, size: Theme.Size.listThumbnail)
                     Text(photo.altText.isEmpty ? "No alt text" : photo.altText)
                        .font(.callout)
                        .foregroundStyle(photo.altText.isEmpty ? Theme.warning : Theme.body)
                        .lineLimit(Theme.LineLimit.altTextLabel)
                  }
               }
               .onMove(perform: model.movePhotos)
               .onDelete { offsets in offsets.map { model.composition.photos[$0] }.forEach(model.removePhoto) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arrange photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
         }
      }
   }

   /// Camera capture via UIImagePickerController (PhotosPicker has no camera).
   struct CameraPicker: UIViewControllerRepresentable {
      /// Extension of the files produced from captures.
      static let fileExtension = "jpg"
      /// JPEG quality for captures: near-lossless while much smaller than 1.0.
      fileprivate static let jpegQuality: CGFloat = 0.92

      /// Receives the captured photo as JPEG data.
      let onCapture: (Data) -> Void
      /// Closes the camera.
      @Environment(\.dismiss) private var dismiss

      /// Creates a camera picker that reports to the coordinator.
      func makeUIViewController(context: Context) -> UIImagePickerController {
         let picker = UIImagePickerController()
         picker.sourceType = .camera
         picker.delegate = context.coordinator
         return picker
      }

      /// Nothing to update: the picker has no inputs from SwiftUI.
      func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

      /// Creates the delegate that forwards the capture.
      func makeCoordinator() -> Coordinator { Coordinator(self) }

      /// The picker's delegate.
      final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
         /// The representable that owns this coordinator.
         let parent: CameraPicker

         /// Creates a coordinator for `parent`.
         init(_ parent: CameraPicker) { self.parent = parent }

         /// Encodes the capture as JPEG, hands it over and closes the camera. A capture that
         /// cannot be encoded is logged and dropped; the user simply sees no new photo.
         func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: CameraPicker.jpegQuality) {
               parent.onCapture(data)
            }
            else {
               Log.media.warning("The camera capture could not be encoded as JPEG")
            }
            parent.dismiss()
         }

         /// Closes the camera without a photo.
         func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
      }
   }

   /// Wrapping layout for tag chips: fills a row, then starts the next one below.
   struct FlowLayout: Layout {
      /// Gap between chips and between rows.
      var spacing: CGFloat = Theme.Spacing.medium

      /// The proposed width (or the widest row) by the bottom of the last row.
      func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
         let rows = arrange(subviews, width: proposal.width ?? .infinity)
         return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.originY + $0.height } ?? 0)
      }

      /// Places each row's subviews left to right at their ideal size.
      func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
         for row in arrange(subviews, width: bounds.width) {
            var cursorX = bounds.minX
            for index in row.indices {
               let size = subviews[index].sizeThatFits(.unspecified)
               subviews[index].place(at: CGPoint(x: cursorX, y: bounds.minY + row.originY), proposal: ProposedViewSize(size))
               cursorX += size.width + spacing
            }
         }
      }

      /// One line of subviews.
      private struct Row {
         /// Indices of the subviews in this row.
         var indices: [Int] = []
         /// Top of the row relative to the layout's top.
         var originY: CGFloat = 0
         /// Width used so far, including trailing spacing.
         var width: CGFloat = 0
         /// Height of the tallest subview.
         var height: CGFloat = 0
      }

      /// Splits subviews into rows no wider than `width`; a subview wider than `width`
      /// still gets a row of its own.
      private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
         var rows = [Row()]
         for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let last = rows[rows.count - 1]
            if last.width + size.width > width, !last.indices.isEmpty {
               rows.append(Row(originY: last.originY + last.height + spacing))
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
         }
         return rows
      }
   }
#endif
