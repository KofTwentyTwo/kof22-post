/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The post fields that describe a post rather than make it up: what lists, feeds and
/// search engines show.
public enum PostDetailField: String, Sendable, Hashable, CaseIterable {
   /// Headline.
   case title
   /// Display name.
   case name
   /// Short label.
   case shortName
   /// URL slug.
   case slug
   /// Summary.
   case description
   /// SEO title.
   case metaTitle
   /// SEO description.
   case metaDescription
   /// SEO keywords.
   case metaKeywords
}

/// Suggested wording for a post's details.
public struct PostDetails: Sendable, Equatable {
   /// Headline.
   public var title: String
   /// Display name (40).
   public var name: String
   /// Short label (20).
   public var shortName: String
   /// One-sentence summary.
   public var description: String
   /// SEO title.
   public var metaTitle: String
   /// SEO description.
   public var metaDescription: String
   /// Search keywords.
   public var keywords: [String]

   /// Creates suggested details.
   public init(
      title: String, name: String, shortName: String, description: String, metaTitle: String, metaDescription: String, keywords: [String]
   ) {
      self.title = title
      self.name = name
      self.shortName = shortName
      self.description = description
      self.metaTitle = metaTitle
      self.metaDescription = metaDescription
      self.keywords = keywords
   }

   /// The details cleaned up and cut to the field limits and SEO targets: no wrapping
   /// quotes or trailing period on titles and names, name and short name falling back
   /// to the title.
   public func clipped() -> Self {
      let title = PostText.clip(Self.label(title), to: PostFieldLimits.title)
      let name = Self.label(name).isEmpty ? title : Self.label(name)
      let shortName = Self.label(shortName).isEmpty ? name : Self.label(shortName)
      return Self(
         title: title,
         name: PostText.clip(name, to: PostFieldLimits.name, ellipsis: false),
         shortName: PostText.clip(shortName, to: PostFieldLimits.shortName, ellipsis: false),
         description: PostText.clip(Self.sentence(description), to: PostFieldLimits.description),
         metaTitle: PostText.clip(Self.label(metaTitle).isEmpty ? title : Self.label(metaTitle), to: PostFieldLimits.seoTitleTarget),
         metaDescription: PostText.clip(Self.sentence(metaDescription), to: PostFieldLimits.seoDescriptionTarget),
         keywords: keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
      )
   }

   /// A title-like value: one line, no surrounding quotes, no trailing period.
   static func label(_ text: String) -> String {
      var value = sentence(text)
      value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
      while value.hasSuffix(".") { value.removeLast() }
      return value.trimmingCharacters(in: .whitespaces)
   }

   /// One line of plain text.
   static func sentence(_ text: String) -> String {
      text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
   }
}

/// Writes details for a post. The app's implementation uses the on-device model and
/// falls back to `RulePostSuggester`.
public protocol PostDetailSuggesting: Sendable {
   /// Whether suggestions can be made at all.
   var isAvailable: Bool { get }
   /// Why the better (model) suggestions are not available, or nil when they are.
   var unavailableReason: String? { get }
   /// Suggests details for a post.
   func suggest(body: String, title: String, tags: [String], blog: String, location: String) async throws -> PostDetails
}

/// Details made by rules alone: the typed (or derived) title, the opening of the body
/// as the description and the tags as keywords. Always available.
public struct RulePostSuggester: PostDetailSuggesting {
   /// Creates the suggester.
   public init() {}

   /// Always available.
   public var isAvailable: Bool { true }

   /// Rules need nothing.
   public var unavailableReason: String? { nil }

   /// Details from the body, title and tags.
   public func suggest(body: String, title: String, tags: [String], blog: String, location: String) async throws -> PostDetails {
      let headline = title.nilIfBlank ?? PostText.deriveTitle(body)
      let summary = PostText.plain(body)
      return PostDetails(
         title: headline, name: headline, shortName: headline, description: summary, metaTitle: headline, metaDescription: summary,
         keywords: tags
      ).clipped()
   }
}

extension PostComposition {
   /// The composition with `details` written into the detail fields, except the ones in
   /// `keeping` (typed by the user) and blank suggestions. Values are clipped first; the
   /// slug follows the suggested title and the keywords add the post's tags.
   public func applying(_ details: PostDetails, keeping: Set<PostDetailField> = []) -> PostComposition {
      var result = self
      let clipped = details.clipped()
      func set(_ field: PostDetailField, _ keyPath: WritableKeyPath<PostComposition, String>, _ value: String) {
         guard !keeping.contains(field), !value.isEmpty else { return }
         result[keyPath: keyPath] = value
      }
      set(.title, \.title, clipped.title)
      set(.name, \.name, clipped.name)
      set(.shortName, \.shortName, clipped.shortName)
      set(.slug, \.slug, PostText.slugify(result.title.nilIfBlank ?? clipped.title))
      set(.description, \.description, clipped.description)
      set(.metaTitle, \.metaTitle, clipped.metaTitle)
      set(.metaDescription, \.metaDescription, clipped.metaDescription)
      set(.metaKeywords, \.metaKeywords, PostText.keywords(clipped.keywords + tags))
      return result
   }

   /// The composition with details from `suggester` filled into its blank detail fields.
   /// Details are a convenience: when the suggester fails the composition is returned
   /// unchanged (the rules fill blanks when it is sent) and the failure is logged.
   public func fillingBlankDetails(using suggester: any PostDetailSuggesting, blog: String) async -> PostComposition {
      let typed = Set(
         PostDetailField.allCases.filter { field in
            let value: String
            switch field {
            case .title: value = title
            case .name: value = name
            case .shortName: value = shortName
            case .slug: value = slug
            case .description: value = description
            case .metaTitle: value = metaTitle
            case .metaDescription: value = metaDescription
            case .metaKeywords: value = metaKeywords
            }
            return value.nilIfBlank != nil
         })
      do {
         let details = try await suggester.suggest(body: body, title: title, tags: tags, blog: blog, location: locationLabel)
         return applying(details, keeping: typed)
      }
      catch {
         Log.outbox.notice("Details could not be suggested, rules will fill them: \(error.localizedDescription, privacy: .public)")
         return self
      }
   }
}
