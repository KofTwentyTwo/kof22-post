/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Text rules shared with the backend (titles, slugs, ETags) and the seed data.
extension MockBackend {
   /// One sample post in the seed data.
   struct SeedPost {
      /// The markdown body; the title is derived from it.
      let body: String
      /// Draft or published.
      let status: PostStatus
      /// Tag names, already registered for the blog.
      let tags: [String]
      /// How long before "now" the post was written.
      let age: TimeInterval
   }

   /// The title the backend gives a post whose body has no usable first line.
   static let fallbackTitle = "Field note"
   /// Slugs are cut to this many characters.
   static let maxSlugLength = 80
   /// Random bytes in a post version (rendered as hex).
   static let versionByteCount = 10
   /// The `W/` prefix of a weak ETag.
   static let weakETagPrefix = "W/"

   /// Tag names each blog starts with, in the order of `blogs`.
   static let seedTagNames = [
      ["Apple", "Linux", "Programming", "Swift", "Unix"],
      ["Apple", "Unix"],
   ]

   /// How long before "now" the published sample post was written (two hours).
   static let welcomePostAge: TimeInterval = 7_200
   /// How long before "now" the draft sample post was written (one hour).
   static let draftPostAge: TimeInterval = 3_600

   /// The sample posts a fresh mock shows: one published, one draft.
   static let seedPosts = [
      SeedPost(
         body: "Welcome to the **mock** Site API. Posts you write here stay on this device.", status: .published,
         tags: ["Swift"], age: welcomePostAge),
      SeedPost(body: "Draft about `launchctl` quirks I keep forgetting.", status: .draft, tags: ["Unix"], age: draftPostAge),
   ]

   /// Whether an `If-Match` header (a list of strong or weak ETags, or `*`) matches
   /// the post's current version.
   static func matches(_ ifMatch: String, version: String) -> Bool {
      ifMatch.split(separator: ",").contains { raw in
         var tag = raw.trimmingCharacters(in: .whitespaces)
         if tag == "*" { return true }
         if tag.hasPrefix(weakETagPrefix) { tag.removeFirst(weakETagPrefix.count) }
         return tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == version
      }
   }

   /// A new random post version, as opaque as the backend's.
   static func newVersion() -> String {
      (0..<versionByteCount).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
   }

   /// Trims a string and turns an empty result into nil.
   static func blankToNil(_ value: String?) -> String? {
      guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
      return value
   }

   /// The backend's title derivation: the first non-empty line without markdown
   /// punctuation, at most the title limit long.
   public static func deriveTitle(_ body: String) -> String {
      let line =
         body.split(whereSeparator: \.isNewline)
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .first { !$0.isEmpty } ?? ""
      var text = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
      text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
      text = text.trimmingCharacters(in: .whitespaces)
      if text.isEmpty { return fallbackTitle }
      let maxLength = limits.maxTitleLength
      return text.count > maxLength ? String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces) : text
   }

   /// The backend's slug rule: ASCII-folded, lowercase, runs of anything else become
   /// one hyphen, trimmed, at most 80 characters.
   public static func slugify(_ text: String) -> String {
      let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
      let slug = folded.lowercased()
         .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
         .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
      return String(slug.prefix(maxSlugLength))
   }

   /// The slug for a post without a title: its creation time in UTC.
   static func timestampSlug(_ date: Date) -> String {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      return formatter.string(from: date)
   }

   /// A fresh state with the seed tags and sample posts, dated relative to `now`.
   static func seed(now: Date) -> State {
      var state = State()
      for (blog, names) in zip(blogs, seedTagNames) {
         for name in names {
            state.tags.append(AuthoringTag(id: state.nextTagId, name: name, slug: slugify(name), blogId: blog.id))
            state.nextTagId += 1
         }
      }
      let blog = blogs[0]
      for sample in seedPosts {
         let date = now.addingTimeInterval(-sample.age)
         var post = Post(
            id: state.nextPostId, blogId: blog.id, blog: blog.slug, status: sample.status, title: deriveTitle(sample.body),
            body: sample.body, slug: timestampSlug(date), tags: sample.tags, media: [], createdAt: date, updatedAt: date,
            version: newVersion())
         if sample.status == .published {
            post.publishedAt = date
            post.url = "\(publicBlogsURL)/\(blog.slug)/\(post.slug)"
         }
         state.posts.append(post)
         state.nextPostId += 1
      }
      return state
   }
}
