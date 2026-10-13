/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import Foundation
   import PhotosUI
   import SwiftUI

   /// Photos and location.
   extension ComposeModel {
      ////////////
      // Photos //
      ////////////

      /// Copies picked photos into the shared photos directory.
      /// With full library access the original (with its metadata) is read from Photos;
      /// otherwise the picker's copy is used.
      public func addPhotos(_ items: [PhotosPickerItem]) async {
         isLoadingPhotos = true
         defer { isLoadingPhotos = false }
         for item in items {
            do {
               if let identifier = item.itemIdentifier, let (data, fileExtension) = await Permissions.shared.originalData(assetIdentifier: identifier) {
                  composition.photos.append(ComposedPhoto(fileName: try Self.store(data, fileExtension: fileExtension)))
                  continue
               }
               guard let data = try await item.loadTransferable(type: Data.self) else {
                  Log.media.notice("A picked item had no image data and was skipped")
                  continue
               }
               let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? Self.fallbackExtension
               composition.photos.append(ComposedPhoto(fileName: try Self.store(data, fileExtension: fileExtension)))
            }
            catch {
               Log.media.warning("A picked photo could not be loaded: \(error.localizedDescription, privacy: .public)")
               message = "A photo could not be loaded: \(error.localizedDescription)"
            }
         }
         changed()
      }

      /// Adds a photo from raw bytes, such as a camera capture.
      public func addPhoto(data: Data, ext: String) {
         do {
            let name = try Self.store(data, fileExtension: ext)
            composition.photos.append(ComposedPhoto(fileName: name))
            changed()
         }
         catch {
            Log.media.warning("A captured photo could not be saved: \(error.localizedDescription, privacy: .public)")
            message = "The photo could not be saved: \(error.localizedDescription)"
         }
      }

      /// Removes `photo` from the post and deletes its local file. A removed featured
      /// photo falls back to the first one.
      public func removePhoto(_ photo: ComposedPhoto) {
         composition.photos.removeAll { $0.id == photo.id }
         if composition.featuredPhotoID == photo.id { composition.featuredPhotoID = nil }
         Self.deleteLocalFile(of: photo)
         changed()
      }

      /// Reorders photos, as the arrange sheet's drag handles do.
      public func movePhotos(from source: IndexSet, to destination: Int) {
         composition.photos.move(fromOffsets: source, toOffset: destination)
         changed()
      }

      /// Makes `photo` the post's image.
      public func feature(_ photo: ComposedPhoto) {
         composition.featuredPhotoID = photo.id
         changed()
      }

      /// Replaces the photo with the same id, for example after editing its alt text.
      public func update(_ photo: ComposedPhoto) {
         guard let index = composition.photos.firstIndex(where: { $0.id == photo.id }) else { return }
         composition.photos[index] = photo
         changed()
      }

      /// Writes photo bytes to the shared photos directory under a new unique name and
      /// returns that name.
      nonisolated static func store(_ data: Data, fileExtension: String) throws -> String {
         let name = "\(UUID().uuidString).\(fileExtension)"
         try data.write(to: SharedContainer.photosDirectory.appending(path: name), options: .completeFileProtectionUntilFirstUserAuthentication)
         return name
      }

      /// Deletes a photo's local copy. A file that cannot be removed only wastes space in
      /// the app group, so the failure is logged rather than shown.
      static func deleteLocalFile(of photo: ComposedPhoto) {
         guard let url = photo.localURL() else { return }
         do {
            try FileManager.default.removeItem(at: url)
         }
         catch {
            Log.media.notice("A local photo could not be deleted: \(error.localizedDescription, privacy: .public)")
         }
      }

      //////////////
      // Location //
      //////////////

      /// Fills the location label with the most specific place for the current
      /// position (prompts for access) and keeps the alternatives for a menu.
      public func useCurrentLocation() async {
         isLocating = true
         defer { isLocating = false }
         do {
            let options = try await Permissions.shared.currentPlaceOptions()
            locationOptions = options
            if let first = options.first { composition.locationLabel = first }
            changed()
         }
         catch {
            Log.ui.notice("Current location unavailable: \(error.localizedDescription, privacy: .public)")
            message = error.localizedDescription
         }
      }
   }
#endif
