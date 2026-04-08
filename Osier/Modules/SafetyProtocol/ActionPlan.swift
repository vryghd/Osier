//
//  ActionPlan.swift
//  Osier — Module D: Safety & Trash Protocol
//
//  Defines the core data model for every agent action.
//  Nothing executes without first being structured as an ActionPlan
//  and confirmed by the user via the ConfirmActionCard.
//

import Foundation

// MARK: - Action Type

/// Enumerates every destructive or mutating action the agent can perform.
/// Non-destructive reads do not require an ActionPlan.
enum AgentActionType: String, Codable, CaseIterable {
    case moveFile       = "Move File"
    case copyFile       = "Copy File"
    case deleteFile     = "Delete (Trash)"
    case renameFile     = "Rename File"
    case createFolder   = "Create Folder"
    case sortFiles      = "Sort Files"
    case createAlbum    = "Create Photo Album"
    case movePhoto      = "Move Photo"
    case deletePhoto    = "Delete Photo (Recently Deleted)"
    case createNote     = "Create Note"
    case editNote       = "Edit Note"
    case createEvent    = "Create Calendar Event"
    case snoozeReminder = "Snooze Reminder"
    case backupVault    = "Backup Vault"
    case exportPDF      = "Export PDF"
}

// MARK: - Risk Level

/// Classifies the risk of each action so the UI can style confirmation cards accordingly.
enum RiskLevel: String, Codable {
    case low      // e.g., create folder, create note
    case moderate // e.g., move file, rename
    case high     // e.g., delete/trash, bulk sort
}

// MARK: - Action Item

/// A single atomic operation within a plan.
struct ActionItem: Identifiable, Codable {
    let id: UUID
    let type: AgentActionType
    let riskLevel: RiskLevel

    /// Human-readable description shown in the confirmation card.
    let description: String

    /// Source path or identifier (file URL, photo asset ID, note ID, etc.)
    let sourcePath: String?

    /// Destination path or identifier (if applicable).
    let destinationPath: String?

    /// Any additional metadata the executor needs.
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        type: AgentActionType,
        riskLevel: RiskLevel,
        description: String,
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.riskLevel = riskLevel
        self.description = description
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.metadata = metadata
    }
}

// MARK: - Action Plan

/// A complete, ordered list of ActionItems the agent proposes to execute.
/// The plan is presented to the user before ANY execution begins.
struct ActionPlan: Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let actions: [ActionItem]
    let createdAt: Date

    /// The highest risk level among all contained actions.
    var overallRisk: RiskLevel {
        if actions.contains(where: { $0.riskLevel == .high }) { return .high }
        if actions.contains(where: { $0.riskLevel == .moderate }) { return .moderate }
        return .low
    }

    init(
        id: UUID = UUID(),
        title: String,
        summary: String,
        actions: [ActionItem],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.actions = actions
        self.createdAt = createdAt
    }
}
