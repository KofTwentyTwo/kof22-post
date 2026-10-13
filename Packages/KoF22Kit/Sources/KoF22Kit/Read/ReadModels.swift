/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// A published post (`GET /v2/blogPost/...`), with tag links and photos when read by id.
public typealias SitePost = Components.Schemas.BlogPost
/// A blog (`GET /v2/blog/...`).
public typealias SiteBlog = Components.Schemas.Blog
/// A blog tag (`GET /v2/blogTag/...`).
public typealias SiteTag = Components.Schemas.BlogTag
/// A tag applied to a post; resolve `blogTagId` with the blog's tags.
public typealias SitePostTagLink = Components.Schemas.BlogPostTagInt
/// A photo attached to a post, in display order.
public typealias SitePostMedia = Components.Schemas.BlogPostMedia

/// One page of a `/query` result: `{"records":[...],"count","pageNo","pageSize"}`.
public struct ReadPage<Record: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
   /// The records on this page.
   public var records: [Record]
   /// Total matching records, when the server included it.
   public var count: Int?
   /// The page number, starting at 1.
   public var pageNo: Int
   /// The requested page size.
   public var pageSize: Int

   /// Creates a page.
   public init(records: [Record], count: Int?, pageNo: Int, pageSize: Int) {
      self.records = records
      self.count = count
      self.pageNo = pageNo
      self.pageSize = pageSize
   }

   /// True when a later page has records: by the total count when known, otherwise when
   /// this page came back full (and not empty).
   public var hasMore: Bool {
      guard let count else { return !records.isEmpty && records.count == pageSize }
      return pageNo * pageSize < count
   }

   /// The page number to ask for next.
   public var nextPageNo: Int { pageNo + 1 }
}

/// The wire shape of a query response. The generated `*SearchResult` types lose
/// `records` (the spec puts it next to an `allOf`, which the generator ignores), so the
/// records are decoded with this envelope, item by item through the generated record
/// types. The mock backend encodes its replies with it too.
struct QueryEnvelope<Record: Codable>: Codable {
   /// The records; a missing array means an empty page.
   var records: [Record]?
   /// Total matching records.
   var count: Int?
   /// The page number the server answered.
   var pageNo: Int?
   /// The page size the server answered.
   var pageSize: Int?
}
