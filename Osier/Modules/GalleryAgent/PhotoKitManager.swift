//
//  PhotoKitManager.swift
//  Osier — Module C: GalleryAgent
//
//  Full PhotoKit service wrapper.
//  Handles .readWrite authorization, asset fetching across
//  smart and user-created albums, and safety-gated trash execution.
//
//  All delete operations use PHAssetChangeRequest.deleteAssets which
//  routes assets to iOS "Recently Deleted" — 30-day recovery guaranteed.
//  Hard deletion is never performed.
//
//  Requires Info.plist:
//    NSPhotoLibraryUsageDescription
//    NSPhotoLibraryAddUsageDescription
//

import Photos
import Foundation

// MARK: - Authorization State

enum PhotoAuthState {
    case notDetermined
    case authorized        // Full .readWrite access
    case limited           // Limited library access (iOS 14+)
    case denied
    case restricted
}

// MARK: - Smart Album Descriptor

struct SmartAlbumDescriptor: Identifiable {
    let id: UUID = UUID()
    let title: String
    let subtype: PHAssetCollectionSubtype
    var assetCount: Int
}

// MARK: - User Album Descriptor

struct UserAlbumDescriptor: Identifiable {
    let id: UUID = UUID()
    let title: String
    let collection: PHAssetCollection
    var assetCount: Int
}

// MARK: - PhotoKitManager

@MainActor
final class PhotoKitManager: ObservableObject {

    // MARK: - Singleton

    static let shared = PhotoKitManager()
    private init() {}

    // MARK: - Published State

    @Published var authState: PhotoAuthState = .notDetermined
    @Published var totalAssetCount: Int = 0

    // MARK: - Authorization

    /// Requests full read/write access to the photo library (iOS 14+).
    func requestAuthorization() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authState  = mapAuthStatus(status)

