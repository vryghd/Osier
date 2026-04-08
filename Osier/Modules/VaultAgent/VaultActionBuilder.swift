//
//  VaultActionBuilder.swift
//  Osier — Module B: VaultAgent
//
//  Translates typed VaultIntent values into ActionPlan objects for Module D.
//  Zero side effects — pure plan construction.
//  All plans route through SafetyProtocolEngine before any execution.
//

import Foundation
import EventKit

// MARK: - VaultIntent

/// All vault-related agent intentions. Produced by the LLM command parser.
enum VaultIntent {

    // MARK: Vault / Markdown
    case createNote(vaultName: String, filename: String, content: String,
                    subpath: String?, tags: [String])
    case appendToNote(vaultName: String, filename: String, content: String, subpath: String?)
    case writeDailyNote(vaultName: String, content: String)
    case insertUnderHeading(vaultName: String, filename: String, heading: String,
                            content: String, subpath: String?)
    case editCloudDocument(fileURL: URL, newContent: String)
    case appendToCloudDocument(fileURL: URL, content: String)

    // MARK: Apple Notes
    case createAppleNote(title: String, body: String, tags: [String])
    case appendToAppleNote(noteTitle: String, content: String)

    // MARK: Calendar
    case createCalendarEvent(title: String, startDate: Date, endDate: Date,
                             calendarTitle: String?, location: String?, notes: String?)
    case updateCalendarEvent(identifier: String, newTitle: String?,
                             newStartDate: Date?, newEndDate: Date?, newNotes: String?)
    case deleteCalendarEvent(identifier: String)

    // MARK: Reminders
    case createReminder(title: String, dueDate: Date?, listTitle: String?,
                        notes: String?, priority: Int)
    case completeReminder(identifier: String)
    case deleteReminder(identifier: String)
    case snoozeLowPriorityReminders(listTitle: String?, intervalDays: Int)

    // Associated raw command string for audit
    var rawCommand: String { "" }
}

// MARK: - VaultActionBuilder

final class VaultActionBuilder {

    static let shared = VaultActionBuilder()
    private init() {}

    // MARK: - Entry Point

