/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// Deterministic text rules for post fields: the slug, fallback title and names, the
/// excerpt and the reading time. They follow the backend's own rules
/// (`BlogAuthoringCustomizer`, the v1 `AuthoringService`) so a value made here looks
/// like one the server would have made. The on-device model only suggests wording; the
/// slug, excerpt and read time always come from here.
public enum PostText {
   /// The title the backend gives a post whose body has no usable first line.
   public static let fallbackTitle = "Field note"
   /// Slugs made from a title are cut to this many characters (the backend's rule).
   public static let slugLength = 80
   /// Longest excerpt, in characters (the backend's `EXCERPT_MAX`).
   public static let excerptLength = 280
   /// Reading speed used for `readTime` (the backend's `WORDS_PER_MIN`).
   public static let wordsPerMinute = 200
   /// A cut moves back to a space only within the last third of the room
   /// (`room * wordBreakNumerator / wordBreakDenominator` onwards).
   static let wordBreakNumerator = 2
   /// See `wordBreakNumerator`.
   static let wordBreakDenominator = 3
   /// The ellipsis appended when a value is shortened.
   static let ellipsis = "..."

   /// URL slug: ASCII-folded, lower case, every run of other characters becomes one
   /// hyphen, no hyphen at either end, at most `maxLength` characters and never ending
   /// in a hyphen after the cut.
   public static func slugify(_ text: String, maxLength: Int = slugLength) -> String {
      var folded = text
      if let latin = text.applyingTransform(.toLatin, reverse: false) { folded = latin }
      let ascii = folded.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      let slug = ascii.lowercased()
         .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
         .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
      return String(slug.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
   }

   /// The slug with `-2`, `-3`, ... appended until it is not in `taken`, still within
   /// `PostFieldLimits.slug`.
   public static func uniqueSlug(_ base: String, taken: Set<String>) -> String {
      var candidate = base
      var number = 2
      while taken.contains(candidate) {
         let suffix = "-\(number)"
         candidate = String(base.prefix(PostFieldLimits.slug - suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + suffix
         number += 1
      }
      return candidate
   }

   /// The backend's title derivation: the first non-empty line without markdown
   /// punctuation, at most the title limit long; `fallbackTitle` when nothing is left.
   public static func deriveTitle(_ body: String) -> String {
      let line =
         body.split(whereSeparator: \.isNewline)
         .map { $0.trimmingCharacters(in: .whitespaces) }
         .first { !$0.isEmpty } ?? ""
      let text = plain(line)
      if text.isEmpty { return fallbackTitle }
      return clip(text, to: PostFieldLimits.title)
   }

   /// Markdown reduced to plain text: link text kept, URLs, images, headings, list and
   /// quote markers and emphasis removed, whitespace collapsed.
   public static func plain(_ markdown: String) -> String {
      var text = markdown.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
      text = text.replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
      text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
   }

   /// `text` cut to at most `length` characters at a word boundary when one is close,
   /// with `...` when anything was removed. Text that fits is returned trimmed.
   public static func clip(_ text: String, to length: Int, ellipsis useEllipsis: Bool = true) -> String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count > length else { return trimmed }
      let room = useEllipsis ? max(length - ellipsis.count, 1) : length
      let head = String(trimmed.prefix(room))
      ////////////////////////////////////////////////////////////////
      // prefer the last space in the final third, so a word is not //
      // cut in half unless it is very long.                        //
      ////////////////////////////////////////////////////////////////
      var cut = head
      if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= room * wordBreakNumerator / wordBreakDenominator {
         cut = String(head[..<space])
      }
      cut = cut.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
      return useEllipsis ? cut + ellipsis : cut
   }

   /// The display name (40) from a title.
   public static func name(fromTitle title: String) -> String {
      clip(title, to: PostFieldLimits.name, ellipsis: false)
   }

   /// The short name (20) from a title.
   public static func shortName(fromTitle title: String) -> String {
      clip(title, to: PostFieldLimits.shortName, ellipsis: false)
   }

   /// The plain-text teaser of a body, at most `excerptLength` characters.
   public static func excerpt(_ body: String) -> String {
      clip(plain(body), to: excerptLength)
   }

   /// Whole minutes to read `body` at `wordsPerMinute`, rounded up, at least 1. Photos
   /// do not add time.
   public static func readTime(_ body: String) -> Int {
      let words = plain(body).split(whereSeparator: \.isWhitespace).count
      return max(1, (words + wordsPerMinute - 1) / wordsPerMinute)
   }

   /// Comma-separated keywords from tags (and extra terms), without duplicates, within
   /// the `metaKeywords` limit.
   public static func keywords(_ terms: [String]) -> String {
      var seen = Set<String>()
      var result: [String] = []
      for term in terms {
         let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
         guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
         let joined = (result + [clean]).joined(separator: ", ")
         if joined.count > PostFieldLimits.metaKeywords { break }
         result.append(clean)
      }
      return result.joined(separator: ", ")
   }
}
