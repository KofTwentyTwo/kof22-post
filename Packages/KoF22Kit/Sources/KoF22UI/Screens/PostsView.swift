/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI

   /// The post list's data: a status filter, cursor paging and the local cache shown
   /// before the first page arrives.
   @MainActor
   @Observable
   final class PostsModel {
      /// Posts requested per page.
      private static let pageSize = 20

      /// Posts loaded so far, newest first.
      var posts: [Post] = []
      /// Cursor of the next page, or nil when there are no more.
      var nextCursor: String?
      /// Only posts with this status, or all when nil.
      var filter: PostStatus?
      /// Whether a page is being loaded.
      var isLoading = false
      /// Why the last load failed, shown above the list.
      var error: String?

      /// Loads the first page (`reset`) or the next one. An unfiltered first load shows
      /// the cached posts while the request runs, and a successful page refreshes the cache.
      func load(app: AppModel, reset: Bool = true) async {
         if reset, posts.isEmpty, filter == nil {
            posts = await cachedPosts(app: app)
         }
         guard !isLoading else { return }
         isLoading = true
         defer { isLoading = false }
         do {
            let page = try await app.service.myPosts(status: filter, cursor: reset ? nil : nextCursor, limit: Self.pageSize)
            posts = reset ? page.items : posts + page.items.filter { new in !posts.contains { $0.id == new.id } }
            nextCursor = page.nextCursor
            error = nil
            await cache(page.items, app: app)
         }
         catch {
            Log.api.warning("Posts could not be loaded: \(error.localizedDescription, privacy: .public)")
            self.error = ErrorClassifier.message(for: error)
         }
      }

      /// Posts from the local cache. The cache only fills the screen until the network
      /// answers, so a read failure is logged and treated as an empty cache.
      private func cachedPosts(app: AppModel) async -> [Post] {
         do {
            return try await app.store.cachedPosts()
         }
         catch {
            Log.storage.warning("Cached posts could not be read: \(error.localizedDescription, privacy: .public)")
            return []
         }
      }

      /// Stores a page in the local cache. The page is already on screen, so a write
      /// failure only costs the next cold start and is logged.
      private func cache(_ posts: [Post], app: AppModel) async {
         do {
            try await app.store.cache(posts)
         }
         catch {
            Log.storage.warning("Posts could not be cached: \(error.localizedDescription, privacy: .public)")
         }
      }

      /// Drops a post from the list, for example after it was deleted.
      func remove(_ id: Int64) { posts.removeAll { $0.id == id } }
   }

   /// My recent posts with status; tap for detail, edit, delete, open on the site.
   public struct PostsView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The list's data.
      @State private var model = PostsModel()

      /// Creates the Posts screen.
      public init() {}

      /// Status filter, error line, posts and a paging spinner; reloads on pull, on filter
      /// change and whenever the tab is selected.
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

   /// One post in the list: status, blog, date, title, excerpt and the first photo.
   struct PostRow: View {
      /// The app's composition root, which resolves photo URLs.
      @Environment(AppModel.self) private var app
      /// The post shown.
      let post: Post

      /// Text on the left, a square thumbnail on the right when the post has photos.
      var body: some View {
         HStack(alignment: .top, spacing: Theme.Spacing.regular) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
               HStack(spacing: Theme.Spacing.small) {
                  StatusBadge(post.status)
                  Text(post.blog).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
                  Spacer()
                  Text(displayDate, format: .dateTime.month(.abbreviated).day().hour().minute())
                     .font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
               }
               Text(post.title).font(Theme.mono(.subheadline, weight: .semibold)).foregroundStyle(Theme.heading).lineLimit(Theme.LineLimit.title)
               Text(excerpt).font(.callout).foregroundStyle(Theme.body).lineLimit(Theme.LineLimit.excerpt)
            }
            if let first = post.media.first, let url = app.photoURL(first.thumbnailUrl ?? first.url) {
               AsyncImage(url: url) {
                  $0.resizable().scaledToFill()
               } placeholder: {
                  Theme.surface
               }
               .frame(width: Theme.Size.listThumbnail, height: Theme.Size.listThumbnail)
               .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
               .accessibilityHidden(true)
            }
         }
         .padding(.vertical, Theme.Spacing.xxSmall)
         .accessibilityElement(children: .combine)
      }

      /// Published date, else scheduled date, else last update.
      var displayDate: Date { post.publishedAt ?? post.publishAt ?? post.updatedAt ?? .now }

      /// Inline markdown (bold, code, links) rendered; block syntax left as text.
      var excerpt: AttributedString {
         let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
         //////////////////////////////////////////////////////////////////////
         // Unparseable Markdown is expected in user text; plain text is the //
         // correct fallback, and logging here would repeat on every redraw. //
         //////////////////////////////////////////////////////////////////////
         return (try? AttributedString(markdown: post.body, options: options)) ?? AttributedString(post.body)
      }
   }
#endif