    func buildPlan(from intent: VaultIntent, rawCommand: String = "") throws -> ActionPlan {
        switch intent {

        // MARK: Vault / Markdown Plans

        case .createNote(let vault, let filename, let content, let subpath, let tags):
            return ActionPlan(
                title: "Create Note: \(filename)",
                summary: "Create a new note \"\(filename)\" in \"\(vault)\"" +
                         (subpath.map { " / \($0)" } ?? "") + ".",
                actions: [
                    ActionItem(
                        type: .createNote,
                        riskLevel: .low,
                        description: "Write \"\(filename).md\" to vault \"\(vault)\"",
                        destinationPath: subpath.map { "\(vault)/\($0)/\(filename).md" }
                            ?? "\(vault)/\(filename).md",
                        metadata: buildNoteMetadata(vault: vault, filename: filename,
                                                    content: content, subpath: subpath,
                                                    mode: "create", tags: tags,
                                                    rawCommand: rawCommand)
                    )
                ]
            )

        case .appendToNote(let vault, let filename, let content, let subpath):
            return ActionPlan(
                title: "Append to Note: \(filename)",
                summary: "Append content to \"\(filename)\" in vault \"\(vault)\".",
                actions: [
                    ActionItem(
                        type: .editNote,
                        riskLevel: .low,
                        description: "Append to \"\(filename).md\" in vault \"\(vault)\"",
                        sourcePath: subpath.map { "\(vault)/\($0)/\(filename).md" }
                            ?? "\(vault)/\(filename).md",
                        metadata: buildNoteMetadata(vault: vault, filename: filename,
                                                    content: content, subpath: subpath,
                                                    mode: "appendToEnd", rawCommand: rawCommand)
                    )
                ]
            )

        case .writeDailyNote(let vault, let content):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let dateStr = formatter.string(from: Date())
            return ActionPlan(
                title: "Daily Note — \(dateStr)",
                summary: "Append timestamped entry to today's daily note in vault \"\(vault)\".",
                actions: [
                    ActionItem(
                        type: .createNote,
                        riskLevel: .low,
                        description: "Write to \(dateStr).md in vault \"\(vault)\"",
                        destinationPath: "\(vault)/Daily Notes/\(dateStr).md",
                        metadata: ["vault": vault, "content": content,
                                   "mode": "createOrAppend", "timestamped": "true",
                                   "rawCommand": rawCommand]
                    )
                ]
            )

        case .insertUnderHeading(let vault, let filename, let heading, let content, let subpath):
            return ActionPlan(
                title: "Insert Under Heading: \"\(heading)\"",
                summary: "Insert content under heading \"\(heading)\" in \"\(filename)\".",
                actions: [
                    ActionItem(
                        type: .editNote,
                        riskLevel: .moderate,
                        description: "Insert under \"\(heading)\" in \"\(filename).md\" (vault: \(vault))",
                        sourcePath: subpath.map { "\(vault)/\($0)/\(filename).md" }
                            ?? "\(vault)/\(filename).md",
                        metadata: buildNoteMetadata(vault: vault, filename: filename,
                                                    content: content, subpath: subpath,
                                                    mode: "insertUnderHeading",
                                                    heading: heading, rawCommand: rawCommand)
                    )
                ]
            )

        case .editCloudDocument(let fileURL, let newContent):
            return ActionPlan(
                title: "Edit Cloud Document: \(fileURL.lastPathComponent)",
                summary: "Overwrite content of \"\(fileURL.lastPathComponent)\" in iCloud Drive.",
                actions: [
                    ActionItem(
                        type: .editNote,
                        riskLevel: .moderate,
                        description: "Overwrite \"\(fileURL.lastPathComponent)\"",
                        sourcePath: fileURL.path,
                        metadata: ["content": newContent, "action": "overwrite",
                                   "rawCommand": rawCommand]
                    )
                ]
            )

        case .appendToCloudDocument(let fileURL, let content):
            return ActionPlan(
                title: "Append to: \(fileURL.lastPathComponent)",
                summary: "Append content to \"\(fileURL.lastPathComponent)\" in iCloud Drive.",
                actions: [
                    ActionItem(
                        type: .editNote,
                        riskLevel: .low,
                        description: "Append to \"\(fileURL.lastPathComponent)\"",
                        sourcePath: fileURL.path,
                        metadata: ["content": content, "action": "append",
                                   "rawCommand": rawCommand]
                    )
                ]
            )

        // MARK: Apple Notes Plans

        case .createAppleNote(let title, let body, let tags):
            return ActionPlan(
                title: "Create Apple Note: \"\(title)\"",
                summary: "Stage note \"\(title)\" for delivery to Apple Notes via Shortcuts.",
                actions: [
                    ActionItem(
                        type: .createNote,
                        riskLevel: .low,
                        description: "Stage note \"\(title)\" in Osier staging area",
                        metadata: ["noteTitle": title, "body": body,
                                   "tags": tags.joined(separator: ","),
                                   "target": "appleNotes", "action": "create",
                                   "rawCommand": rawCommand]
                    )
                ]
            )

        case .appendToAppleNote(let noteTitle, let content):
            return ActionPlan(
                title: "Append to Apple Note: \"\(noteTitle)\"",
                summary: "Append content to staged note \"\(noteTitle)\".",
                actions: [
                    ActionItem(
                        type: .editNote,
                        riskLevel: .low,
                        description: "Append to staged note \"\(noteTitle)\"",
                        metadata: ["noteTitle": noteTitle, "content": content,
                                   "target": "appleNotes", "action": "append",
                                   "rawCommand": rawCommand]
                    )
                ]
            )

        // MARK: Calendar Plans

        case .createCalendarEvent(let title, let start, let end,
                                  let calTitle, let location, let notes):
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
            return ActionPlan(
                title: "Create Event: \"\(title)\"",
                summary: "\(fmt.string(from: start)) → \(fmt.string(from: end))" +
                         (calTitle.map { " in \($0)" } ?? ""),
                actions: [
                    ActionItem(
                        type: .createEvent,
                        riskLevel: .low,
                        description: "Add \"\(title)\" to Calendar",
                        metadata: buildEventMetadata(title: title, startDate: start,
                                                     endDate: end, calendarTitle: calTitle,
                                                     location: location, notes: notes,
                                                     rawCommand: rawCommand)
                    )
                ]
            )

        case .updateCalendarEvent(let id, let newTitle, let newStart, let newEnd, let newNotes):
            return ActionPlan(
                title: "Update Calendar Event",
                summary: "Modify event \(id.prefix(8))…",
                actions: [
                    ActionItem(
                        type: .createEvent,
                        riskLevel: .moderate,
                        description: "Update event with identifier \(id.prefix(8))…",
                        metadata: [
                            "eventID":   id,
                            "newTitle":  newTitle ?? "",
                            "newNotes":  newNotes ?? "",
                            "action":    "update",
                            "rawCommand": rawCommand
                        ]
                    )
                ]
            )

        case .deleteCalendarEvent(let id):
            return ActionPlan(
                title: "Delete Calendar Event",
                summary: "Remove event \(id.prefix(8))… from Calendar.",
                actions: [
                    ActionItem(
                        type: .createEvent,
                        riskLevel: .high,
                        description: "Delete event \(id.prefix(8))… from Calendar",
                        metadata: ["eventID": id, "action": "delete", "rawCommand": rawCommand]
                    )
                ]
            )

        // MARK: Reminder Plans

        case .createReminder(let title, let dueDate, let listTitle, let notes, let priority):
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .short
            let dueSummary = dueDate.map { " due \(fmt.string(from: $0))" } ?? ""
            return ActionPlan(
                title: "Create Reminder: \"\(title)\"",
                summary: "Add reminder \"\(title)\"\(dueSummary)" +
                         (listTitle.map { " to \($0)" } ?? ""),
                actions: [
                    ActionItem(
                        type: .snoozeReminder,
                        riskLevel: .low,
                        description: "Create reminder \"\(title)\"",
                        metadata: buildReminderMetadata(title: title, dueDate: dueDate,
                                                        listTitle: listTitle, notes: notes,
                                                        priority: priority, action: "create",
                                                        rawCommand: rawCommand)
                    )
                ]
            )

        case .completeReminder(let id):
            return ActionPlan(
                title: "Complete Reminder",
                summary: "Mark reminder \(id.prefix(8))… as completed.",
                actions: [
                    ActionItem(
                        type: .snoozeReminder,
                        riskLevel: .low,
                        description: "Complete reminder \(id.prefix(8))…",
                        metadata: ["reminderID": id, "action": "complete", "rawCommand": rawCommand]
                    )
                ]
            )

        case .deleteReminder(let id):
            return ActionPlan(
                title: "Delete Reminder",
                summary: "Remove reminder \(id.prefix(8))… from Reminders.",
                actions: [
                    ActionItem(
                        type: .snoozeReminder,
                        riskLevel: .high,
                        description: "Delete reminder \(id.prefix(8))…",
                        metadata: ["reminderID": id, "action": "delete", "rawCommand": rawCommand]
                    )
                ]
            )

        case .snoozeLowPriorityReminders(let listTitle, let intervalDays):
            let listSummary = listTitle.map { "in \"\($0)\"" } ?? "across all lists"
            return ActionPlan(
                title: "Snooze Low-Priority Reminders",
                summary: "Push all low-priority reminders \(listSummary) forward by \(intervalDays) day(s).",
                actions: [
                    ActionItem(
                        type: .snoozeReminder,
                        riskLevel: .moderate,
                        description: "Snooze low-priority reminders by \(intervalDays) day(s)",
                        metadata: [
                            "action":       "snoozeLowPriority",
                            "intervalDays": "\(intervalDays)",
                            "listTitle":    listTitle ?? "",
                            "rawCommand":   rawCommand
                        ]
                    )
                ]
            )
        }
    }

