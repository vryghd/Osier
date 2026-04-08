//
//  FileActionBuilder.swift
//  Osier — Module A: File & Hardware Manager
//
//  Translates raw agent intent (parsed from user commands or LLM output)
//  into typed ActionPlan objects that Module D's SafetyProtocolEngine
//  can queue, present for confirmation, and execute.
//
//  This is the bridge between language and system action.
//  Nothing here touches the filesystem — it only builds plans.
//

import Foundation

// MARK: - Agent Intent

/// Structured intent resolved from a user command before it becomes an ActionPlan.
struct AgentIntent {
    enum Kind {
        case moveFiles(sources: [URL], destination: URL)
        case copyFiles(sources: [URL], destination: URL)
        case deleteFiles(targets: [URL])
        case sortFolder(source: URL, strategy: SortStrategy)
        case clearDownloads
        case backupVault(source: URL, destination: URL)
        case exportToPDF(sourceURL: URL, outputName: String)
        case moveToExternal(sources: [URL], volume: ExternalVolume)
        case deduplicateFolder(source: URL)
    }

    let kind: Kind
    let rawCommand: String  // The original text the user typed
}

// MARK: - Sort Strategy

enum SortStrategy: String, CaseIterable {
    case byType         = "By File Type"
    case byDate         = "By Date Modified"
    case bySize         = "By Size"
    case alphabetical   = "Alphabetically"
}

// MARK: - FileActionBuilder

final class FileActionBuilder {

    // MARK: - Singleton

    static let shared = FileActionBuilder()
    private init() {}

    private let fm = FileManager.default

    // MARK: - Plan Construction

    /// Builds a complete ActionPlan from a structured AgentIntent.
    /// Returns nil if the intent cannot be resolved to a valid plan.
    func buildPlan(from intent: AgentIntent) throws -> ActionPlan {
        switch intent.kind {

        case .moveFiles(let sources, let destination):
            return try buildMovePlan(sources: sources, destination: destination, rawCommand: intent.rawCommand)

        case .copyFiles(let sources, let destination):
            return try buildCopyPlan(sources: sources, destination: destination, rawCommand: intent.rawCommand)

        case .deleteFiles(let targets):
            return buildDeletePlan(targets: targets, rawCommand: intent.rawCommand)

        case .sortFolder(let source, let strategy):
            return try buildSortPlan(source: source, strategy: strategy, rawCommand: intent.rawCommand)

        case .clearDownloads:
            return try buildClearDownloadsPlan(rawCommand: intent.rawCommand)

        case .backupVault(let source, let destination):
            return buildBackupPlan(source: source, destination: destination, rawCommand: intent.rawCommand)

        case .exportToPDF(let sourceURL, let outputName):
            return buildExportPDFPlan(sourceURL: sourceURL, outputName: outputName, rawCommand: intent.rawCommand)

        case .moveToExternal(let sources, let volume):
            return try buildMoveToExternalPlan(sources: sources, volume: volume, rawCommand: intent.rawCommand)

        case .deduplicateFolder(let source):
            return try buildDeduplicatePlan(source: source, rawCommand: intent.rawCommand)
        }
    }

    // MARK: - Move Plan

    private func buildMovePlan(sources: [URL], destination: URL, rawCommand: String) throws -> ActionPlan {
        var actions: [ActionItem] = []

        // Ensure destination exists or create it
        if !fm.fileExists(atPath: destination.path) {
            actions.append(ActionItem(
                type: .createFolder,
                riskLevel: .low,
                description: "Create destination folder: \(destination.lastPathComponent)",
                destinationPath: destination.path
            ))
        }

        for source in sources {
            let dest = destination.appendingPathComponent(source.lastPathComponent)
            actions.append(ActionItem(
                type: .moveFile,
                riskLevel: .moderate,
                description: "Move \"\(source.lastPathComponent)\" → \(destination.lastPathComponent)/",
                sourcePath: source.path,
                destinationPath: dest.path
            ))
        }

        return ActionPlan(
            title: "Move \(sources.count) File\(sources.count == 1 ? "" : "s")",
            summary: "Move to \(destination.lastPathComponent). Original locations will be cleared.",
            actions: actions
        )
    }

