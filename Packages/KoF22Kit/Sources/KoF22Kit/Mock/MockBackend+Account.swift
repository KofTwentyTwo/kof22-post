/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// The account, version, tag autocomplete and link preview endpoints.
extension MockBackend {
   /// `GET /me`: the mock author, their blogs and the authoring limits.
   func me() -> Me {
      Me(
         email: "james@kof22.com",
         name: "James Maes",
         groups: ["kof22-admins"],
         author: .init(id: 1, name: "James Maes", slug: "james-maes"),
         canPost: true,
         blogs: Self.blogs,
         defaultBlog: Self.defaultBlog,
         limits: Self.limits
      )
   }

   /// `GET /versions.json`: the one API version the mock implements.
   func versions() -> APIVersions {
      APIVersions(
         currentVersion: "v1",
         supportedVersions: ["v1"],
         versions: [
            .init(
               version: "v1", semver: "1.0.0 (mock)", status: .current,
               docsUrl: "https://api.kof22.com/v1/", openapiUrl: "https://api.kof22.com/v1/openapi.json")
         ]
      )
   }

   /// `GET /me/tags`: tags of one blog, names starting with the query first, then
   /// names containing it, each group alphabetical. A leading `#` is ignored.
   func listTags(_ query: [String: String]) throws -> Response {
      let blogSlug = query["blog"] ?? Self.defaultBlog
      let blogID = Self.blogs.first { $0.slug == blogSlug }?.id ?? Self.blogs[0].id
      let needle = (query["q"] ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
      let tags = state.tags.filter { $0.blogId == blogID }
      let prefix = tags.filter { needle.isEmpty || $0.name.lowercased().hasPrefix(needle) }.sorted { $0.name < $1.name }
      let contains = tags.filter { !needle.isEmpty && !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle) }
         .sorted { $0.name < $1.name }
      return try json(Status.okay, Components.Schemas.TagList(items: Array((prefix + contains).prefix(Self.pageSize(query["limit"])))))
   }

   /// `POST /me/link-preview`: only public http(s) URLs are previewed.
   func linkPreview(_ body: Data?) throws -> Response {
      guard let input = Self.decodeBody(Components.Schemas.LinkPreviewRequest.self, from: body) else { return try badBody() }
      var issues: [APIError.Detail] = []
      guard let preview = preview(for: input.url, field: "url", issues: &issues) else {
         return try problem(Status.unprocessable, "link_not_allowed", "Only public http(s) URLs can be previewed")
      }
      return try json(
         Status.okay,
         LinkPreview(url: preview.url, title: preview.title, description: preview.description, imageUrl: preview.imageUrl))
   }

   /// Builds the canned preview for a public http(s) URL, or records an issue on
   /// `field` for anything else (other schemes, no host, localhost).
   func preview(for raw: String, field: String, issues: inout [APIError.Detail]) -> PostLink? {
      guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
         let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
         let host = url.host(), !host.isEmpty, host != "localhost"
      else {
         issues.append(.init(field: field, issue: "must be a public http(s) URL"))
         return nil
      }
      let wwwPrefix = "www."
      let name = host.hasPrefix(wwwPrefix) ? String(host.dropFirst(wwwPrefix.count)) : host
      return PostLink(
         url: url.absoluteString, title: "\(name) (mock preview)",
         description: "Link previews are fetched server-side; this one comes from the mock API.",
         imageUrl: nil)
   }
}
