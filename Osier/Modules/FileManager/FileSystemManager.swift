//
//  FileSystemManager.swift
//  Osier — Module A: File & Hardware Manager
//
//  Core file system engine. Handles directory scanning, file metadata
//  resolution, and storage capacity calculations across Internal, iCloud,
//  and External volumes. All destructive operations are delegated to
//  SafetyProtocolEngine — never executed directly here.
//

import Foundation

// MARK: - Storage Volume

/// Represents a mounted storage volume available to the app.
struct StorageVolume: Identifiable {
    let id: UUID
    let name: String
    let kind: VolumeKind
    let rootURL: URL
    var totalBytes: Int64
    var availableBytes: Int64

    var usedBytes: Int64 { totalBytes - availableBytes }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }

    enum VolumeKind {
        case `internal`
        case iCloud
        case external   // USB SSD, SD card, etc.
    }
}

// MARK: - File Item

/// A lightweight descriptor for a single file or directory.
struct FileItem: Identifiable {
    let id: UUID
    let url: URL
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let contentType: String?    // UTType identifier string
    var children: [FileItem]?   // Populated only for directories when expanded

    init(url: URL, attributes: [FileAttributeKey: Any]) {
        self.id          = UUID()
        self.url         = url
        self.name        = url.lastPathComponent
        self.isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        self.sizeBytes   = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        self.createdAt   = attributes[.creationDate] as? Date
        self.modifiedAt  = attributes[.modificationDate] as? Date
        self.contentType = nil
        self.children    = nil
    }
}

// MARK: - Scan Options

struct ScanOptions {
    /// Whether to recurse into subdirectories.
    var recursive: Bool = false
    /// File extensions to include. Empty = all.
    var filterExtensions: [String] = []
    /// Skip hidden files (names starting with ".").
    var skipHidden: Bool = true
    /// Maximum number of items to return (0 = unlimited).
    var limit: Int = 0
}

// MARK: - FileSystemManager

@MainActor
final class FileSystemManager: ObservableObject {

    // MARK: - Published State

    @Published var internalVolume: StorageVolume? = nil
    @Published var iCloudVolume: StorageVolume? = nil

    // MARK: - Singleton

    static let shared = FileSystemManager()
    private init() {}

    private let fm = FileManager.default

    // MARK: - Storage Refresh

    /// Refreshes storage capacity for Internal and iCloud volumes.
    func refreshStorageInfo() {
        internalVolume = buildInternalVolume()
        iCloudVolume   = buildiCloudVolume()
    }

    private func buildInternalVolume() -> StorageVolume? {
        guard let homeURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let (total, available) = storageCapacity(for: homeURL)
        return StorageVolume(
            id: UUID(),
            name: "iPhone Storage",
            kind: .internal,
            rootURL: homeURL,
            totalBytes: total,
            availableBytes: available
        )
    }

    private func buildiCloudVolume() -> StorageVolume? {
        guard let iCloudURL = fm.url(forUbiquityContainerIdentifier: nil) else {
            return nil  // iCloud not available / not signed in
        }
        let (total, available) = storageCapacity(for: iCloudURL)
        return StorageVolume(
            id: UUID(),
            name: "iCloud Drive",
            kind: .iCloud,
            rootURL: iCloudURL,
            totalBytes: total,
            availableBytes: available
        )
    }

    /// Reads filesystem capacity values from resource values on a URL.
    private func storageCapacity(for url: URL) -> (total: Int64, available: Int64) {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            let total     = Int64(values.volumeTotalCapacity ?? 0)
            let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            return (total, available)
        } catch {
            print("[FileSystemManager] ⚠️ Could not read capacity for \(url.path): \(error)")
            return (0, 0)
        }
    }

    // MARK: - Directory Scanning

    /// Returns a flat list of FileItems at the given URL.
    func scan(directory url: URL, options: ScanOptions = ScanOptions()) throws -> [FileItem] {
        guard fm.fileExists(atPath: url.path) else {
            throw FileSystemError.directoryNotFound(url)
        }

        var resourceKeys: [URLResourceKey] = [
            .nameKey,
            .isDirectoryKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        let enumeratorOptions: FileManager.DirectoryEnumerationOptions = options.skipHidden
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsPackageDescendants]

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: enumeratorOptions
        ) else {
            throw FileSystemError.scanFailed(url)
        }

        var results: [FileItem] = []

        for case let fileURL as URL in enumerator {
            // Respect recursive flag
            if !options.recursive {
                enumerator.skipDescendants()
            }

            // Filter by extension if specified
            if !options.filterExtensions.isEmpty {
                let ext = fileURL.pathExtension.lowercased()
                guard options.filterExtensions.contains(ext) else { continue }
            }

            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            let item = FileItem(url: fileURL, attributes: attrs)
            results.append(item)

            if options.limit > 0 && results.count >= options.limit { break }
        }

        return results
    }

    // MARK: - File Metadata

    /// Returns detailed attributes for a single file.
    func attributes(of url: URL) throws -> [FileAttributeKey: Any] {
        try fm.attributesOfItem(atPath: url.path)
    }

    /// Returns the total size of all files in a directory, recursively.
    func totalSize(of directoryURL: URL) throws -> Int64 {
        let items = try scan(directory: directoryURL, options: ScanOptions(recursive: true))
        return items.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Common Directory URLs

    var documentsURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var downloadsURL: URL {
        fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? documentsURL.appendingPathComponent("Downloads")
    }

    var tempURL: URL { fm.temporaryDirectory }

    // MARK: - Duplicate Detection

    /// Groups files by size — files with identical sizes are candidates for deduplication.
    /// A full content hash would be performed as a follow-up (expensive for large files).
    func findSizeDuplicateCandidates(in urls: [URL]) throws -> [[FileItem]] {
        var sizeMap: [Int64: [FileItem]] = [:]

        for url in urls {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let item = FileItem(url: url, attributes: attrs)
            sizeMap[item.sizeBytes, default: []].append(item)
        }

        return sizeMap.values.filter { $0.count > 1 }
    }

    /// Computes a SHA-256 hash of a file's contents for exact duplicate detection.
    func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - FileSystem Errors

enum FileSystemError: LocalizedError {
    case directoryNotFound(URL)
    case scanFailed(URL)
    case insufficientSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound(let url):
            return "Directory not found: \(url.lastPathComponent)"
        case .scanFailed(let url):
            return "Failed to enumerate: \(url.lastPathComponent)"
        case .insufficientSpace(let needed, let available):
            let fmt = ByteCountFormatter()
            return "Not enough space. Need \(fmt.string(fromByteCount: needed)), have \(fmt.string(fromByteCount: available))."
        }
    }
}

// MARK: - CommonCrypto bridge (SHA-256)
// Declared here to avoid importing CryptoKit (which requires iOS 13 target minimum)
import CommonCrypto
