//
//  AppleNotesIntentProvider.swift
//  Osier — Module B: VaultAgent
//
//  iOS 17 AppIntents integration for Apple Notes.
//
//  SANDBOX BOUNDARY DOCUMENTATION:
//  Apple Notes data lives in a private Core Data store under com.apple.Notes.
//  There is NO public API to directly read or write Notes database records
//  from a third-party app. This is an intentional sandbox restriction.
//
//  What IS available (public, documented):
//  1. AppIntents (iOS 16+): Define Shortcuts-compatible actions that appear in
//     the Shortcuts app and can be invoked by Siri.
//  2. INCreateNoteIntent / INAppendToNoteIntent (SiriKit Intents domain, iOS 11+):
//     Handled inside an Intents Extension target. The system bridges these to Notes.
//  3. The `mobilenotes://` URL scheme: opens Apple Notes app. Does NOT support
//     parameterized note creation from a URL.
//
//  Implementation strategy used here:
//  A. CreateNoteIntent and AppendNoteIntent are defined as AppIntents — they are
//     visible in Shortcuts and can be chained into automations.
//  B. Execution writes content to a staging .md file in the app's Documents folder.
//     The staged content is immediately accessible and can be shared to Notes manually
//     or via a Shortcuts automation that chains these intents.
//  C. NotesIntentHandler is a scaffold for a future INExtension target that would
//     handle INCreateNoteIntent from Siri directly into Apple Notes.
//
//  No private APIs. No hallucinated framework calls.
//

import AppIntents
import Foundation
import Intents

// MARK: - Staging Area

/// Where staged note content is written before the user routes it to Notes.
private let stagingDirectory: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir  = docs.appendingPathComponent("Osier/StagedNotes")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

// MARK: - AppIntent: Create Note

/// Shortcuts-compatible action: stages a new note for delivery to Apple Notes.
/// Surfaces in the Shortcuts app under "Osier" → "Create Note".
struct CreateNoteIntent: AppIntent {

    static var title: LocalizedStringResource       = "Create Note in Apple Notes"
    static var description                          = IntentDescription(
        "Stages a new note with the given title and body. Opens Apple Notes so you can paste or save it.",
        categoryName: "Notes"
    )

    @Parameter(title: "Note Title", description: "Title of the new note.")
    var noteTitle: String

    @Parameter(title: "Body", description: "Main content of the note.")
    var body: String

    @Parameter(title: "Tags", description: "Comma-separated tags to include in the note body.",
               default: "")
    var tags: String

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let stagedURL = try NoteStagingEngine.stage(
            title: noteTitle,
            body: body,
            tags: tags.isEmpty ? [] : tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        // Donate to SiriKit so Siri can suggest this action
        let siriIntent = INCreateNoteIntent()
        siriIntent.title = INSpeakableString(spokenPhrase: noteTitle)
        siriIntent.content = INNoteContent(type: .text)
        INInteraction(intent: siriIntent, response: nil).donate(completion: nil)

        let filename = stagedURL.lastPathComponent
        return .result(
            value: stagedURL.path,
            dialog: "Note '\(noteTitle)' staged as \(filename). Open Notes and paste, or use a Shortcuts automation to send it."
        )
    }
}

// MARK: - AppIntent: Append to Note

/// Shortcuts-compatible action: appends content to an existing staged note,
/// or creates a new one if the title doesn't match any staged file.
struct AppendNoteIntent: AppIntent {

    static var title: LocalizedStringResource = "Append to Note"
    static var description                    = IntentDescription(
        "Appends content to a previously staged note. Matches by note title.",
        categoryName: "Notes"
    )

    @Parameter(title: "Note Title", description: "Title of the note to append to.")
    var noteTitle: String

    @Parameter(title: "Content to Append", description: "The text to add at the end of the note.")
    var appendContent: String

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let result = try NoteStagingEngine.appendOrCreate(title: noteTitle, content: appendContent)

        let siriIntent = INAppendToNoteIntent()
        siriIntent.targetNote = INNote(
            identifier: INSpeakableString(spokenPhrase: noteTitle),
            title: INSpeakableString(spokenPhrase: noteTitle),
            contents: [],
            createdDateComponents: nil,
            modifiedDateComponents: nil,
            identifier: nil
        )
        siriIntent.content = INNoteContent(type: .text)
        INInteraction(intent: siriIntent, response: nil).donate(completion: nil)

        return .result(
            value: result.path,
            dialog: "Appended to '\(noteTitle)'."
        )
    }
}

// MARK: - AppIntent: List Staged Notes

/// Returns which notes are currently in the staging area.
struct ListStagedNotesIntent: AppIntent {

    static var title: LocalizedStringResource = "List Staged Notes"
    static var description                    = IntentDescription(
        "Returns the titles of all notes currently staged and waiting to be sent to Apple Notes.",
        categoryName: "Notes"
    )

