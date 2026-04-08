//
//  SafetyProtocol.swift
//  Osier — Module D: Safety & Trash Protocol
//
//  The central execution engine for all agent actions.
//  Enforces the confirmation-first pattern:
//  1. Agent BUILDS a plan  →  2. User CONFIRMS  →  3. Engine EXECUTES
//  Deletion is ALWAYS routed to system trash — never hard-deleted.
//

import Foundation
import Photos

// MARK: - Execution Result

enum ExecutionResult {
    case success(message: String)
    case partialSuccess(completed: [ActionItem], failed: [ActionItem])
    case failure(error: Error, item: ActionItem)
    case cancelledByUser
}

// MARK: - SafetyProtocol Engine

@MainActor
final class SafetyProtocolEngine: ObservableObject {

    // MARK: - State

    /// The queued plan awaiting user confirmation. Nil if nothing is pending.
    @Published var pendingPlan: ActionPlan? = nil

    /// Whether the confirmation card is visible.
    @Published var isShowingConfirmation: Bool = false

    /// Result of the last execution, used to display feedback.
    @Published var lastResult: ExecutionResult? = nil

    /// Audit log of every plan that was processed this session.
    @Published var auditLog: [AuditEntry] = []

    // MARK: - Plan Queuing

    /// Called by the LLM engine when it has parsed a command into a plan.
    /// This does NOT execute anything — it surfaces the confirmation card.
    func queuePlan(_ plan: ActionPlan) {
        pendingPlan = plan
        isShowingConfirmation = true
    }

    // MARK: - Execution (after user confirms)

    /// Executes the pending plan only after explicit user confirmation.
    func confirmAndExecute() async {
        guard let plan = pendingPlan else { return }
        isShowingConfirmation = false
        pendingPlan = nil

        var completed: [ActionItem] = []
        var failed: [ActionItem] = []

        for action in plan.actions {
            do {
                try await execute(action)
                completed.append(action)
            } catch {
                failed.append(action)
                print("[SafetyProtocol] ❌ Failed action: \(action.description) — \(error)")
            }
        }

        let result: ExecutionResult = failed.isEmpty
            ? .success(message: "\(completed.count) action(s) completed.")
            : .partialSuccess(completed: completed, failed: failed)

        lastResult = result
        logAudit(plan: plan, result: result)
    }

    /// User cancelled — plan is discarded. Nothing executed.
    func cancelPlan() {
        guard let plan = pendingPlan else { return }
        isShowingConfirmation = false
        logAudit(plan: plan, result: .cancelledByUser)
        pendingPlan = nil
        lastResult = .cancelledByUser
    }

    // MARK: - Action Router

    private func execute(_ action: ActionItem) async throws {
        switch action.type {
        case .moveFile, .copyFile, .renameFile, .createFolder, .sortFiles, .exportPDF:
            try executeFileAction(action)

        case .deleteFile:
            try trashFile(action)

        case .createAlbum, .movePhoto:
            try await executePhotoAction(action)

        case .deletePhoto:
            try await trashPhoto(action)

        case .createNote, .editNote:
            // Module B handles note writing — stubbed here for Module D routing
            print("[SafetyProtocol] Note action delegated to VaultAgent: \(action.description)")

        case .createEvent, .snoozeReminder:
            // Module B handles EventKit — stubbed here
            print("[SafetyProtocol] Calendar action delegated to VaultAgent: \(action.description)")

        case .backupVault:
            print("[SafetyProtocol] Backup action delegated to FileManager: \(action.description)")
        }
    }

    // MARK: - File Actions

    private func executeFileAction(_ action: ActionItem) throws {
        let fm = FileManager.default

        switch action.type {
        case .moveFile:
            guard let src = action.sourcePath, let dst = action.destinationPath else {
                throw SafetyError.missingPath
            }
            let srcURL = URL(fileURLWithPath: src)
            let dstURL = URL(fileURLWithPath: dst)
            try fm.moveItem(at: srcURL, to: dstURL)

        case .copyFile:
            guard let src = action.sourcePath, let dst = action.destinationPath else {
                throw SafetyError.missingPath
            }
            try fm.copyItem(at: URL(fileURLWithPath: src), to: URL(fileURLWithPath: dst))

        case .renameFile:
            guard let src = action.sourcePath, let dst = action.destinationPath else {
                throw SafetyError.missingPath
            }
            try fm.moveItem(at: URL(fileURLWithPath: src), to: URL(fileURLWithPath: dst))

        case .createFolder:
            guard let dst = action.destinationPath else { throw SafetyError.missingPath }
            try fm.createDirectory(at: URL(fileURLWithPath: dst),
                                   withIntermediateDirectories: true)

        default:
            print("[SafetyProtocol] File action not yet implemented: \(action.type.rawValue)")
        }
    }

    /// Routes a file to the system trash instead of hard-deleting.
    private func trashFile(_ action: ActionItem) throws {
        guard let src = action.sourcePath else { throw SafetyError.missingPath }
        let srcURL = URL(fileURLWithPath: src)
        var resultURL: NSURL?
        try FileManager.default.trashItem(at: srcURL, resultingItemURL: &resultURL)
        print("[SafetyProtocol] 🗑 Trashed: \(src) → \(resultURL?.path ?? "system trash")")
    }

    // MARK: - Photo Actions

    private func executePhotoAction(_ action: ActionItem) async throws {
        // PhotoKit mutations must happen inside a performChanges block
        try await PHPhotoLibrary.shared().performChanges {
            switch action.type {
            case .createAlbum:
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: action.metadata["albumName"] ?? "New Album"
                )
                _ = request
            case .movePhoto:
                // Moving requires fetching the asset and adding to collection
                // Full implementation in Module C (GalleryAgent)
                print("[SafetyProtocol] Photo move delegated to GalleryAgent")
            default:
                break
            }
        }
    }

    /// Routes a photo to iOS "Recently Deleted" — never permanently removed.
    private func trashPhoto(_ action: ActionItem) async throws {
        guard let assetID = action.sourcePath else { throw SafetyError.missingPath }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = result.firstObject else { throw SafetyError.assetNotFound }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
        // Note: iOS routes this to "Recently Deleted" automatically — 30-day window preserved.
        print("[SafetyProtocol] 🗑 Photo routed to Recently Deleted: \(assetID)")
    }

    // MARK: - Audit Log

    private func logAudit(plan: ActionPlan, result: ExecutionResult) {
        let entry = AuditEntry(plan: plan, result: result, timestamp: Date())
        auditLog.append(entry)
    }
}

// MARK: - Audit Entry

struct AuditEntry: Identifiable {
    let id = UUID()
    let plan: ActionPlan
    let result: ExecutionResult
    let timestamp: Date
}

// MARK: - Safety Errors

enum SafetyError: LocalizedError {
    case missingPath
    case assetNotFound
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .missingPath:       return "Source or destination path is missing."
        case .assetNotFound:     return "Could not locate the specified media asset."
        case .permissionDenied:  return "Permission was denied for this action."
        }
    }
}
