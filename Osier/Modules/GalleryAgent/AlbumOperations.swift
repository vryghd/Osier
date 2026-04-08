//
//  AlbumOperations.swift
//  Osier — Module C: GalleryAgent
//
//  Album management service: find-or-create by name, batch add, batch remove.
//  All write operations use PHPhotoLibrary.performChanges — the only
//  public API for mutating the photo library.
//

import Photos
import Foundation

// MARK: - AlbumOperations

final class AlbumOperations {

    // MARK: - Singleton

    static let shared = AlbumOperations()
    private init() {}

    private let photoKit = PhotoKitManager.shared

    // MARK: - Find

    /// Returns an existing user album matching the given name (case-insensitive).
    /// Returns nil if no match is found.
    func findAlbum(named name: String) -> PHAssetCollection? {
        photoKit.findUserAlbum(named: name)
    }

    /// Returns true if a user album with the given name already exists.
    func albumExists(named name: String) -> Bool {
        findAlbum(named: name) != nil
    }

    // MARK: - Create

    /// Creates a new user album with the given name.
    /// Throws if creation fails.
    /// Returns the newly created PHAssetCollection.
    @discardableResult
    func createAlbum(named name: String) async throws -> PHAssetCollection {
        var placeholderID: String?

        try await PHPhotoLibrary.shared().performChanges {
            let request     = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            placeholderID   = request.placeholderForCreatedAssetCollection.localIdentifier
        }

        guard let id = placeholderID,
              let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id], options: nil
              ).firstObject else {
            throw PhotoKitError.albumCreationFailed(name)
        }

        print("[AlbumOperations] ✅ Album created: \"\(name)\"")
        return collection
    }

    // MARK: - Find or Create

    /// Returns an existing album matching the name, or creates one if absent.
    @discardableResult
    func findOrCreateAlbum(named name: String) async throws -> PHAssetCollection {
        if let existing = findAlbum(named: name) {
            print("[AlbumOperations] 🔍 Found existing album: \"\(name)\"")
            return existing
        }
        return try await createAlbum(named: name)
    }

    // MARK: - Batch Add

    /// Adds an array of PHAssets to the specified album.
    /// Skips assets already in the album (no-op for duplicates).
    func batchAddAssets(_ assets: [PHAsset], to album: PHAssetCollection) async throws {
        guard !assets.isEmpty else { return }

        // Determine which assets are not already in the album
        let existing       = PHAsset.fetchAssets(in: album, options: nil)
        var existingIDs    = Set<String>()
        existing.enumerateObjects { asset, _, _ in
            existingIDs.insert(asset.localIdentifier)
        }

        let toAdd = assets.filter { !existingIDs.contains($0.localIdentifier) }
        guard !toAdd.isEmpty else {
            print("[AlbumOperations] ℹ️ All \(assets.count) asset(s) already in \"\(album.localizedTitle ?? "album")\".")
            return
        }

        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.addAssets(toAdd as NSArray)
        }

        print("[AlbumOperations] ✅ Added \(toAdd.count) asset(s) to \"\(album.localizedTitle ?? "album")\".")
    }

    /// Convenience: add assets identified by local identifiers.
    func batchAddAssets(withIdentifiers ids: [String], toAlbumNamed albumName: String) async throws {
        let assets  = photoKit.fetchAssets(withIdentifiers: ids)
        guard !assets.isEmpty else { throw PhotoKitError.assetsNotFound(ids) }
        let album   = try await findOrCreateAlbum(named: albumName)
        try await batchAddAssets(assets, to: album)
    }

    // MARK: - Batch Remove

    /// Removes an array of PHAssets from a specific album.
    /// Assets remain in the library — only removed from this album.
    func batchRemoveAssets(_ assets: [PHAsset], from album: PHAssetCollection) async throws {
        guard !assets.isEmpty else { return }

        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.removeAssets(assets as NSArray)
        }

        print("[AlbumOperations] 🗑 Removed \(assets.count) asset(s) from \"\(album.localizedTitle ?? "album")\".")
    }

    // MARK: - Rename Album

    /// Renames an existing album.
    func renameAlbum(_ album: PHAssetCollection, to newName: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.title = newName
        }
        print("[AlbumOperations] ✏️ Renamed album to \"\(newName)\".")
    }

    // MARK: - Delete Album

    /// Deletes an album (the album container only — assets are NOT trashed).
    /// To also trash the assets, use PhotoKitManager.trashAssets() first.
    func deleteAlbum(_ album: PHAssetCollection) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
        print("[AlbumOperations] 🗑 Album deleted: \"\(album.localizedTitle ?? "unknown")\".")
    }

    // MARK: - Move Assets Between Albums

    /// Moves assets from one album to another.
    /// "Move" = remove from source + add to destination.
    /// Assets remain in the library regardless.
    func moveAssets(_ assets: [PHAsset],
                    from source: PHAssetCollection,
                    to destination: PHAssetCollection) async throws {
        try await batchRemoveAssets(assets, from: source)
        try await batchAddAssets(assets, to: destination)
        print("[AlbumOperations] ↔️ Moved \(assets.count) asset(s) from \"\(source.localizedTitle ?? "?")\" to \"\(destination.localizedTitle ?? "?")\".")
    }

    // MARK: - Asset Count

    /// Returns the number of assets in a given album.
    func assetCount(in album: PHAssetCollection) -> Int {
        PHAsset.fetchAssets(in: album, options: nil).count
    }
}
