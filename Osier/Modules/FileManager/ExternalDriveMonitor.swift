//
//  ExternalDriveMonitor.swift
//  Osier — Module A: File & Hardware Manager
//
//  Monitors for connected external storage (USB SSDs, SD cards, thumb drives)
//  via the UIDocumentPickerViewController / FileProvider pathway on iOS.
//  Publishes discovered volumes so the rest of the app can react reactively.
//
//  NOTE: iOS does not expose USB mounts through FileManager the same way
//  macOS does. The correct iOS pathway is:
//  1. User grants access via UIDocumentPickerViewController (one-time per volume)
//  2. App receives a security-scoped URL and bookmarks it for persistent access
//  3. This class stores, restores, and monitors those bookmarked URLs
//

import Foundation
import UIKit
import Combine

// MARK: - External Volume

struct ExternalVolume: Identifiable {
    let id: UUID
    let displayName: String
    let rootURL: URL        // Security-scoped URL
    var totalBytes: Int64
    var availableBytes: Int64
    var usedBytes: Int64 { totalBytes - availableBytes }
    var isActive: Bool      // Whether the security scope is currently open

    enum AccessState {
        case accessible
        case revoked
        case unknown
    }
    var accessState: AccessState = .unknown
}

// MARK: - ExternalDriveMonitor

@MainActor
final class ExternalDriveMonitor: ObservableObject {

    // MARK: - Published State

    /// All currently known external volumes (bookmarked + accessible).
    @Published var connectedVolumes: [ExternalVolume] = []

    /// True while a volume scan / capacity read is in progress.
    @Published var isScanning: Bool = false

    // MARK: - Singleton

    static let shared = ExternalDriveMonitor()
    private init() {
        restoreBookmarkedVolumes()
    }

    private let fm = FileManager.default
    private let bookmarksKey = "osier.externalVolume.bookmarks"

    // MARK: - Volume Access

    /// Call this after the user picks an external directory via UIDocumentPickerViewController.
    /// Creates a security-scoped bookmark so access persists across app launches.
    func registerVolume(from pickedURL: URL) async {
        let accessed = pickedURL.startAccessingSecurityScopedResource()
        defer { if accessed { pickedURL.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try pickedURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            saveBookmark(bookmark, for: pickedURL)

            let volume = await buildVolume(from: pickedURL)
            connectedVolumes.append(volume)

            print("[ExternalDriveMonitor] ✅ Registered: \(pickedURL.lastPathComponent)")
        } catch {
            print("[ExternalDriveMonitor] ❌ Bookmark creation failed: \(error)")
        }
    }

    /// Removes a volume from the monitored list and deletes its stored bookmark.
    func removeVolume(_ volume: ExternalVolume) {
        volume.rootURL.stopAccessingSecurityScopedResource()
        connectedVolumes.removeAll { $0.id == volume.id }
        deleteBookmark(for: volume.rootURL)
        print("[ExternalDriveMonitor] 🗑 Removed: \(volume.displayName)")
    }

    // MARK: - Persistency: Bookmark Storage

    private func saveBookmark(_ data: Data, for url: URL) {
        var stored = loadAllBookmarks()
        stored[url.path] = data
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
    }

    private func deleteBookmark(for url: URL) {
        var stored = loadAllBookmarks()
        stored.removeValue(forKey: url.path)
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
    }

    private func loadAllBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }

    /// On app launch, restore all previously bookmarked external volumes.
    private func restoreBookmarkedVolumes() {
        let bookmarks = loadAllBookmarks()
        guard !bookmarks.isEmpty else { return }

        Task {
            isScanning = true
            for (_, bookmarkData) in bookmarks {
                await restoreVolume(from: bookmarkData)
            }
            isScanning = false
        }
    }

    private func restoreVolume(from bookmarkData: Data) async {
        do {
            var isStale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("[ExternalDriveMonitor] ⚠️ Stale bookmark — prompting re-authorisation required.")
                return
            }

            let accessed = resolvedURL.startAccessingSecurityScopedResource()
            if !accessed {
                print("[ExternalDriveMonitor] ⚠️ Could not access security scope for: \(resolvedURL.lastPathComponent)")
                return
            }

            let volume = await buildVolume(from: resolvedURL)
            connectedVolumes.append(volume)

            print("[ExternalDriveMonitor] ♻️ Restored: \(resolvedURL.lastPathComponent)")
        } catch {
            print("[ExternalDriveMonitor] ❌ Restore failed: \(error)")
        }
    }

    // MARK: - Volume Builder

    private func buildVolume(from url: URL) async -> ExternalVolume {
        var totalBytes: Int64 = 0
        var availableBytes: Int64 = 0

        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            totalBytes     = Int64(values.volumeTotalCapacity ?? 0)
            availableBytes = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        } catch {
            print("[ExternalDriveMonitor] ⚠️ Could not read capacity: \(error)")
        }

        return ExternalVolume(
            id: UUID(),
            displayName: url.lastPathComponent,
            rootURL: url,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            isActive: true,
            accessState: .accessible
        )
    }

    // MARK: - Capacity Refresh

    /// Re-reads capacity for all connected volumes (call periodically or on demand).
    func refreshCapacity() async {
        isScanning = true
        for index in connectedVolumes.indices {
            let url = connectedVolumes[index].rootURL
            do {
                let values = try url.resourceValues(forKeys: [
                    .volumeTotalCapacityKey,
                    .volumeAvailableCapacityForImportantUsageKey
                ])
                connectedVolumes[index].totalBytes     = Int64(values.volumeTotalCapacity ?? 0)
                connectedVolumes[index].availableBytes = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            } catch {
                connectedVolumes[index].accessState = .revoked
                print("[ExternalDriveMonitor] ❌ Volume no longer accessible: \(url.lastPathComponent)")
            }
        }
        isScanning = false
    }

    // MARK: - Space Validation

    /// Returns true if the target volume has enough free space for a given byte count.
    func hasSpace(on volume: ExternalVolume, for bytes: Int64) -> Bool {
        return volume.availableBytes >= bytes
    }
}
