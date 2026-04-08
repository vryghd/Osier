//
//  iCloudDocumentManager.swift
//  Osier — Module B: VaultAgent
//
//  Background read/write engine for standard documents (.txt, .md, .rtf)
//  exposed in iCloud Drive by any app (Bear, Ulysses, Notes exports, etc.).
//
//  Architecture:
//  - NSMetadataQuery: discovers files within the app's own iCloud ubiquity container
//  - OsierDocument (UIDocument subclass): provides safe conflict detection + resolution
//  - NSFileCoordinator: wraps all reads/writes for externally-picked URLs
//  - SecurityScoped access: opened before every coordinated operation
//
//  For files OUTSIDE the app's container (from other apps), the user must first
//  pick the file via UIDocumentPickerViewController. The returned URL is then
//  passed to read() or write() which handle security scope + coordination.
//

import Foundation
import UIKit

// MARK: - Supported Document Type

enum CloudDocumentType: String, CaseIterable {
    case markdown  = "md"
    case plainText = "txt"
    case richText  = "rtf"

    var utTypeIdentifier: String {
        switch self {
        case .markdown:  return "net.daringfireball.markdown"
        case .plainText: return "public.plain-text"
        case .richText:  return "public.rtf"
        }
    }
}

// MARK: - Discovered Cloud File

struct CloudFile: Identifiable {
    let id: UUID         = UUID()
    let url: URL
    let displayName: String
    let type: CloudDocumentType
    let modifiedAt: Date?
    let sizeBytes: Int?
    var isDownloaded: Bool
}

// MARK: - OsierDocument (UIDocument Subclass)

/// Wraps a single iCloud document for safe read/write with conflict detection.
final class OsierDocument: UIDocument {

    /// The raw string content of the document.
    var content: String = ""

    // MARK: Read

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let data = contents as? Data else { return }

        if typeName == "public.rtf" || typeName?.contains("rtf") == true {
            // Parse RTF into plain string
            let attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            content = attributed.string
        } else {
            content = String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: Write

    override func contents(forType typeName: String) throws -> Any {
        if typeName == "public.rtf" || typeName?.contains("rtf") == true {
            let attributed = NSAttributedString(
                string: content,
                attributes: [.font: UIFont.systemFont(ofSize: 13)]
            )
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
        } else {
            return Data(content.utf8)
        }
    }

    // MARK: Conflict Detection

    override func handleError(_ error: Error, userInteractionPermitted: Bool) {
        print("[OsierDocument] ⚠️ Document error: \(error.localizedDescription)")
        // Prefer local version on conflict — app-level conflict resolution
        if documentState.contains(.inConflict) {
            resolveConflict()
        }
    }

    private func resolveConflict() {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: fileURL),
              !versions.isEmpty else { return }

        // Strategy: keep the most recently modified version
        let sorted = versions.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        if let winner = sorted.first {
            do {
                try winner.replaceItem(at: fileURL)
                try NSFileVersion.removeOtherVersionsOfItem(at: fileURL)
                sorted.dropFirst().forEach { try? $0.remove() }
                print("[OsierDocument] ✅ Conflict resolved: kept version from \(winner.modificationDate?.description ?? "unknown")")
            } catch {
                print("[OsierDocument] ❌ Conflict resolution failed: \(error)")
            }
        }
    }
}

// MARK: - iCloudDocumentManager

@MainActor
final class iCloudDocumentManager: ObservableObject {

    // MARK: - Singleton

    static let shared = iCloudDocumentManager()
    private init() {}

    // MARK: - Published State

    @Published var discoveredFiles: [CloudFile] = []
    @Published var isQuerying: Bool = false

    private var metadataQuery: NSMetadataQuery?
    private let fm = FileManager.default

    // MARK: - iCloud Container Discovery (app's own container)