    // MARK: - Copy Plan

    private func buildCopyPlan(sources: [URL], destination: URL, rawCommand: String) throws -> ActionPlan {
        var actions: [ActionItem] = []

        if !fm.fileExists(atPath: destination.path) {
            actions.append(ActionItem(
                type: .createFolder,
                riskLevel: .low,
                description: "Create destination folder: \(destination.lastPathComponent)",
                destinationPath: destination.path
            ))
        }

        for source in sources {
            let dest = destination.appendingPathComponent(source.lastPathComponent)
            actions.append(ActionItem(
                type: .copyFile,
                riskLevel: .low,
                description: "Copy \"\(source.lastPathComponent)\" → \(destination.lastPathComponent)/",
                sourcePath: source.path,
                destinationPath: dest.path
            ))
        }

        return ActionPlan(
            title: "Copy \(sources.count) File\(sources.count == 1 ? "" : "s")",
            summary: "Copies will be made at \(destination.lastPathComponent). Originals are untouched.",
            actions: actions
        )
    }

    // MARK: - Delete (Trash) Plan

    private func buildDeletePlan(targets: [URL], rawCommand: String) -> ActionPlan {
        let actions = targets.map { url in
            ActionItem(
                type: .deleteFile,
                riskLevel: .high,
                description: "Trash \"\(url.lastPathComponent)\"",
                sourcePath: url.path,
                metadata: ["originalCommand": rawCommand]
            )
        }

        return ActionPlan(
            title: "Move \(targets.count) Item\(targets.count == 1 ? "" : "s") to Trash",
            summary: "Items will be routed to the system Trash. You have 30 days to recover them.",
            actions: actions
        )
    }

    // MARK: - Sort Plan

    private func buildSortPlan(source: URL, strategy: SortStrategy, rawCommand: String) throws -> ActionPlan {
        let items = try FileSystemManager.shared.scan(directory: source, options: ScanOptions(recursive: false, skipHidden: true))

        // Group files by strategy
        let groups = group(items: items, by: strategy)

        var actions: [ActionItem] = []

        for (groupName, groupItems) in groups {
            let subfolder = source.appendingPathComponent(groupName)

            if !fm.fileExists(atPath: subfolder.path) {
                actions.append(ActionItem(
                    type: .createFolder,
                    riskLevel: .low,
                    description: "Create subfolder: \(groupName)",
                    destinationPath: subfolder.path
                ))
            }

            for item in groupItems where !item.isDirectory {
                let dest = subfolder.appendingPathComponent(item.name)
                actions.append(ActionItem(
                    type: .moveFile,
                    riskLevel: .moderate,
                    description: "Move \"\(item.name)\" → \(groupName)/",
                    sourcePath: item.url.path,
                    destinationPath: dest.path
                ))
            }
        }

        return ActionPlan(
            title: "Sort \"\(source.lastPathComponent)\" \(strategy.rawValue)",
            summary: "\(actions.filter { $0.type == .moveFile }.count) files will be organized into \(groups.count) subfolders.",
            actions: actions
        )
    }

    // MARK: - Clear Downloads Plan

    private func buildClearDownloadsPlan(rawCommand: String) throws -> ActionPlan {
        let downloadsURL = FileSystemManager.shared.downloadsURL
        let items = try FileSystemManager.shared.scan(directory: downloadsURL, options: ScanOptions(skipHidden: true))
        return buildDeletePlan(targets: items.map { $0.url }, rawCommand: rawCommand)
    }

    // MARK: - Backup Plan

