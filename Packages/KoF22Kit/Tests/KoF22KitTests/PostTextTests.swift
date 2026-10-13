/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// The deterministic field rules: slugs, titles, clipping, excerpt, read time, keywords.
@Suite struct PostTextTests {
   @Test(arguments: [
      ("Héllo, Wörld!", "hello-world"), ("  --Already-Slugged--  ", "already-slugged"), ("Crème brûlée & café", "creme-brulee-cafe"),
      ("Привет мир", "privet-mir"), ("東京", "dong-jing"), ("!!!", ""), ("Raspberry Pi 5: first look", "raspberry-pi-5-first-look"),
   ])
   func slugsAreLowercaseASCIIWithHyphens(input: String, slug: String) {
      #expect(PostText.slugify(input) == slug)
   }

   @Test func slugsAreCutWithoutATrailingHyphen() {
      let long = String(repeating: "a", count: 79) + " b"
      #expect(PostText.slugify(long).count == PostText.slugLength - 1)
      #expect(!PostText.slugify(long).hasSuffix("-"))
      #expect(PostText.slugify("abc def", maxLength: 4) == "abc")
   }

   @Test func uniqueSlugsCountUpPastTakenOnes() {
      #expect(PostText.uniqueSlug("trip", taken: []) == "trip")
      #expect(PostText.uniqueSlug("trip", taken: ["trip"]) == "trip-2")
      #expect(PostText.uniqueSlug("trip", taken: ["trip", "trip-2", "trip-3"]) == "trip-4")
      let full = String(repeating: "x", count: PostFieldLimits.slug)
      let unique = PostText.uniqueSlug(full, taken: [full])
      #expect(unique.count == PostFieldLimits.slug)
      #expect(unique.hasSuffix("-2"))
   }

   @Test func titlesComeFromTheFirstUsefulLine() {
      #expect(PostText.deriveTitle("\n\n## Heading with [a link](https://x) and ![img](p.png)\nmore") == "Heading with a link and")
      #expect(PostText.deriveTitle("> quoted *line*") == "quoted line")
      #expect(PostText.deriveTitle("") == PostText.fallbackTitle)
      #expect(PostText.deriveTitle(String(repeating: "word ", count: 40)).count <= PostFieldLimits.title)
   }

   @Test func clippingPrefersAWordBoundary() {
      #expect(PostText.clip("  short  ", to: 10) == "short")
      #expect(PostText.clip("one two three four", to: 12) == "one two...")
      #expect(PostText.clip("one two three four", to: 12, ellipsis: false) == "one two thre")
      #expect(PostText.clip("one two three four", to: 10, ellipsis: false) == "one two")
      #expect(PostText.clip("abcdefghijklmnop", to: 8) == "abcde...")
      #expect(PostText.clip("Ends with comma, then more words", to: 20) == "Ends with comma...")
   }

   @Test func namesExcerptsAndReadTime() {
      #expect(PostText.name(fromTitle: String(repeating: "n", count: 50)).count == PostFieldLimits.name)
      #expect(PostText.shortName(fromTitle: "A short title that is long") == "A short title that")
      let body = "# Title\n\n" + String(repeating: "word ", count: 401)
      #expect(PostText.readTime(body) == 3)
      #expect(PostText.readTime("") == 1)
      #expect(PostText.excerpt(body).count <= PostText.excerptLength)
      #expect(PostText.excerpt("*Bold* and `code`") == "Bold and code")
   }

   @Test func keywordsAreDeduplicatedAndFitTheLimit() {
      #expect(PostText.keywords(["Swift", " swift ", "", "iOS"]) == "Swift, iOS")
      let many = (0..<100).map { "keyword\($0)" }
      #expect(PostText.keywords(many).count <= PostFieldLimits.metaKeywords)
   }
}

