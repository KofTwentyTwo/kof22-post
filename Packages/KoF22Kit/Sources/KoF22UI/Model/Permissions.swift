/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import CoreLocation
   import MapKit
   import Observation
   import Photos
   import UIKit
   import UniformTypeIdentifiers

   /// Photo library and location access. Both are requested the first time they are
   /// needed (adding photos, "use current location") and shown in Settings.
   @MainActor
   @Observable
   public final class Permissions {
      /// The instance shared by the composer and Settings, so both see the same status.
      public static let shared = Permissions()

      /// How long to wait for a usable location fix before giving up.
      private static let locationTimeout: TimeInterval = 20
      /// Worst horizontal accuracy, in metres, accepted as "where you are".
      private static let acceptableAccuracy: CLLocationAccuracy = 200
      /// Coordinates shown when reverse geocoding finds no place name.
      private static let coordinateFormat = "%.3f, %.3f"
      /// Extension used when Photos reports no type for an original.
      private nonisolated static let fallbackExtension = "jpg"

      /// Current photo library authorization for read and write access.
      public private(set) var photos: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      /// Current location authorization.
      public private(set) var location: CLAuthorizationStatus
      /// Whether location access is precise rather than approximate.
      public private(set) var preciseLocation: Bool

      /// Reads location authorization; it never starts updates itself.
      private let manager = CLLocationManager()

      /// Creates a permissions model with the current authorization state.
      public init() {
         location = manager.authorizationStatus
         preciseLocation = manager.accuracyAuthorization == .fullAccuracy
      }

      /// Re-reads both authorizations, for example when the app returns from Settings.
      public func refresh() {
         photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
         location = manager.authorizationStatus
         preciseLocation = manager.accuracyAuthorization == .fullAccuracy
      }

      ////////////
      // Photos //
      ////////////

      /// Full library access lets the app read originals with their metadata (so
      /// "Keep photo location" has something to keep) instead of picker copies.
      public var hasFullPhotoAccess: Bool { photos == .authorized }

      /// Prompts when undecided. Returns the resulting status.
      @discardableResult
      public func requestPhotos() async -> PHAuthorizationStatus {
         if photos == .notDetermined {
            photos = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
         }
         return photos
      }

      /// Original bytes for a picked asset, including EXIF/GPS, with a file extension.
      /// Returns nil without full access or when Photos has no data, so the caller falls
      /// back to the picker's copy.
      public func originalData(assetIdentifier: String) async -> (Data, String)? {
         guard hasFullPhotoAccess,
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject
         else { return nil }
         let options = PHImageRequestOptions()
         options.isNetworkAccessAllowed = true
         options.deliveryMode = .highQualityFormat
         options.version = .current
         return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
               guard let data else {
                  Log.media.notice("Photos returned no original data; using the picker copy")
                  return continuation.resume(returning: nil)
               }
               let fileExtension = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? Self.fallbackExtension
               continuation.resume(returning: (data, fileExtension))
            }
         }
      }

      //////////////
      // Location //
      //////////////

      /// Whether the app may read the location while in use.
      public var hasLocationAccess: Bool { location == .authorizedWhenInUse || location == .authorizedAlways }

      /// Why a place label could not be produced.
      public enum LocationError: LocalizedError {
         /// The user or a device policy turned location access off.
         case denied
         /// No fix of usable accuracy arrived in time, or geocoding found nothing.
         case unavailable

         /// A sentence for the composer's alert.
         public var errorDescription: String? {
            switch self {
            case .denied: "Location access is off. Turn it on in Settings to tag posts with where you are."
            case .unavailable: "Your location could not be determined."
            }
         }
      }

      /// Asks for When In Use access with precise accuracy (the service session
      /// prompts for both), then returns a short place label such as "Chester, IL".
      public func currentPlaceLabel() async throws -> String {
         let session = CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: "PostLocation")
         defer { session.invalidate() }
         var found: CLLocation?
         let deadline = Date.now.addingTimeInterval(Self.locationTimeout)
         for try await update in CLLocationUpdate.liveUpdates() {
            refresh()
            if update.authorizationDenied || update.authorizationDeniedGlobally { throw LocationError.denied }
            if let location = update.location, location.horizontalAccuracy <= Self.acceptableAccuracy {
               found = location
               break
            }
            if Date.now > deadline { break }
         }
         refresh()
         guard let found else { throw LocationError.unavailable }
         return try await Self.label(for: found)
      }

      /// Reverse-geocodes `location` to "Place, City", "City", the place name, or the
      /// rounded coordinates, whichever is the most specific available.
      static func label(for location: CLLocation) async throws -> String {
         guard let request = MKReverseGeocodingRequest(location: location),
            let item = try await request.mapItems.first
         else { throw LocationError.unavailable }
         if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty {
            if let name = item.name, !name.isEmpty, !city.hasPrefix(name), item.pointOfInterestCategory != nil {
               return "\(name), \(city)"
            }
            return city
         }
         return item.name ?? String(format: Self.coordinateFormat, location.coordinate.latitude, location.coordinate.longitude)
      }

      /// Opens this app's page in the Settings app.
      public func openSettings() {
         guard let url = URL(string: UIApplication.openSettingsURLString) else {
            Log.ui.error("The system Settings URL is not a valid URL")
            return
         }
         UIApplication.shared.open(url)
      }
   }
#endif
