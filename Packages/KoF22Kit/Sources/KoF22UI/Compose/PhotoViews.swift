#if os(iOS)
import SwiftUI
import UIKit

/// Thumbnail for a local (queued) or uploaded photo.
struct PhotoThumbnail: View {
    @Environment(AppModel.self) private var app
    let photo: ComposedPhoto
    let size: CGFloat

    var body: some View {
        Group {
            if let url = photo.localURL(), let image = UIImage(contentsOfFile: url.path()) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = app.photoURL(photo.remoteURL) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Theme.surface }
            } else {
                Theme.surface.overlay(Image(systemName: "photo").foregroundStyle(Theme.muted))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

struct PhotoDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var photo: ComposedPhoto
    let onSave: (ComposedPhoto) -> Void
    let onRemove: (ComposedPhoto) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); PhotoThumbnail(photo: photo, size: 220); Spacer() }
                }
                .listRowBackground(Color.clear)
                Section {
                    TextField("Describe the photo for screen readers", text: $photo.altText, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("photo.altText")
                } header: {
                    Text("Alt text")
                } footer: {
                    Text("Shown to people using VoiceOver and when images do not load.")
                }
                Section("Caption") {
                    TextField("Optional caption", text: $photo.caption, axis: .vertical).lineLimit(1...4)
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

struct ArrangePhotosSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ComposeModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.composition.photos) { photo in
                    HStack {
                        PhotoThumbnail(photo: photo, size: 56)
                        Text(photo.altText.isEmpty ? "No alt text" : photo.altText)
                            .font(.callout)
                            .foregroundStyle(photo.altText.isEmpty ? Theme.warning : Theme.body)
                            .lineLimit(2)
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
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.92) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
#endif
