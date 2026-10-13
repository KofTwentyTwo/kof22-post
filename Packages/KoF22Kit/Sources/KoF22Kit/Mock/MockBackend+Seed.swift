/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The fixed site, blogs, authors and caller of the fake, and its sample posts.
extension MockBackend {
   /// One sample post in the seed data.
   struct SeedPost {
      /// The markdown body; the title is derived from it.
      let body: String
      /// Published or draft.
      let isPublished: Bool
      /// Tag names, already registered for the blog.
      let tags: [String]
      /// How long before "now" the post was written.
      let age: TimeInterval
   }

   /// Id of the default blog.
   static let quickBitsID = 1
   /// Id of the second blog.
   static let deepThoughtsID = 2
   /// Id of the signed-in author.
   static let ownerAuthorID = 1
   /// Id of a second author the owner may post as.
   static let guestAuthorID = 2

   /// The site everything belongs to.
   static let sites = [Components.Schemas.Site(description: "The public website", id: siteId, name: "KoF22", shortName: "KoF22")]

   /// The blogs.
   static let blogs = [
      Components.Schemas.Blog(
         description: "Short posts and photos", id: quickBitsID, name: "Quick Bits", shortName: "Quick Bits", siteId: siteId, slug: Post.defaultBlogSlug),
      Components.Schemas.Blog(description: "Longer essays", id: deepThoughtsID, name: "Deep Thoughts", shortName: "Deep Thoughts", siteId: siteId, slug: "deep-thoughts"),
   ]

   /// The authors.
   static let authors = [
      Components.Schemas.Author(email: "mock@kof22.invalid", id: ownerAuthorID, isActive: true, name: "Mock Author", shortName: "Mock", slug: "mock-author"),
      Components.Schemas.Author(email: "guest@kof22.invalid", id: guestAuthorID, isActive: true, name: "Guest Writer", shortName: "Guest", slug: "guest-writer"),
   ]

   /// What `GET /me` answers.
   static let demoCaller = Me(
      email: "mock@kof22.invalid", name: "Mock Author", permissions: ["blog_post.delete", "blog_post.edit", "blog_post.insert", "blog_post.read"],
      author: AuthorRef(id: Int64(ownerAuthorID), name: "Mock Author", slug: "mock-author"), canPost: true,
      blogs: blogs.compactMap { blog in
         guard let id = blog.id, let slug = blog.slug, let name = blog.name else { return nil }
         return BlogRef(id: Int64(id), slug: slug, name: name, isDefault: slug == Post.defaultBlogSlug)
      },
      defaultBlog: Post.defaultBlogSlug, limits: .fallback)

   /// What `/versions.json` answers.
   static let versions = APIVersions(semanticVersions: [APIVersions.appMajor: "2.1.0"], supportedVersions: [APIVersions.appMajor], currentVersion: APIVersions.appMajor)

   /// The demo account's blogs, shown before `/me` has loaded in demo mode.
   public static var demoBlogs: [BlogRef] { demoCaller.blogs }

   /// Tag names each blog starts with, in the order of `blogs`.
   static let seedTagNames = [["Apple", "Linux", "Programming", "Swift", "Unix"], ["Apple", "Unix"]]
   /// How long before "now" the published sample post was written (two hours).
   static let welcomePostAge: TimeInterval = 7_200
   /// How long before "now" the draft sample post was written (one hour).
   static let draftPostAge: TimeInterval = 3_600
   /// The sample posts a fresh fake shows: one published, one draft.
   static let seedPosts = [
      SeedPost(
         body: "Welcome to the **demo** of KoF22 Postr. Posts you write here stay on this device.", isPublished: true,
         tags: ["Swift"], age: welcomePostAge),
      SeedPost(body: "Draft about `launchctl` quirks I keep forgetting.", isPublished: false, tags: ["Unix"], age: draftPostAge),
   ]

   /// A fresh state with the seed tags and sample posts, dated relative to `now`.
   static func seed(now: Date) -> State {
      var state = State()
      for (blog, names) in zip(blogs, seedTagNames) {
         for name in names {
            state.tags.append(
               Components.Schemas.BlogTag(blogId: blog.id, createDate: now, id: state.takeId(), modifyDate: now, name: name, slug: PostText.slugify(name)))
         }
      }
      for sample in seedPosts {
         let date = now.addingTimeInterval(-sample.age)
         let title = PostText.deriveTitle(sample.body)
         let slug = PostText.slugify(title)
         let tagLinks = sample.tags.compactMap { name in
            state.tags.first { $0.blogId == quickBitsID && $0.name == name }.map { Components.Schemas.BlogPostTagInt(blogTagId: $0.id) }
         }
         var post = Components.Schemas.BlogPost(
            authorId: ownerAuthorID, blogId: quickBitsID, content: sample.body, createDate: date,
            description: PostText.clip(PostText.plain(sample.body), to: PostFieldLimits.description), excerpt: PostText.excerpt(sample.body),
            id: state.takeId(), isFeatured: false, isPublished: sample.isPublished,
            metaDescription: PostText.clip(PostText.plain(sample.body), to: PostFieldLimits.seoDescriptionTarget),
            metaKeywords: PostText.keywords(sample.tags), metaTitle: PostText.clip(title, to: PostFieldLimits.seoTitleTarget),
            modifyDate: date, name: PostText.name(fromTitle: title), publishDate: sample.isPublished ? date : nil,
            readTime: PostText.readTime(sample.body), shortName: PostText.shortName(fromTitle: title), slug: slug, title: title,
            viewCount: 0, tags: tagLinks, media: [])
         if sample.isPublished {
            let path = "/blogs/\(Post.defaultBlogSlug)/\(slug)"
            post.sitePath = path
            post.siteUrl = websiteBase + path
         }
         state.posts.append(post)
      }
      return state
   }
}