    private func buildBackupPlan(source: URL, destination: URL, rawCommand: String) -> ActionPlan {
        let action = ActionItem(
            type: .backupVault,
            riskLevel: .low,
            description: "Sync \"\(source.lastPathComponent)\" → \(destination.lastPathComponent)",
            sourcePath: source.path,
            destinationPath: destination.path,
            metadata: ["trigger": "manual", "originalCommand": rawCommand]
        )

        return ActionPlan(
            title: "Backup \"\(source.lastPathComponent)\"",
            summary: "Contents will be synced to \(destination.lastPathComponent). Existing files are not deleted.",
            actions: [action]
        )
    }

    // MARK: - Export PDF Plan

    private func buildExportPDFPlan(sourceURL: URL, outputName: String, rawCommand: String) -> ActionPlan {
        let action = ActionItem(
            type: .exportPDF,
            riskLevel: .low,
            description: "Export \"\(sourceURL.lastPathComponent)\" as \(outputName).pdf",
            sourcePath: sourceURL.path,
            metadata: ["outputName": outputName, "originalCommand": rawCommand]
        )

        return ActionPlan(
            title: "Export PDF: \(outputName)",
            summary: "A PDF will be created from \(sourceURL.lastPathComponent) and saved to Documents.",
            actions: [action]
        )
    }

    // MARK: - Move to External Plan

    private func buildMoveToExternalPlan(sources: [URL], volume: ExternalVolume, rawCommand: String) throws -> ActionPlan {
        // Validate space
        let totalSize = sources.compactMap { try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int64 }.reduce(0, +)

        guard ExternalDriveMonitor.shared.hasSpace(on: volume, for: totalSize) else {
            throw FileSystemError.insufficientSpace(needed: totalSize, available: volume.availableBytes)
        }

        var actions: [ActionItem] = []

        for source in sources {
            let dest = volume.rootURL.appendingPathComponent(source.lastPathComponent)
            actions.append(ActionItem(
                type: .moveFile,
                riskLevel: .high,
                description: "Move \"\(source.lastPathComponent)\" to \(volume.displayName)",
                sourcePath: source.path,
                destinationPath: dest.path,
                metadata: ["externalVolume": volume.displayName]
            ))
        }

        return ActionPlan(
            title: "Move \(sources.count) File\(sources.count == 1 ? "" : "s") to \(volume.displayName)",
            summary: "Files will be moved from internal storage to the external drive. This frees internal space.",
            actions: actions
        )
    }

    // MARK: - Deduplicate Plan

    private func buildDeduplicatePlan(source: URL, rawCommand: String) throws -> ActionPlan {
        let items = try FileSystemManager.shared.scan(directory: source, options: ScanOptions(recursive: true))
        let allURLs = items.map { $0.url }
        let candidateGroups = try FileSystemManager.shared.findSizeDuplicateCandidates(in: allURLs)

        var targets: [URL] = []

        for group in candidateGroups {
            // Keep the most recently modified; mark the rest for trash
            let sorted = group.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
            targets.append(contentsOf: sorted.dropFirst().map { $0.url })
        }

        guard !targets.isEmpty else {
            return ActionPlan(
                title: "No Duplicates Found",
                summary: "No size-duplicate candidates were found in \(source.lastPathComponent).",
                actions: []
            )
        }

        return buildDeletePlan(targets: targets, rawCommand: rawCommand)
    }

    // MARK: - Grouping Helpers

    private func group(items: [FileItem], by strategy: SortStrategy) -> [String: [FileItem]] {
        switch strategy {
        case .byType:
            return Dictionary(grouping: items) { item in
                item.url.pathExtension.isEmpty ? "Other" : item.url.pathExtension.uppercased()
            }
        case .byDate:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            return Dictionary(grouping: items) { item in
                guard let date = item.modifiedAt else { return "Unknown" }
                return formatter.string(from: date)
            }
        case .bySize:
            return Dictionary(grouping: items) { item in
                switch item.sizeBytes {
                case 0..<1_000_000:        return "Small (< 1 MB)"
                case 1_000_000..<50_000_000: return "Medium (1–50 MB)"
                default:                   return "Large (> 50 MB)"
                }
            }
        case .alphabetical:
            return Dictionary(grouping: items) { item in
                String(item.name.prefix(1).uppercased())
            }
        }
    }
}
