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
    public static let shared = Permissions()

    public private(set) var photos: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    public private(set) var location: CLAuthorizationStatus
    public private(set) var preciseLocation: Bool

    private let manager = CLLocationManager()

    public init() {
        location = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
    }

    public func refresh() {
        photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        location = manager.authorizationStatus
        preciseLocation = manager.accuracyAuthorization == .fullAccuracy
    }

    // MARK: Photos

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

    /// Original bytes for a picked asset, including EXIF/GPS. Nil without full access.
    public func originalData(assetIdentifier: String) async -> (Data, String)? {
        guard hasFullPhotoAccess,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard let data else { return continuation.resume(returning: nil) }
                let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
                continuation.resume(returning: (data, ext))
            }
        }
    }

    // MARK: Location

    public var hasLocationAccess: Bool { location == .authorizedWhenInUse || location == .authorizedAlways }

    public enum LocationError: LocalizedError {
        case denied
        case unavailable

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
        let deadline = Date.now.addingTimeInterval(20)
        for try await update in CLLocationUpdate.liveUpdates() {
            refresh()
            if update.authorizationDenied || update.authorizationDeniedGlobally { throw LocationError.denied }
            if let location = update.location, location.horizontalAccuracy <= 200 {
                found = location
                break
            }
            if Date.now > deadline { break }
        }
        refresh()
        guard let found else { throw LocationError.unavailable }
        return try await Self.label(for: found)
    }

    static func label(for location: CLLocation) async throws -> String {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try await request.mapItems.first else { throw LocationError.unavailable }
        if let city = item.addressRepresentations?.cityWithContext, !city.isEmpty {
            if let name = item.name, !name.isEmpty, !city.hasPrefix(name), item.pointOfInterestCategory != nil {
                return "\(name), \(city)"
            }
            return city
        }
        return item.name ?? String(format: "%.3f, %.3f", location.coordinate.latitude, location.coordinate.longitude)
    }

    public func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
#endif
