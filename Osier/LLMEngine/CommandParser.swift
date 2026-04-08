//
//  CommandParser.swift
//  Osier — LLM Engine
//
//  Central routing layer between raw LLM output and Module D's ActionPlan system.
//  The LLM is instructed (via system prompt) to output JSON in this schema:
//
//  {
//    "module":     "file" | "vault" | "gallery",
//    "intent":     <intent name string>,
//    "parameters": { <key: value pairs> }
//  }
//
//  CommandParser extracts that JSON, decodes it into a ParsedCommand,
//  then routes to FileActionBuilder, VaultActionBuilder, or GalleryActionBuilder
//  to produce a fully typed ActionPlan for SafetyProtocolEngine.
//

import Foundation

// MARK: - Parsed Command

struct ParsedCommand: Decodable {
    let module:     String
    let intent:     String
    let parameters: [String: AnyCodable]
}

/// Type-erased Codable wrapper for heterogeneous JSON parameter values.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self)   { value = v; return }
        if let v = try? container.decode(Double.self)   { value = v; return }
        if let v = try? container.decode(Bool.self)     { value = v; return }
        if let v = try? container.decode(Int.self)      { value = v; return }
        if let v = try? container.decode([String].self) { value = v; return }
        value = ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as String: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as Bool:   try c.encode(v)
        case let v as Int:    try c.encode(v)
        default: try c.encode("")
        }
    }

    var string:   String?   { value as? String }
    var double:   Double?   { value as? Double }
    var int:      Int?      { value as? Int ?? (value as? Double).map { Int($0) } }
    var bool:     Bool?     { value as? Bool }
    var strings:  [String]? { value as? [String] }
}

// MARK: - Parse Result

enum ParseResult {
    case plan(ActionPlan)
    case clarificationNeeded(String)   // LLM output was valid NL but no intent matched
    case parseError(String)            // Could not extract JSON
}

// MARK: - CommandParser

final class CommandParser {

    static let shared = CommandParser()
    private init() {}

    // MARK: - Entry Point

