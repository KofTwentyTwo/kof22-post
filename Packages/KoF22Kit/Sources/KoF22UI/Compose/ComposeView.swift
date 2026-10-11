#if os(iOS)
import PhotosUI
import SwiftUI
import Textual

/// The composer: opens with the keyboard up on the body field.
public struct ComposeView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ComposeModel
    let onDone: (() -> Void)?

    @FocusState private var focus: Field?
    @State private var preview = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showSchedule = false
    @State private var scheduleDate = Date.now.addingTimeInterval(3600)
    @State private var editingPhoto: ComposedPhoto?
    @State private var arranging = false
    @State private var showDetails = false
    @State private var confirmDiscard = false

    enum Field { case body, title, tags, link, location }

    public init(model: ComposeModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.showTitle { titleField }
                editor
                photoStrip
                tagsSection
                if showDetails || !model.composition.linkURL.isEmpty || !model.composition.locationLabel.isEmpty {
                    detailsSection
                }
            }
            .padding()
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
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await model.addPhotos(items)
                pickerItems = []
            }
        }
        .sheet(item: $editingPhoto) { photo in
            PhotoDetailSheet(photo: photo, onSave: model.update, onRemove: model.removePhoto)
        }
        .sheet(isPresented: $arranging) { ArrangePhotosSheet(model: model) }
        .sheet(isPresented: $showSchedule) { scheduleSheet }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in model.addPhoto(data: data, ext: "jpg") }.ignoresSafeArea()
        }
        .alert("Heads up", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
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

    // MARK: Sections

    private var header: some View {
        HStack {
            PromptLabel("~/blogs/\(model.composition.blog)", cursor: focus == nil && model.composition.isEmpty)
            Spacer()
            Menu {
                Picker("Blog", selection: $model.composition.blog) {
                    ForEach(app.blogs) { blog in Text(blog.name).tag(blog.slug) }
                }
                Toggle("Title", isOn: $model.showTitle)
                Toggle("Link & location", isOn: $showDetails)
            } label: {
                Label(app.blogs.first { $0.slug == model.composition.blog }?.name ?? model.composition.blog,
                      systemImage: "chevron.up.chevron.down")
                    .font(Theme.mono(.caption, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Blog and options")
            .accessibilityIdentifier("compose.blogMenu")
        }
    }

    private var titleField: some View {
        TextField("Title (optional)", text: $model.composition.title)
            .font(.title3.weight(.semibold))
            .focused($focus, equals: .title)
            .submitLabel(.next)
            .onSubmit { focus = .body }
            .onChange(of: model.composition.title) { model.changed() }
            .accessibilityIdentifier("compose.title")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: $preview) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
            .accessibilityIdentifier("compose.previewToggle")

            if preview {
                Group {
                    if model.composition.body.isEmpty {
                        Text("Nothing to preview").foregroundStyle(Theme.muted)
                    } else {
                        StructuredText(markdown: model.composition.body)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack(alignment: .topLeading) {
                    if model.composition.body.isEmpty {
                        Text("What's happening? Markdown works.")
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.composition.body)
                        .focused($focus, equals: .body)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .onChange(of: model.composition.body) { model.changed() }
                        .accessibilityLabel("Post text")
                        .accessibilityIdentifier("compose.body")
                }
                .padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(focus == .body ? Theme.accent.opacity(0.6) : Theme.border))
            }
        }
    }

    @ViewBuilder
    private var photoStrip: some View {
        if !model.composition.photos.isEmpty || model.isLoadingPhotos {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.composition.photos) { photo in
                            Button { editingPhoto = photo } label: {
                                PhotoThumbnail(photo: photo, size: 84)
                                    .overlay(alignment: .bottomLeading) {
                                        if photo.altText.isEmpty {
                                            Text("ALT").font(Theme.mono(.caption2, weight: .bold))
                                                .padding(3).background(Theme.warning, in: RoundedRectangle(cornerRadius: 3))
                                                .foregroundStyle(.black).padding(4)
                                        }
                                    }
                            }
                            .accessibilityLabel(photo.altText.isEmpty ? "Photo without alt text" : "Photo: \(photo.altText)")
                            .accessibilityHint("Edit alt text or remove")
                        }
                        if model.isLoadingPhotos { ProgressView().frame(width: 84, height: 84) }
                    }
                }
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
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.composition.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(model.composition.tags, id: \.self) { tag in
                        TagChip(tag) { model.removeTag(tag) }
                    }
                }
            }
            HStack {
                Text("#").font(Theme.mono()).foregroundStyle(Theme.accent)
                TextField("Add tags", text: $model.tagInput)
                    .font(Theme.mono(.callout))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .tags)
                    .submitLabel(.done)
                    .onSubmit { model.addTag(model.tagInput) }
                    .onChange(of: model.tagInput) { model.tagInputChanged() }
                    .onChange(of: focus) { _, field in if field == .tags { model.tagInputChanged() } }
                    .accessibilityIdentifier("compose.tags")
            }
            if focus == .tags && !model.tagSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.tagSuggestions) { tag in
                            Button { model.addTag(tag.name) } label: { TagChip(tag.name) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "link").foregroundStyle(Theme.muted)
                TextField("https://", text: $model.composition.linkURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .link)
                    .onChange(of: model.composition.linkURL) { model.linkChanged() }
                    .accessibilityIdentifier("compose.link")
            }
            if let preview = model.linkPreview {
                LinkPreviewCard(preview: preview)
            } else if let error = model.linkPreviewError {
                Text(error).font(.caption).foregroundStyle(Theme.muted)
            }
            HStack {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.muted)
                TextField("Location label (optional)", text: $model.composition.locationLabel)
                    .focused($focus, equals: .location)
                    .onChange(of: model.composition.locationLabel) { model.changed() }
            }
            if !model.composition.photos.isEmpty {
                Toggle(isOn: $model.composition.keepLocation) {
                    VStack(alignment: .leading) {
                        Text("Keep photo location")
                        Text("GPS data in photos is removed unless you turn this on. It will be public.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.accent)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: max(model.limits.maxPhotosPerPost - model.composition.photos.count, 1),
                         matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .accessibilityLabel("Add photos")
            .accessibilityIdentifier("compose.addPhotos")
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Image(systemName: "camera") }
                    .accessibilityLabel("Take photo")
            }
            Button { showDetails.toggle(); if showDetails { focus = .link } } label: { Image(systemName: "link") }
                .accessibilityLabel("Add link or location")
            Spacer()
            if !model.composition.isEmpty || onDone != nil {
                Menu {
                    if !model.isEditing || model.composition.status != .published {
                        Button("Save as draft", systemImage: "doc") { submit(.draft) }
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
            Button {
                submit(model.isEditing && model.composition.status != .published ? model.composition.status : .published)
            } label: {
                Text(model.isEditing ? "Save" : "Post")
                    .font(Theme.mono(.body, weight: .bold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(Color.black)
            }
            .disabled(model.composition.isEmpty || model.isSubmitting)
            .opacity(model.composition.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("compose.post")
        }
        .font(.title3)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var scheduleSheet: some View {
        NavigationStack {
            Form {
                DatePicker("Publish at", selection: $scheduleDate, in: Date.now.addingTimeInterval(120)...Date.now.addingTimeInterval(365 * 86400))
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)
            }
            .navigationTitle("Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSchedule = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        showSchedule = false
                        submit(.scheduled, at: scheduleDate)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func submit(_ status: PostStatus, at date: Date? = nil) {
        Task {
            if await model.submit(as: status, publishAt: date) {
                focus = nil
                if model.isEditing || onDone != nil {
                    onDone?()
                } else {
                    model.reset()
                    app.selectedTab = .outbox
                }
            }
        }
    }
}

struct LinkPreviewCard: View {
    let preview: LinkPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview.title ?? preview.url).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.heading)
            if let description = preview.description { Text(description).font(.caption).foregroundStyle(Theme.body).lineLimit(3) }
            Text(URL(string: preview.url)?.host() ?? preview.url).font(Theme.mono(.caption2)).foregroundStyle(Theme.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .accessibilityElement(children: .combine)
    }
}
#endif