        if authState == .authorized || authState == .limited {
            totalAssetCount = fetchAllAssets().count
            print("[PhotoKitManager] ✅ Auth granted — \(totalAssetCount) assets in library.")
        } else {
            print("[PhotoKitManager] ❌ Auth denied: \(authState)")
        }
    }

    private func mapAuthStatus(_ status: PHAuthorizationStatus) -> PhotoAuthState {
        switch status {
        case .authorized:      return .authorized
        case .limited:         return .limited
        case .denied:          return .denied
        case .restricted:      return .restricted
        case .notDetermined:   return .notDetermined
        @unknown default:      return .notDetermined
        }
    }

    // MARK: - Asset Fetching

    /// Returns all photo assets in the library, sorted newest first.
    func fetchAllAssets(mediaType: PHAssetMediaType = .unknown) -> [PHAsset] {
        let options             = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false

        if mediaType != .unknown {
            options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        }

        return fetchResult(PHAsset.fetchAssets(with: options))
    }

    /// Returns assets within a date range, sorted newest first.
    func fetchAssets(from startDate: Date, to endDate: Date,
                     mediaType: PHAssetMediaType = .unknown) -> [PHAsset] {
        let options             = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var predicates: [NSPredicate] = [
            NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                        startDate as NSDate, endDate as NSDate)
        ]
        if mediaType != .unknown {
            predicates.append(NSPredicate(format: "mediaType == %d", mediaType.rawValue))
        }
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        return fetchResult(PHAsset.fetchAssets(with: options))
    }

    /// Returns assets within a specific `PHAssetCollection`.
    func fetchAssets(in collection: PHAssetCollection,
                     mediaType: PHAssetMediaType = .unknown) -> [PHAsset] {
        let options             = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if mediaType != .unknown {
            options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        }
        return fetchResult(PHAsset.fetchAssets(in: collection, options: options))
    }

    /// Fetches assets by a list of local identifiers.
    func fetchAssets(withIdentifiers ids: [String]) -> [PHAsset] {
        fetchResult(PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil))
    }

    /// Fetches the single asset with the specified local identifier.
    func fetchAsset(withIdentifier id: String) -> PHAsset? {
        fetchAssets(withIdentifiers: [id]).first
    }

    // MARK: - Smart Albums

    /// All recognized smart album subtypes mapped to user-friendly names.
    static let smartAlbumMap: [(subtype: PHAssetCollectionSubtype, title: String)] = [
        (.smartAlbumFavorites,       "Favorites"),
        (.smartAlbumPanoramas,       "Panoramas"),
        (.smartAlbumVideos,          "Videos"),
        (.smartAlbumSlomoVideos,     "Slo-mo"),
        (.smartAlbumTimelapses,      "Time-lapses"),
        (.smartAlbumBursts,          "Bursts"),
        (.smartAlbumScreenshots,     "Screenshots"),
        (.smartAlbumSelfPortraits,   "Selfies"),
        (.smartAlbumLivePhotos,      "Live Photos"),
        (.smartAlbumDepthEffect,     "Portrait"),
        (.smartAlbumAllHidden,       "Hidden"),
        (.smartAlbumLongExposures,   "Long Exposure"),
        (.smartAlbumAnimated,        "Animated"),
        (.smartAlbumRAW,             "RAW"),
    ]

    /// Returns all available smart albums with their asset counts.
    func fetchSmartAlbums() -> [SmartAlbumDescriptor] {
        PhotoKitManager.smartAlbumMap.compactMap { entry in
            let result = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: entry.subtype,
                options: nil
            )
            guard let collection = result.firstObject else { return nil }
            let countOptions        = PHFetchOptions()
            countOptions.predicate  = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                                  PHAssetMediaType.image.rawValue,
                                                  PHAssetMediaType.video.rawValue)
            let count = PHAsset.fetchAssets(in: collection, options: countOptions).count
            return SmartAlbumDescriptor(title: entry.title, subtype: entry.subtype, assetCount: count)
        }
    }

    /// Returns a specific smart album collection by subtype, or nil if empty.
    func fetchSmartAlbumCollection(subtype: PHAssetCollectionSubtype) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: subtype, options: nil
        ).firstObject
    }

    // MARK: - User Albums

    /// Returns all user-created albums with their asset counts.
    func fetchUserAlbums() -> [UserAlbumDescriptor] {
        let results = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        return fetchResult(results).map { collection in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            return UserAlbumDescriptor(
                title: collection.localizedTitle ?? "Untitled",
                collection: collection,
                assetCount: count
            )
        }
    }

    /// Finds a user album by exact title (case-insensitive). Returns nil if not found.
    func findUserAlbum(named name: String) -> PHAssetCollection? {
        let results = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        for i in 0..<results.count {
            let col = results[i]
            if col.localizedTitle?.lowercased() == name.lowercased() { return col }
        }
        return nil
    }

    // MARK: - Safety-Gated Trash Execution

    /// Routes a list of PHAssets to iOS "Recently Deleted."
    /// NEVER hard-deletes. System preserves a 30-day recovery window.
    /// This is called ONLY after SafetyProtocolEngine has received user confirmation.
    func trashAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        guard authState == .authorized || authState == .limited else {
            throw PhotoKitError.notAuthorized
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }

        print("[PhotoKitManager] 🗑 Routed \(assets.count) asset(s) to Recently Deleted.")
    }

    /// Trashes assets identified by local identifier strings.
    func trashAssets(withIdentifiers ids: [String]) async throws {
        let assets = fetchAssets(withIdentifiers: ids)
        guard !assets.isEmpty else { throw PhotoKitError.assetsNotFound(ids) }
        try await trashAssets(assets)
    }

    // MARK: - Utility

    /// Converts a PHFetchResult<T> to a Swift array.
    func fetchResult<T: AnyObject>(_ result: PHFetchResult<T>) -> [T] {
        var items: [T] = []
        result.enumerateObjects { obj, _, _ in items.append(obj) }
        return items
    }
}

// MARK: - PhotoKit Errors

enum PhotoKitError: LocalizedError {
    case notAuthorized
    case assetsNotFound([String])
    case albumCreationFailed(String)
    case performChangesFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Photo library access not authorized."
        case .assetsNotFound(let ids):
            return "Could not locate \(ids.count) asset(s) in the photo library."
        case .albumCreationFailed(let name):
            return "Failed to create album: \"\(name)\"."
        case .performChangesFailed(let err):
            return "Photo library change failed: \(err.localizedDescription)"
        }
    }
}
