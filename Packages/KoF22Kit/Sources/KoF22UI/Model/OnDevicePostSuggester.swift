/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import Foundation
   import FoundationModels

   /// How many keywords the model writes.
   let generatedKeywordCount = 3...8

   /// What the on-device model fills in for a post.
   @Generable
   struct GeneratedPostDetails {
      /// Headline.
      @Guide(description: "A clear, specific headline for the post in the author's voice, 3 to 10 words, at most 70 characters, no quotes")
      var title: String
      /// Display name.
      @Guide(description: "This post's name in lists: a shorter form of the title, 2 to 5 words, at most 40 characters, not a category")
      var name: String
      /// Short label.
      @Guide(description: "The post's shortest label: the key words of the title, 1 to 3 words, at most 20 characters, not a category")
      var shortName: String
      /// Summary.
      @Guide(description: "One plain sentence telling a reader what the post is about, at most 200 characters")
      var summary: String
      /// SEO title.
      @Guide(description: "A search result title that states the topic, at most 60 characters")
      var seoTitle: String
      /// SEO description.
      @Guide(description: "A search result description, one or two plain sentences, 110 to 155 characters")
      var seoDescription: String
      /// Keywords.
      @Guide(description: "Lowercase search keywords or short phrases taken from the post's topic", .count(generatedKeywordCount))
      var keywords: [String]
   }

   /// Suggests post details with Apple's on-device language model (Foundation Models).
   /// Only the on-device `SystemLanguageModel` is used, never Private Cloud Compute, so
   /// post text does not leave the iPhone. Without Apple Intelligence (an older iPhone,
   /// the feature turned off, the model still downloading) it uses `RulePostSuggester`.
   public struct OnDevicePostSuggester: PostDetailSuggesting {
      /// Longest body passed to the model, in characters; the model's context is small
      /// and the opening of a post says what it is about.
      static let maximumPromptBody = 6_000

      /// What the model is told about the task and the voice.
      static let instructions = """
         You write the metadata for one post on kof22.com, a personal website. \
         Every field must describe what this post's text is about. \
         Base everything only on the post text you are given; do not invent facts, names or places. \
         Never use the website's or a blog's name as a title or name. \
         Keep the author's tone. Use plain words, no emoji, no hashtags, no clickbait. \
         Titles use sentence case.
         """

      /// The rules used when the model cannot run.
      let fallback = RulePostSuggester()

      /// Creates the suggester.
      public init() {}

      /// Always available: the rules work everywhere.
      public var isAvailable: Bool { true }

      /// Why the model cannot run, worded for the details section, or nil when it can.
      public var unavailableReason: String? {
         switch SystemLanguageModel.default.availability {
         case .available: nil
         case .unavailable(.deviceNotEligible): "This iPhone doesn't support Apple Intelligence, so details come from simple rules."
         case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings for better suggestions. Simple rules are used for now."
         case .unavailable(.modelNotReady): "Apple Intelligence is still getting ready. Simple rules are used for now."
         case .unavailable: "Apple Intelligence isn't available, so details come from simple rules."
         }
      }

      /// Suggests details with the model, or with the rules when it is unavailable.
      public func suggest(body: String, title: String, tags: [String], blog: String, location: String) async throws -> PostDetails {
         guard case .available = SystemLanguageModel.default.availability else {
            return try await fallback.suggest(body: body, title: title, tags: tags, blog: blog, location: location)
         }
         let session = LanguageModelSession(model: .default, instructions: Self.instructions)
         let response = try await session.respond(to: Self.prompt(body: body, title: title, tags: tags, blog: blog, location: location), generating: GeneratedPostDetails.self)
         let generated = response.content
         let rules = try await fallback.suggest(body: body, title: title, tags: tags, blog: blog, location: location)
         let headline = title.isEmpty ? Self.usable(generated.title, blog: blog) ?? rules.title : title
         return PostDetails(
            title: headline, name: Self.usable(generated.name, blog: blog) ?? rules.name,
            shortName: Self.usable(generated.shortName, blog: blog) ?? rules.shortName,
            description: generated.summary, metaTitle: generated.seoTitle, metaDescription: generated.seoDescription,
            keywords: generated.keywords
         ).clipped()
      }

      /// `value`, or nil when it is blank or just names the blog or the site (a mistake
      /// the model makes when the blog name is in view), so the rules are used instead.
      static func usable(_ value: String, blog: String) -> String? {
         let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
         let names = [blog, "kof22", "kof22.com", "field notes", "quick bits"].map { $0.lowercased() }
         return clean.isEmpty || names.contains(clean.lowercased()) ? nil : clean
      }

      /// The prompt: the post and what is already known about it. The blog name is left
      /// out on purpose: the model took it for the post's title.
      static func prompt(body: String, title: String, tags: [String], blog: String, location: String) -> String {
         var lines: [String] = []
         if !title.isEmpty { lines.append("The author's title: \(title)") }
         if !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", "))") }
         if !location.isEmpty { lines.append("Written at: \(location)") }
         lines.append("Post (Markdown):")
         lines.append(String(body.prefix(maximumPromptBody)))
         return lines.joined(separator: "\n")
      }
   }
#endif