    /// Extracts JSON from raw LLM output and routes to the correct ActionBuilder.
    func parse(llmOutput: String, rawUserInput: String = "") throws -> ParseResult {
        guard let json = extractJSON(from: llmOutput) else {
            // Fallback: try keyword-based routing for robustness
            return keywordFallback(for: rawUserInput)
        }

        guard let data = json.data(using: .utf8) else {
            return .parseError("Failed to encode extracted JSON.")
        }

        do {
            let command = try JSONDecoder().decode(ParsedCommand.self, from: data)
            return try route(command: command, rawCommand: rawUserInput)
        } catch {
            return .parseError("JSON decode failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Router

    private func route(command: ParsedCommand, rawCommand: String) throws -> ParseResult {
        let p = command.parameters

        switch command.module.lowercased() {

        // ─── FILE MODULE ───────────────────────────────────────────────────

        case "file":
            let intent = try routeFileIntent(intent: command.intent, params: p, rawCommand: rawCommand)
            return .plan(intent)

        // ─── VAULT MODULE ──────────────────────────────────────────────────

        case "vault":
            let intent = try routeVaultIntent(intent: command.intent, params: p, rawCommand: rawCommand)
            return .plan(intent)

        // ─── GALLERY MODULE ────────────────────────────────────────────────

        case "gallery":
            let intent = try routeGalleryIntent(intent: command.intent, params: p, rawCommand: rawCommand)
            return .plan(intent)

        default:
            return .clarificationNeeded("Unknown module: \(command.module)")
        }
    }

    // MARK: - File Intent Routing

    private func routeFileIntent(intent: String, params: [String: AnyCodable],
                                  rawCommand: String) throws -> ActionPlan {
        let builder = FileActionBuilder.shared

        switch intent {
        case "moveFiles":
            let srcs  = (params["sources"]?.strings ?? []).map { URL(fileURLWithPath: $0) }
            let dst   = URL(fileURLWithPath: params["destination"]?.string ?? "")
            return try builder.buildPlan(from: AgentIntent(kind: .moveFiles(sources: srcs, destination: dst), rawCommand: rawCommand))

        case "copyFiles":
            let srcs  = (params["sources"]?.strings ?? []).map { URL(fileURLWithPath: $0) }
            let dst   = URL(fileURLWithPath: params["destination"]?.string ?? "")
            return try builder.buildPlan(from: AgentIntent(kind: .copyFiles(sources: srcs, destination: dst), rawCommand: rawCommand))

        case "deleteFiles":
            let targets = (params["targets"]?.strings ?? []).map { URL(fileURLWithPath: $0) }
            return try builder.buildPlan(from: AgentIntent(kind: .deleteFiles(targets: targets), rawCommand: rawCommand))

        case "sortFolder":
            let src      = URL(fileURLWithPath: params["source"]?.string ?? "")
            let strategy = SortStrategy(rawValue: params["strategy"]?.string ?? "") ?? .byType
            return try builder.buildPlan(from: AgentIntent(kind: .sortFolder(source: src, strategy: strategy), rawCommand: rawCommand))

        case "clearDownloads":
            return try builder.buildPlan(from: AgentIntent(kind: .clearDownloads, rawCommand: rawCommand))

        case "backupVault":
            let src = URL(fileURLWithPath: params["source"]?.string ?? "")
            let dst = URL(fileURLWithPath: params["destination"]?.string ?? "")
            return try builder.buildPlan(from: AgentIntent(kind: .backupVault(source: src, destination: dst), rawCommand: rawCommand))

        case "exportToPDF":
            let src  = URL(fileURLWithPath: params["source"]?.string ?? "")
            let name = params["outputName"]?.string ?? "Document"
            return try builder.buildPlan(from: AgentIntent(kind: .exportToPDF(sourceURL: src, outputName: name), rawCommand: rawCommand))

        case "deduplicateFolder":
            let src = URL(fileURLWithPath: params["source"]?.string ?? "")
            return try builder.buildPlan(from: AgentIntent(kind: .deduplicateFolder(source: src), rawCommand: rawCommand))

        default:
            throw ParserError.unknownIntent(module: "file", intent: intent)
        }
    }

    // MARK: - Vault Intent Routing

    private func routeVaultIntent(intent: String, params: [String: AnyCodable],
                                   rawCommand: String) throws -> ActionPlan {
        let builder = VaultActionBuilder.shared
        let dateParser = ISO8601DateFormatter()

        switch intent {
        case "createNote":
            return try builder.buildPlan(from: .createNote(
                vaultName:   params["vault"]?.string ?? "",
                filename:    params["filename"]?.string ?? "Untitled",
                content:     params["content"]?.string ?? "",
                subpath:     params["subpath"]?.string,
                tags:        params["tags"]?.strings ?? []
            ), rawCommand: rawCommand)

        case "appendToNote":
            return try builder.buildPlan(from: .appendToNote(
                vaultName: params["vault"]?.string ?? "",
                filename:  params["filename"]?.string ?? "",
                content:   params["content"]?.string ?? "",
                subpath:   params["subpath"]?.string
            ), rawCommand: rawCommand)

        case "writeDailyNote":
            return try builder.buildPlan(from: .writeDailyNote(
                vaultName: params["vault"]?.string ?? "",
                content:   params["content"]?.string ?? ""
            ), rawCommand: rawCommand)

        case "createAppleNote":
            return try builder.buildPlan(from: .createAppleNote(
                title: params["title"]?.string ?? "New Note",
                body:  params["body"]?.string ?? "",
                tags:  params["tags"]?.strings ?? []
            ), rawCommand: rawCommand)

        case "appendToAppleNote":
            return try builder.buildPlan(from: .appendToAppleNote(
                noteTitle: params["title"]?.string ?? "",
                content:   params["content"]?.string ?? ""
            ), rawCommand: rawCommand)

        case "createCalendarEvent":
            let start = dateParser.date(from: params["startDate"]?.string ?? "") ?? Date()
            let end   = dateParser.date(from: params["endDate"]?.string ?? "") ?? Date().addingTimeInterval(3600)
            return try builder.buildPlan(from: .createCalendarEvent(
                title:         params["title"]?.string ?? "New Event",
                startDate:     start,
                endDate:       end,
                calendarTitle: params["calendar"]?.string,
                location:      params["location"]?.string,
                notes:         params["notes"]?.string
            ), rawCommand: rawCommand)

        case "createReminder":
            let due = params["dueDate"].flatMap { dateParser.date(from: $0.string ?? "") }
            return try builder.buildPlan(from: .createReminder(
                title:     params["title"]?.string ?? "New Reminder",
                dueDate:   due,
                listTitle: params["list"]?.string,
                notes:     params["notes"]?.string,
                priority:  params["priority"]?.int ?? 0
            ), rawCommand: rawCommand)

        case "snoozeLowPriorityReminders":
            return try builder.buildPlan(from: .snoozeLowPriorityReminders(
                listTitle:    params["list"]?.string,
                intervalDays: params["days"]?.int ?? 1
            ), rawCommand: rawCommand)

        default:
            throw ParserError.unknownIntent(module: "vault", intent: intent)
        }
    }

    // MARK: - Gallery Intent Routing

    private func routeGalleryIntent(intent: String, params: [String: AnyCodable],
                                     rawCommand: String) throws -> ActionPlan {
        let builder = GalleryActionBuilder.shared

        switch intent {
        case "createAlbum":
            return try builder.buildPlan(from: .createAlbum(
                name: params["name"]?.string ?? "New Album"
            ), rawCommand: rawCommand)

        case "addAssetsToAlbum":
            return try builder.buildPlan(from: .addAssetsToAlbum(
                assetIDs:  params["assetIDs"]?.strings ?? [],
                albumName: params["album"]?.string ?? "New Album"
            ), rawCommand: rawCommand)

        case "trashAssets":
            return try builder.buildPlan(from: .trashAssets(
                assetIDs: params["assetIDs"]?.strings ?? []
            ), rawCommand: rawCommand)

        case "trashAssetsNearCoordinate":
            let lat    = params["latitude"]?.double  ?? 0
            let lng    = params["longitude"]?.double ?? 0
            let radius = params["radiusMeters"]?.double ?? 500
            return try builder.buildPlan(from: .trashAssetsNearCoordinate(
                latitude: lat, longitude: lng,
                radiusMeters: radius, dateRange: nil
            ), rawCommand: rawCommand)

        case "sortAssetsIntoAlbum":
            return try builder.buildPlan(from: .sortAssetsIntoAlbum(
                assetIDs:    params["assetIDs"]?.strings ?? [],
                targetAlbum: params["album"]?.string ?? "Sorted",
                visionLabel: params["visionLabel"]?.string
            ), rawCommand: rawCommand)

        case "groupByDate":
            return try builder.buildPlan(from: .groupByDate(
                assetIDs: params["assetIDs"]?.strings ?? [],
                strategy: params["strategy"]?.string ?? "month"
            ), rawCommand: rawCommand)

        case "groupByLocation":
            return try builder.buildPlan(from: .groupByLocation(
                assetIDs: params["assetIDs"]?.strings ?? []
            ), rawCommand: rawCommand)

        default:
            throw ParserError.unknownIntent(module: "gallery", intent: intent)
        }
    }

    // MARK: - JSON Extraction

    /// Pulls the JSON object from LLM output, ignoring surrounding markdown/prose.
    private func extractJSON(from text: String) -> String? {
        // Try to find a code block first:  ```json { ... } ```
        if let codeMatch = text.range(of: #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#,
                                       options: .regularExpression) {
            let block = String(text[codeMatch])
            if let jsonStart = block.firstIndex(of: "{"),
               let jsonEnd   = block.lastIndex(of: "}") {
                return String(block[jsonStart...jsonEnd])
            }
        }
        // Fallback: find first { ... } in the text
        if let start = text.firstIndex(of: "{"),
           let end   = text.lastIndex(of: "}") {
            let candidate = String(text[start...end])
            // Validate it's parseable JSON
            if let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Keyword Fallback

    /// Simple keyword matching when the LLM did not produce JSON.
    private func keywordFallback(for input: String) -> ParseResult {
        let lower = input.lowercased()

        if lower.contains("move") && (lower.contains("file") || lower.contains("folder")) {
            return .clarificationNeeded("Which files should I move, and where?")
        }
        if lower.contains("daily note") || lower.contains("log") {
            return .clarificationNeeded("Which vault should I write the daily note to?")
        }
        if lower.contains("remind") || lower.contains("reminder") {
            return .clarificationNeeded("What should the reminder say, and when is it due?")
        }
        if lower.contains("album") || lower.contains("photo") {
            return .clarificationNeeded("Which photos, and which album?")
        }
        if lower.contains("calendar") || lower.contains("event") || lower.contains("schedule") {
            return .clarificationNeeded("What event should I create, and when?")
        }

        return .clarificationNeeded("I didn't understand that command. Could you rephrase?")
    }
}

// MARK: - System Prompt Builder

extension CommandParser {

    /// The system prompt injected before every inference call.
    /// Instructs the LLM to respond ONLY with a structured JSON command.
    static func buildSystemPrompt() -> String {
        """
        You are Osier, a powerful local iOS system agent. \
        You help users manage files, vaults, calendars, photos, and notes directly on-device.

        STRICT OUTPUT FORMAT:
        Respond ONLY with a single JSON object. No prose, no markdown, no explanation.
        Schema:
        {
          "module": "file" | "vault" | "gallery",
          "intent": <intent_name>,
          "parameters": { <key: value> }
        }

        FILE INTENTS: moveFiles(sources,destination) | copyFiles(sources,destination) | \
        deleteFiles(targets) | sortFolder(source,strategy) | clearDownloads | \
        backupVault(source,destination) | exportToPDF(source,outputName) | deduplicateFolder(source)

        VAULT INTENTS: createNote(vault,filename,content,subpath?,tags?) | \
        appendToNote(vault,filename,content,subpath?) | writeDailyNote(vault,content) | \
        createAppleNote(title,body,tags?) | appendToAppleNote(title,content) | \
        createCalendarEvent(title,startDate,endDate,calendar?,location?,notes?) | \
        createReminder(title,dueDate?,list?,notes?,priority?) | \
        snoozeLowPriorityReminders(list?,days?)

        GALLERY INTENTS: createAlbum(name) | addAssetsToAlbum(assetIDs,album) | \
        trashAssets(assetIDs) | trashAssetsNearCoordinate(latitude,longitude,radiusMeters) | \
        sortAssetsIntoAlbum(assetIDs,album,visionLabel?) | groupByDate(assetIDs,strategy) | \
        groupByLocation(assetIDs)

        Use ISO8601 format for all dates. Paths must be absolute file system paths.
        If the user's intent is ambiguous, respond with:
        { "module": "clarify", "intent": "ask", "parameters": { "question": "<your question>" } }
        """
    }
}

// MARK: - Parser Errors

enum ParserError: LocalizedError {
    case unknownIntent(module: String, intent: String)
    case missingParameter(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .unknownIntent(let m, let i): return "Unknown intent '\(i)' in module '\(m)'."
        case .missingParameter(let p):     return "Required parameter '\(p)' is missing."
        case .invalidJSON:                 return "LLM output did not contain valid JSON."
        }
    }
}