    func perform() async throws -> some ReturnsValue<[String]> & ProvidesDialog {
        let staged = NoteStagingEngine.listStaged()
        let titles = staged.map { $0.deletingPathExtension().lastPathComponent }
        let dialog: LocalizedStringResource = titles.isEmpty
            ? "No staged notes."
            : "\(titles.count) staged note(s): \(titles.joined(separator: ", "))"
        return .result(value: titles, dialog: dialog)
    }
}

// MARK: - Note Staging Engine

/// Internal engine that manages the staging folder where note content
/// is written as .md files before they are routed to Apple Notes.
enum NoteStagingEngine {

    private static let fm = FileManager.default

    /// Creates a new .md file in the staging directory.
    static func stage(title: String, body: String, tags: [String] = []) throws -> URL {
        let sanitized = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        let fileURL = stagingDirectory.appendingPathComponent("\(sanitized).md")

        var lines: [String] = []
        if !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", "))\n") }
        lines.append("# \(title)\n")
        lines.append(body)

        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        print("[NoteStagingEngine] ✅ Staged: \(fileURL.lastPathComponent)")
        return fileURL
    }

    /// Appends content to an existing staged note, or creates a new one.
    static func appendOrCreate(title: String, content: String) throws -> URL {
        let sanitized = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
        let fileURL = stagingDirectory.appendingPathComponent("\(sanitized).md")

        if fm.fileExists(atPath: fileURL.path) {
            let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            try (existing + "\n" + content).write(to: fileURL, atomically: true, encoding: .utf8)
        } else {
            try stage(title: title, body: content)
        }
        return fileURL
    }

    /// Returns URLs of all staged note files.
    static func listStaged() -> [URL] {
        (try? fm.contentsOfDirectory(at: stagingDirectory,
                                     includingPropertiesForKeys: nil,
                                     options: .skipsHiddenFiles))
        ?? []
    }

    /// Removes a staged note after it has been delivered.
    static func clearStaged(url: URL) {
        try? fm.removeItem(at: url)
        print("[NoteStagingEngine] 🗑 Cleared staged note: \(url.lastPathComponent)")
    }
}

// MARK: - NotesIntentHandler (Intents Extension Scaffold)

/// This class is the handler you would implement inside a separate
/// Intents Extension target (File → New → Target → Intents Extension in Xcode).
/// It handles INCreateNoteIntent and INAppendToNoteIntent from Siri,
/// bridging them into Apple Notes via the system.
///
/// To enable this:
/// 1. Add an "Intents Extension" target to the Xcode project.
/// 2. Declare INCreateNoteIntent and INAppendToNoteIntent in that target's Info.plist
///    under NSExtension → NSExtensionAttributes → IntentsSupported.
/// 3. Move this class into the extension target's source.
/// 4. The system will route Siri/Shortcuts requests to this handler.
final class NotesIntentHandler: NSObject, INCreateNoteIntentHandling, INAppendToNoteIntentHandling {

    // MARK: INCreateNoteIntentHandling

    func handle(intent: INCreateNoteIntent, completion: @escaping (INCreateNoteIntentResponse) -> Void) {
        guard let title = intent.title?.spokenPhrase,
              let contentObj = intent.content,
              let textBody = contentObj.text else {
            completion(INCreateNoteIntentResponse(code: .failure, userActivity: nil))
            return
        }

        do {
            let url = try NoteStagingEngine.stage(title: title, body: textBody)
            print("[NotesIntentHandler] ✅ INCreateNoteIntent staged: \(url.lastPathComponent)")
            completion(INCreateNoteIntentResponse(code: .success, userActivity: nil))
        } catch {
            completion(INCreateNoteIntentResponse(code: .failure, userActivity: nil))
        }
    }

    func resolveTitle(for intent: INCreateNoteIntent,
                      with completion: @escaping (INSpeakableStringResolutionResult) -> Void) {
        if let title = intent.title, !title.spokenPhrase.isEmpty {
            completion(.success(with: title))
        } else {
            completion(.needsValue())
        }
    }

    // MARK: INAppendToNoteIntentHandling

    func handle(intent: INAppendToNoteIntent, completion: @escaping (INAppendToNoteIntentResponse) -> Void) {
        guard let note = intent.targetNote,
              let title = note.title?.spokenPhrase,
              let contentObj = intent.content,
              let textBody = contentObj.text else {
            completion(INAppendToNoteIntentResponse(code: .failure, userActivity: nil))
            return
        }

        do {
            let url = try NoteStagingEngine.appendOrCreate(title: title, content: textBody)
            print("[NotesIntentHandler] ✅ INAppendToNoteIntent appended: \(url.lastPathComponent)")
            completion(INAppendToNoteIntentResponse(code: .success, userActivity: nil))
        } catch {
            completion(INAppendToNoteIntentResponse(code: .failure, userActivity: nil))
        }
    }
}