    /// Starts an NSMetadataQuery to enumerate .md, .txt, .rtf files
    /// in the app's own iCloud ubiquity Documents container.
    func startDiscovery() {
        guard let containerURL = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents") else {
            print("[iCloudDocumentManager] ⚠️ iCloud container not available.")
            return
        }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Filter for supported types
        let extensions = CloudDocumentType.allCases.map { $0.rawValue }
        let predicates = extensions.map { ext in
            NSPredicate(format: "%K ENDSWITH '.%@'",
                        NSMetadataItemFSNameKey, ext)
        }
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )

        metadataQuery = query
        isQuerying = true
        query.start()
        print("[iCloudDocumentManager] 🔍 Discovery started in \(containerURL.path)")
    }

    func stopDiscovery() {
        metadataQuery?.stop()
        metadataQuery = nil
        isQuerying = false
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()

        var files: [CloudFile] = []

        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }

            guard let urlValue = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let ext = urlValue.pathExtension.lowercased()
            guard let docType = CloudDocumentType(rawValue: ext) else { continue }

            let downloaded = (item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadedKey) as? Bool) ?? false
            let modified   = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            let size       = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.intValue

            files.append(CloudFile(
                url: urlValue,
                displayName: urlValue.deletingPathExtension().lastPathComponent,
                type: docType,
                modifiedAt: modified,
                sizeBytes: size,
                isDownloaded: downloaded
            ))
        }

        discoveredFiles = files
        query.enableUpdates()
        print("[iCloudDocumentManager] ✅ Discovered \(files.count) cloud file(s)")
    }

    // MARK: - Coordinated Read (any URL, including externally-picked files)

    /// Reads the string content of any supported document using NSFileCoordinator.
    /// Works with both app-container files and externally-picked security-scoped URLs.
    func read(from url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var result = ""
        var coordinatorError: NSError?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { resolvedURL in
            do {
                let ext = resolvedURL.pathExtension.lowercased()
                if ext == "rtf" {
                    let data = try Data(contentsOf: resolvedURL)
                    let attributed = try NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                        documentAttributes: nil
                    )
                    result = attributed.string
                } else {
                    result = try String(contentsOf: resolvedURL, encoding: .utf8)
                }
            } catch {
                print("[iCloudDocumentManager] ❌ Read error: \(error)")
            }
        }

        if let err = coordinatorError { throw err }
        return result
    }

    // MARK: - Coordinated Write (any URL)

    /// Writes string content to any supported document using NSFileCoordinator.
    /// For .rtf files, content is re-encoded as RTF data.
    func write(content: String, to url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { resolvedURL in
            do {
                let ext = resolvedURL.pathExtension.lowercased()
                if ext == "rtf" {
                    let attributed = NSAttributedString(
                        string: content,
                        attributes: [.font: UIFont.systemFont(ofSize: 13)]
                    )
                    let data = try attributed.data(
                        from: NSRange(location: 0, length: attributed.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    )
                    try data.write(to: resolvedURL, options: .atomic)
                } else {
                    try content.write(to: resolvedURL, atomically: true, encoding: .utf8)
                }
                print("[iCloudDocumentManager] ✅ Written: \(resolvedURL.lastPathComponent)")
            } catch {
                print("[iCloudDocumentManager] ❌ Write error: \(error)")
            }
        }

        if let err = coordinatorError { throw err }
    }

    // MARK: - Coordinated Append

    /// Appends content to an existing document.
    func append(content: String, to url: URL) throws {
        let existing = try read(from: url)
        try write(content: existing + "\n" + content, to: url)
    }

    // MARK: - iCloud Download Trigger

    /// Triggers download of an iCloud file that hasn't been fetched to device yet.
    func downloadIfNeeded(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey,
                                                       .ubiquitousItemDownloadingStatusKey])
        if values.ubiquitousItemDownloadingStatus != .current {
            try fm.startDownloadingUbiquitousItem(at: url)
            print("[iCloudDocumentManager] ⬇️ Triggered download: \(url.lastPathComponent)")
        }
    }

    // MARK: - UIDocument Workflow (for app container files with conflict detection)

    /// Opens a document from the app's iCloud container using UIDocument (with conflict detection).
    func openDocument(at url: URL) async throws -> OsierDocument {
        let doc = OsierDocument(fileURL: url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            doc.open { success in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: iCloudDocumentError.openFailed(url))
                }
            }
        }
        return doc
    }

    /// Saves a UIDocument back to iCloud.
    func saveDocument(_ doc: OsierDocument) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            doc.save(to: doc.fileURL, for: .forOverwriting) { success in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: iCloudDocumentError.saveFailed(doc.fileURL))
                }
            }
        }
    }
}

// MARK: - Errors

enum iCloudDocumentError: LocalizedError {
    case openFailed(URL), saveFailed(URL), containerUnavailable

    var errorDescription: String? {
        switch self {
        case .openFailed(let u):  return "Failed to open document: \(u.lastPathComponent)"
        case .saveFailed(let u):  return "Failed to save document: \(u.lastPathComponent)"
        case .containerUnavailable: return "iCloud container is not available. Check iCloud sign-in."
        }
    }
}