/// Suggested details: cleaning, clipping and writing them into a composition.
@Suite struct PostDetailsTests {
   /// A suggester that answers fixed details or fails.
   struct FixedSuggester: PostDetailSuggesting {
      /// What to answer, or nil to fail.
      let details: PostDetails?
      /// Always available.
      var isAvailable: Bool { true }
      /// No reason.
      var unavailableReason: String? { nil }
      /// The fixed details, or a failure.
      func suggest(body: String, title: String, tags: [String], blog: String, location: String) async throws -> PostDetails {
         guard let details else { throw RigError.deliberate }
         return details
      }
   }

   /// Details where every field is set.
   static let suggested = PostDetails(
      title: "\"Herons at dawn.\"", name: "Herons", shortName: "Herons", description: "Herons  were\nout early.",
      metaTitle: "Herons at the lake", metaDescription: "Herons at the lake at dawn.", keywords: [" Birds ", "", "Lake"])

   @Test func clippingCleansTitlesAndFallsBack() {
      let clipped = Self.suggested.clipped()
      #expect(clipped.title == "Herons at dawn")
      #expect(clipped.description == "Herons were out early.")
      #expect(clipped.keywords == ["birds", "lake"])
      let blank = PostDetails(title: "Only a title", name: " ", shortName: "", description: "", metaTitle: "", metaDescription: "", keywords: [])
         .clipped()
      #expect(blank.name == "Only a title")
      #expect(blank.shortName == "Only a title")
      #expect(blank.metaTitle == "Only a title")
   }

   @Test func rulesSuggestFromTheBodyAndTags() async throws {
      let rules = RulePostSuggester()
      #expect(rules.isAvailable)
      #expect(rules.unavailableReason == nil)
      let details = try await rules.suggest(body: "Hello there. More text.", title: "", tags: ["Tag"], blog: "b", location: "")
      #expect(details.title == "Hello there. More text")
      #expect(details.description == "Hello there. More text.")
      #expect(details.keywords == ["tag"])
      let typed = try await rules.suggest(body: "x", title: "Typed", tags: [], blog: "b", location: "")
      #expect(typed.title == "Typed")
   }

   @Test func applyingKeepsTypedFieldsAndIgnoresBlankSuggestions() {
      let composition = PostComposition(title: "Mine", body: "b", tags: ["Lake", "Sunrise"])
      let blankName = PostDetails(title: "Theirs", name: "", shortName: "", description: "", metaTitle: "", metaDescription: "", keywords: ["birds"])
      let result = composition.applying(blankName, keeping: [.title])
      #expect(result.title == "Mine")
      #expect(result.name == "Theirs")
      #expect(result.slug == "mine")
      #expect(result.description == "")
      #expect(result.metaKeywords == "birds, Lake, Sunrise")
   }

   @Test func applyingWithoutKeepsUsesTheSuggestedTitleForTheSlug() {
      let result = PostComposition(body: "b").applying(Self.suggested)
      #expect(result.title == "Herons at dawn")
      #expect(result.slug == "herons-at-dawn")
      #expect(result.metaTitle == "Herons at the lake")
      #expect(result.metaKeywords == "birds, lake")
   }

   @Test func fillingBlankDetailsKeepsEverythingTyped() async {
      let typed = PostComposition(
         title: "T", name: "N", shortName: "S", slug: "s", description: "D", metaTitle: "MT", metaDescription: "MD", metaKeywords: "k",
         body: "b")
      #expect(await typed.fillingBlankDetails(using: FixedSuggester(details: Self.suggested), blog: "Quick Bits") == typed)
      let blank = PostComposition(body: "b")
      let filled = await blank.fillingBlankDetails(using: FixedSuggester(details: Self.suggested), blog: "Quick Bits")
      #expect(filled.title == "Herons at dawn")
      #expect(filled.slug == "herons-at-dawn")
   }

   @Test func aFailingSuggesterLeavesTheCompositionAlone() async {
      let composition = PostComposition(body: "b")
      #expect(await composition.fillingBlankDetails(using: FixedSuggester(details: nil), blog: "Quick Bits") == composition)
   }
}