    // MARK: - Metadata Builders

    private func buildNoteMetadata(vault: String, filename: String, content: String,
                                   subpath: String?, mode: String, tags: [String] = [],
                                   heading: String? = nil, rawCommand: String) -> [String: String] {
        var meta: [String: String] = [
            "vault":      vault,
            "filename":   filename,
            "content":    content,
            "mode":       mode,
            "rawCommand": rawCommand
        ]
        if let sp = subpath   { meta["subpath"] = sp }
        if !tags.isEmpty      { meta["tags"]    = tags.joined(separator: ",") }
        if let h = heading    { meta["heading"] = h }
        return meta
    }

    private func buildEventMetadata(title: String, startDate: Date, endDate: Date,
                                    calendarTitle: String?, location: String?,
                                    notes: String?, rawCommand: String) -> [String: String] {
        var meta: [String: String] = [
            "title":      title,
            "startDate":  ISO8601DateFormatter().string(from: startDate),
            "endDate":    ISO8601DateFormatter().string(from: endDate),
            "action":     "create",
            "rawCommand": rawCommand
        ]
        if let cal = calendarTitle { meta["calendarTitle"] = cal }
        if let loc = location      { meta["location"]      = loc }
        if let n   = notes         { meta["notes"]         = n   }
        return meta
    }

    private func buildReminderMetadata(title: String, dueDate: Date?, listTitle: String?,
                                       notes: String?, priority: Int, action: String,
                                       rawCommand: String) -> [String: String] {
        var meta: [String: String] = [
            "title":      title,
            "priority":   "\(priority)",
            "action":     action,
            "rawCommand": rawCommand
        ]
        if let dd   = dueDate   { meta["dueDate"]   = ISO8601DateFormatter().string(from: dd) }
        if let list = listTitle { meta["listTitle"]  = list }
        if let n    = notes     { meta["notes"]      = n    }
        return meta
    }
}
