/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import Foundation

   /// On-device details: name, short name, title, description and SEO fields.
   extension ComposeModel {
      /// Records that the user typed in `field`, so automatic suggestions keep it.
      public func detailEdited(_ field: PostDetailField) {
         editedDetails.insert(field)
         changed()
      }

      /// Schedules an automatic suggestion after the body settles. It fills only detail
      /// fields the user has not typed in, and only for new posts.
      public func bodyChanged() {
         changed()
         guard !isEditing, canSuggest else { return }
         suggestTask?.cancel()
         suggestTask = Task {
            guard await Self.debounce(.milliseconds(Self.suggestDebounceMilliseconds)) else { return }
            await suggest(overwrite: false)
         }
      }

      /// Asks the on-device model for details. `overwrite` (the Suggest button) replaces
      /// every field; otherwise only fields the user has not edited are filled.
      public func suggest(overwrite: Bool) async {
         let body = composition.body.trimmingCharacters(in: .whitespacesAndNewlines)
         guard body.count >= Self.minimumSuggestBodyLength || !composition.title.isEmpty else {
            if overwrite { suggestionError = "Write a little more first." }
            return
         }
         isSuggesting = true
         suggestionError = nil
         defer { isSuggesting = false }
         do {
            let details = try await suggester.suggest(
               body: composition.body, title: composition.title, tags: composition.tags, blog: blogName, location: composition.locationLabel)
            guard !Task.isCancelled else { return }
            apply(details, overwrite: overwrite)
         }
         catch {
            Log.ui.notice("Detail suggestion failed: \(error.localizedDescription, privacy: .public)")
            if overwrite { suggestionError = error.localizedDescription }
         }
      }

      /// Writes suggested details into the composition, clipped to the field limits;
      /// without `overwrite`, fields the user typed in are kept.
      func apply(_ details: PostDetails, overwrite: Bool) {
         if overwrite { editedDetails = [] }
         ////////////////////////////////////////////////////////////////
         // the title field is not switched on here: a field appearing //
         // above the editor would move the text while it is typed.    //
         ////////////////////////////////////////////////////////////////
         composition = composition.applying(details, keeping: editedDetails)
         changed()
      }

      /// The display name of the chosen blog.
      var blogName: String {
         app.blogs.first { $0.slug == composition.blog }?.name ?? composition.blog
      }
   }
#endif
