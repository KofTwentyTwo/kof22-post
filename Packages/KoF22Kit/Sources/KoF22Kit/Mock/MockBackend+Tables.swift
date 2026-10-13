/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The query filter syntax of the v2 table operations: `field=value` (equals, ignoring
/// case like the database's collation),
/// `field=!value`, `field=LIKE pat%`, `field=IN a,b`, `field=EMPTY`, combined with AND,
/// and `orderBy=field DESC, other ASC`.
extension MockBackend {
   /// The pattern-match operator of a criterion.
   static let likeOperator = "LIKE "
   /// The list operator of a criterion.
   static let inOperator = "IN "

   /// Query parameters that are not field filters.
   static let controlParameters: Set<String> = ["pageNo", "pageSize", "includeCount", "orderBy", "booleanOperator"]

   /// The records matching every filter in `query`, in `orderBy` order.
   func filter<Record: Codable>(_ records: [Record], _ query: [String: String]) -> [Record] {
      let filters = query.filter { !Self.controlParameters.contains($0.key) }
      let rows = records.map { ($0, Self.fields(of: $0)) }
      let matching = rows.filter { _, fields in
         filters.allSatisfy { name, criterion in Self.matches(fields[name], criterion) }
      }
      let order = Self.ordering(query["orderBy"])
      return matching.sorted { lhs, rhs in
         for (field, descending) in order {
            let left = lhs.1[field] ?? ""
            let right = rhs.1[field] ?? ""
            if left == right { continue }
            let ascending = Self.lessThan(left, right)
            return descending ? !ascending : ascending
         }
         return false
      }.map(\.0)
   }

   /// A record's top-level fields as strings (booleans `true`/`false`, dates as encoded).
   static func fields(of record: some Encodable) -> [String: String] {
      ///////////////////////////////////////////////////////////////
      // the generated records always encode to a JSON object; a   //
      // record that did not would match no filter.                //
      ///////////////////////////////////////////////////////////////
      guard let data = try? encoder.encode(record), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
         return [:]
      }
      var fields: [String: String] = [:]
      for (key, value) in object {
         switch value {
         case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): fields[key] = number.boolValue ? "true" : "false"
         case let number as NSNumber: fields[key] = number.stringValue
         case let string as String: fields[key] = string
         default: continue
         }
      }
      return fields
   }

   /// Whether a field value satisfies one criterion.
   static func matches(_ value: String?, _ criterion: String) -> Bool {
      if criterion == "EMPTY" { return value?.isEmpty ?? true }
      if criterion.hasPrefix(likeOperator) {
         guard let value else { return false }
         let like = String(criterion.dropFirst(likeOperator.count))
         let pattern = "^" + NSRegularExpression.escapedPattern(for: like).replacingOccurrences(of: "%", with: ".*") + "$"
         return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
      }
      if criterion.hasPrefix(inOperator) {
         return criterion.dropFirst(inOperator.count).split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == value }
      }
      if criterion.hasPrefix("!") { return !equal(value, String(criterion.dropFirst())) }
      return equal(value, criterion)
   }

   /// Equality as the database compares text: ignoring case.
   static func equal(_ value: String?, _ other: String) -> Bool {
      value?.caseInsensitiveCompare(other) == .orderedSame
   }

   /// `orderBy` as (field, descending) pairs; by id when absent.
   static func ordering(_ orderBy: String?) -> [(String, Bool)] {
      let terms = (orderBy ?? "id").split(separator: ",").map { $0.split(separator: " ").map(String.init) }
      return terms.compactMap { parts in
         guard let field = parts.first else { return nil }
         return (field, parts.dropFirst().first?.uppercased() == "DESC")
      }
   }

   /// Numbers compare numerically, everything else as text.
   static func lessThan(_ left: String, _ right: String) -> Bool {
      if let lhs = Double(left), let rhs = Double(right) { return lhs < rhs }
      return left.localizedStandardCompare(right) == .orderedAscending
   }
}
