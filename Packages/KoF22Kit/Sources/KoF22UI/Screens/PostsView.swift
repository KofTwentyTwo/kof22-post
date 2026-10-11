#if os(iOS)
   import SwiftUI
   import Textual

   @MainActor
   @Observable
   final class PostsModel {
      var posts: [Post] = []
      var nextCursor: String?
      var filter: PostStatus?
      var isLoading = false
      var error: String?

      func load(app: AppModel, reset: Bool = true) async {
         if reset, posts.isEmpty, filter == nil {
            posts = (try? await app.store.cachedPosts()) ?? []
         }
         guard !isLoading else { return }
         isLoading = true
         defer { isLoading = false }
         do {
            let page = try await app.service.myPosts(status: filter, cursor: reset ? nil : nextCursor, limit: 20)
            posts = reset ? page.items : posts + page.items.filter { new in !posts.contains { $0.id == new.id } }
            nextCursor = page.nextCursor
            error = nil
            try? await app.store.cache(page.items)
         }
         catch {
            self.error = ErrorClassifier.message(for: error)
         }
      }

      func remove(_ id: Int64) { posts.removeAll { $0.id == id } }
   }

   /// My recent posts with status; tap for detail, edit, delete, open on the site.
   public struct PostsView: View {
      @Environment(AppModel.self) private var app
      @State private var model = PostsModel()

      public init() {}

      public var body: some View {
         NavigationStack {
            List {
               Picker("Status", selection: $model.filter) {
                  Text("All").tag(PostStatus?.none)
                  ForEach(PostStatus.allCases, id: \.self) { Text($0.label).tag(PostStatus?.some($0)) }
               }
               .pickerStyle(.segmented)
               .listRowSeparator(.hidden)

               if let error = model.error {
                  Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(Theme.muted)
               }
               ForEach(model.posts) { post in
                  NavigationLink(value: post) { PostRow(post: post) }
               }
               if model.nextCursor != nil {
                  ProgressView().frame(maxWidth: .infinity).task { await model.load(app: app, reset: false) }
               }
            }
            .listStyle(.plain)
            .overlay {
               if model.posts.isEmpty && !model.isLoading && model.error == nil {
                  ContentUnavailableView("No posts yet", systemImage: "text.bubble")
               }
            }
            .navigationTitle("Posts")
            .navigationDestination(for: Post.self) { post in
               PostDetailView(post: post) { model.remove($0) }
            }
            .refreshable { await model.load(app: app) }
            .task(id: model.filter) { await model.load(app: app) }
            .onChange(of: app.selectedTab) { _, tab in if tab == .posts { Task { await model.load(app: app) } } }
         }
      }
   }

   struct PostRow: View {
      @Environment(AppModel.self) private var app
      let post: Post

      var body: some View {
         HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
               HStack(spacing: 6) {
                  StatusBadge(post.status)
                  Text(post.blog).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
                  Spacer()
                  Text(displayDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                     .font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
               }
               Text(post.title).font(Theme.mono(.subheadline, weight: .semibold)).foregroundStyle(Theme.heading).lineLimit(2)
               Text(excerpt).font(.callout).foregroundStyle(Theme.body).lineLimit(2)
            }
            if let first = post.media.first, let url = app.photoURL(first.thumbnailUrl ?? first.url) {
               AsyncImage(url: url) {
                  $0.resizable().scaledToFill()
               } placeholder: {
                  Theme.surface
               }
               .frame(width: 56, height: 56)
               .clipShape(RoundedRectangle(cornerRadius: 6))
               .accessibilityHidden(true)
            }
         }
         .padding(.vertical, 2)
         .accessibilityElement(children: .combine)
      }

      var displayDate: Date { post.publishedAt ?? post.publishAt ?? post.updatedAt ?? .now }

      /// Inline markdown (bold, code, links) rendered; block syntax left as text.
      var excerpt: AttributedString {
         let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
         return (try? AttributedString(markdown: post.body, options: options)) ?? AttributedString(post.body)
      }
   }

   struct PostDetailView: View {
      @Environment(AppModel.self) private var app
      @Environment(\.dismiss) private var dismiss
      @State var post: Post
      let onDelete: (Int64) -> Void
      @State private var editor: ComposeModel?
      @State private var confirmDelete = false
      @State private var error: String?

      var body: some View {
         ScrollView {
            VStack(alignment: .leading, spacing: 14) {
               HStack {
                  StatusBadge(post.status)
                  if post.status == .scheduled, let at = post.publishAt {
                     Text("for \(at, format: .dateTime.month().day().hour().minute())").font(.caption).foregroundStyle(Theme.muted)
                  }
                  Spacer()
                  Text(post.blog).font(Theme.mono(.caption)).foregroundStyle(Theme.muted)
               }
               Text(post.title).font(Theme.mono(.title3, weight: .bold)).foregroundStyle(Theme.heading)
               StructuredText(markdown: post.body)
               ForEach(post.media, id: \.mediaId) { photo in
                  VStack(alignment: .leading, spacing: 4) {
                     AsyncImage(url: app.photoURL(photo.url)) {
                        $0.resizable().scaledToFit()
                     } placeholder: {
                        Theme.surface.frame(height: 200)
                     }
                     .clipShape(RoundedRectangle(cornerRadius: 8))
                     .accessibilityLabel(photo.altText ?? "Photo")
                     if let caption = photo.caption { Text(caption).font(.caption).foregroundStyle(Theme.muted) }
                  }
               }
               if let link = post.link {
                  LinkPreviewCard(preview: LinkPreview(url: link.url, title: link.title, description: link.description, imageUrl: link.imageUrl))
               }
               if let location = post.locationLabel {
                  Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(Theme.muted)
               }
               if !post.tags.isEmpty {
                  FlowLayout(spacing: 6) { ForEach(post.tags, id: \.self) { TagChip($0) } }
               }
               if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            }
            .padding()
         }
         .background(Theme.background)
         .navigationBarTitleDisplayMode(.inline)
         .toolbar {
            if let url = post.url.flatMap(URL.init(string:)) {
               ToolbarItem { Link(destination: url) { Image(systemName: "safari") }.accessibilityLabel("Open on kof22.com") }
               ToolbarItem { ShareLink(item: url) }
            }
            ToolbarItem {
               Button("Edit") {
                  editor = ComposeModel(
                     app: app, composition: PostComposition(post: post),
                     mode: .edit(postID: post.id, version: post.version))
               }
               .accessibilityIdentifier("post.edit")
            }
            ToolbarItem {
               Button(role: .destructive) {
                  confirmDelete = true
               } label: {
                  Image(systemName: "trash")
               }
               .accessibilityLabel("Delete post")
            }
         }
         .confirmationDialog("Delete this post from kof22.com?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
         }
         .sheet(item: $editor) { composer in
            NavigationStack {
               ComposeView(model: composer) {
                  editor = nil
                  Task { await reload() }
               }
               .navigationTitle("Edit post")
               .navigationBarTitleDisplayMode(.inline)
               .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editor = nil } } }
            }
         }
         .task { await reload() }
      }

      private func reload() async {
         // Give the outbox a moment to send an edit before re-reading.
         try? await Task.sleep(for: .milliseconds(500))
         if let fresh = try? await app.service.post(id: post.id) { post = fresh }
      }

      private func delete() {
         let id = post.id
         let version = post.version
         Task {
            do {
               try await app.submit(PostComposition(post: post), operation: .delete, serverPostID: id, ifMatch: version)
               try? await app.store.removeCached(id)
               onDelete(id)
               dismiss()
            }
            catch {
               self.error = error.localizedDescription
            }
         }
      }
   }
#endif
