//
//  ContextManager.swift
//  Osier — LLM Engine
//
//  In-memory session state for multi-step agent conversations.
//  Stores the last N turns (user input + LLM response + result).
//  Provides a formatted context string to inject into each new prompt.
//  No persistent storage — context is cleared on app restart.
//

import Foundation

// MARK: - Context Entry

struct ContextEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let userInput: String
    let llmResponse: String
    let resolvedModule: String?   // "file" | "vault" | "gallery" | nil
    let resolvedIntent: String?   // e.g. "moveFiles", "createNote"
    let executionSummary: String? // Human-readable result after SafetyProtocol execution

    init(userInput: String, llmResponse: String,
         resolvedModule: String? = nil, resolvedIntent: String? = nil,
         executionSummary: String? = nil) {
        self.id               = UUID()
        self.timestamp        = Date()
        self.userInput        = userInput
        self.llmResponse      = llmResponse
        self.resolvedModule   = resolvedModule
        self.resolvedIntent   = resolvedIntent
        self.executionSummary = executionSummary
    }
}

// MARK: - ContextManager

final class ContextManager {

    // MARK: - Singleton

    static let shared = ContextManager()
    private init() {}

    // MARK: - Configuration

    /// Maximum number of turns retained in memory.
    var maxEntries: Int = 10

    // MARK: - State (in-memory only, never persisted)

    private(set) var entries: [ContextEntry] = []

    // MARK: - Append

    func append(_ entry: ContextEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Convenience: create and append a minimal entry immediately after LLM responds.
    func record(userInput: String, llmResponse: String,
                module: String? = nil, intent: String? = nil,
                executionSummary: String? = nil) {
        let entry = ContextEntry(
            userInput: userInput,
            llmResponse: llmResponse,
            resolvedModule: module,
            resolvedIntent: intent,
            executionSummary: executionSummary
        )
        append(entry)
    }

    // MARK: - Context Prompt Builder

    /// Builds a compact context block to prepend to each new LLM prompt.
    /// Format keeps token count low while preserving task continuity.
    func buildContextBlock() -> String {
        guard !entries.isEmpty else { return "" }

        var lines: [String] = ["<context>"]
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .none

        for entry in entries {
            lines.append("[\(fmt.string(from: entry.timestamp))] USER: \(entry.userInput)")
            if let intent = entry.resolvedIntent, let module = entry.resolvedModule {
                lines.append("  → \(module).\(intent)")
            }
            if let summary = entry.executionSummary {
                lines.append("  RESULT: \(summary)")
            }
        }
        lines.append("</context>")
        return lines.joined(separator: "\n")
    }

    /// Returns the last user input, if any. Useful for "continue" / "do it again" resolution.
    var lastUserInput: String? { entries.last?.userInput }

    /// Returns the last resolved intent, if any.
    var lastIntent: String? { entries.last?.resolvedIntent }

    /// Returns the last resolved module, if any.
    var lastModule: String? { entries.last?.resolvedModule }

    // MARK: - History as ChatMessages (for BYOK providers)

    /// Formats context as OpenAI/Anthropic-compatible ChatMessage array.
    func asChatMessages() -> [ChatMessage] {
        entries.flatMap { entry -> [ChatMessage] in
            var messages: [ChatMessage] = [
                ChatMessage(role: "user", content: entry.userInput)
            ]
            if !entry.llmResponse.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: entry.llmResponse))
            }
            return messages
        }
    }

    // MARK: - Clear

    func clear() {
        entries.removeAll()
        print("[ContextManager] 🧹 Session context cleared.")
    }
}
