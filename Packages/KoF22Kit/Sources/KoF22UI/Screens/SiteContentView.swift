/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI
   import Textual

   /// Published content on kof22.com, read anonymously (ADR-0008): the blogs, then the
   /// newest posts of one blog with their tags. Reads are cached briefly and refreshed
   /// only on pull, never polled.
   struct SiteBlogsView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The blogs from `/v1/blog/query`.
      @State private var blogs: [SiteBlog] = []
      /// A user-facing message when the blogs could not be read.
      @State private var errorMessage: String?

      /// The blog list, with pull to refresh.
      var body: some View {
         List {
            if let errorMessage {
               Label(errorMessage, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(blogs, id: \.id) { blog in
               NavigationLink {
                  SiteBlogPostsView(blog: blog)
               } label: {
                  VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                     Text(blog.name ?? blog.slug ?? "Blog").font(Theme.mono(.body, weight: .semibold)).foregroundStyle(Theme.heading)
                     if let description = blog.description {
                        Text(description).font(.callout).foregroundStyle(Theme.body).lineLimit(Theme.LineLimit.excerpt)
                     }
                  }
               }
            }
         }
         .navigationTitle("On kof22.com")
         .refreshable { await load(forceRefresh: true) }
         .task { await load(forceRefresh: false) }
      }

      /// Reads the blogs, keeping the last list and showing a message on failure.
      private func load(forceRefresh: Bool) async {
         do {
            blogs = try await app.reads.blogs(forceRefresh: forceRefresh)
            errorMessage = nil
         }
         catch {
            Log.ui.warning("Blogs could not be read: \(error.localizedDescription, privacy: .public)")
            errorMessage = ErrorClassifier.message(for: error)
         }
      }
   }

   /// The newest published posts of one blog, page by page, with tag names resolved
   /// from the blog's tags.
   struct SiteBlogPostsView: View {
      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// The blog whose posts are listed.
      let blog: SiteBlog
      /// Posts loaded so far, newest first.
      @State private var posts: [SitePost] = []
      /// Tag names by tag id, for the chips under each post.
      @State private var tagNames: [Int: String] = [:]
      /// The last page read, for paging.
      @State private var lastPage: ReadPage<SitePost>?
      /// A user-facing message when posts could not be read.
      @State private var errorMessage: String?

      /// The post list with a loader row while more pages exist.
      var body: some View {
         List {
            if let errorMessage {
               Label(errorMessage, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(posts, id: \.id) { post in
               NavigationLink {
                  SitePostView(post: post, blogSlug: blog.slug, tagNames: tagNames)
               } label: {
                  SitePostRow(post: post, tagNames: tagNames)
               }
            }
            if lastPage?.hasMore == true {
               ProgressView().frame(maxWidth: .infinity).task { await loadNextPage() }
            }
         }
         .listStyle(.plain)
         .navigationTitle(blog.name ?? "Posts")
         .refreshable { await reload(forceRefresh: true) }
         .task { await reload(forceRefresh: false) }
      }

      /// Loads the first page and the blog's tags.
      private func reload(forceRefresh: Bool) async {
         guard let blogId = blog.id else { return }
         do {
            let page = try await app.reads.posts(blogId: blogId, forceRefresh: forceRefresh)
            posts = page.records
            lastPage = page
            let tags = try await app.reads.tags(blogId: blogId, forceRefresh: forceRefresh)
            tagNames = Dictionary(tags.compactMap { tag in tag.id.map { ($0, tag.name ?? "") } }, uniquingKeysWith: { first, _ in first })
            errorMessage = nil
         }
         catch {
            Log.ui.warning("Posts could not be read: \(error.localizedDescription, privacy: .public)")
            errorMessage = ErrorClassifier.message(for: error)
         }
      }

      /// Appends the next page when the loader row appears.
      private func loadNextPage() async {
         guard let blogId = blog.id, let lastPage else { return }
         do {
            let page = try await app.reads.posts(blogId: blogId, pageNo: lastPage.nextPageNo)
            posts += page.records.filter { new in !posts.contains { $0.id == new.id } }
            self.lastPage = page
         }
         catch {
            Log.ui.warning("More posts could not be read: \(error.localizedDescription, privacy: .public)")
            errorMessage = ErrorClassifier.message(for: error)
         }
      }
   }

   /// One published post in a list: date, title, excerpt and tags.
   struct SitePostRow: View {
      /// The post to show.
      let post: SitePost
      /// Tag names by tag id.
      let tagNames: [Int: String]

      /// The row layout.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            if let date = post.publishDate {
               Text(date, format: .dateTime.month(.abbreviated).day().year()).font(Theme.mono(.caption2)).foregroundStyle(Theme.muted)
            }
            Text(post.title ?? post.name ?? "Untitled").font(Theme.mono(.subheadline, weight: .semibold)).foregroundStyle(Theme.heading)
            if let excerpt = post.excerpt ?? post.description, !excerpt.isEmpty {
               Text(excerpt).font(.callout).foregroundStyle(Theme.body).lineLimit(Theme.LineLimit.excerpt)
            }
            let names = (post.tags ?? []).compactMap { $0.tagId.flatMap { tagNames[$0] } }
            if !names.isEmpty {
               FlowLayout(spacing: Theme.Spacing.small) { ForEach(names, id: \.self) { TagChip($0) } }
            }
         }
         .padding(.vertical, Theme.Spacing.xxSmall)
         .accessibilityElement(children: .combine)
      }
   }

   /// A published post rendered from its Markdown, with a link to the website.
   struct SitePostView: View {
      /// The post to show.
      let post: SitePost
      /// The blog's slug, for the website URL.
      let blogSlug: String?
      /// Tag names by tag id.
      let tagNames: [Int: String]

      /// The website address `https://www.kof22.com/blogs/<blog>/<post>`, when both slugs are known.
      private var websiteURL: URL? {
         guard let blogSlug, let slug = post.slug else { return nil }
         return URL(literal: "https://www.kof22.com/blogs").appending(path: blogSlug).appending(path: slug)
      }

      /// Title, body, photos and tags.
      var body: some View {
         ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
               Text(post.title ?? "Untitled").font(Theme.mono(.title3, weight: .bold)).foregroundStyle(Theme.heading)
               StructuredText(markdown: post.content ?? "")
               ForEach(post.media ?? [], id: \.mediaId) { photo in
                  AsyncImage(url: (photo.url).flatMap(URL.init(string:))) {
                     $0.resizable().scaledToFit()
                  } placeholder: {
                     Theme.surface.frame(height: Theme.Size.detailImagePlaceholder)
                  }
                  .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                  .accessibilityLabel(photo.altText ?? "Photo")
               }
               let names = (post.tags ?? []).compactMap { $0.tagId.flatMap { tagNames[$0] } }
               if !names.isEmpty {
                  FlowLayout(spacing: Theme.Spacing.small) { ForEach(names, id: \.self) { TagChip($0) } }
               }
            }
            .padding()
         }
         .background(Theme.background)
         .navigationBarTitleDisplayMode(.inline)
         .toolbar {
            if let websiteURL {
               ToolbarItem { Link(destination: websiteURL) { Image(systemName: "safari") }.accessibilityLabel("Open on kof22.com") }
            }
         }
      }
   }
#endif
