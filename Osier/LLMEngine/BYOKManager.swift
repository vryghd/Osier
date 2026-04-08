//
//  BYOKManager.swift
//  Osier — LLM Engine
//
//  Security-first API key management via Keychain.
//  Provides SSE streaming REST wrappers for OpenAI and Anthropic.
//  Keys are NEVER stored in UserDefaults, plist, or source code.
//

import Foundation
import Security

// MARK: - Supported External Providers

enum ExternalProvider: String, CaseIterable {
    case openAI    = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    var keychainKey: String { "osier.byok.\(rawValue).apikey" }

    // Default models
    var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o"
        case .anthropic: return "claude-3-5-sonnet-20241022"
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Codable {
    let role: String       // "system" | "user" | "assistant"
    let content: String
}

// MARK: - BYOK Manager

final class BYOKManager {

    static let shared = BYOKManager()
    private init() {}

    private let service = "com.osier.byok"

    // MARK: - Keychain: Store

    /// Saves an API key securely in the Keychain.
    /// Overwrites any existing key for this provider.
    func saveKey(_ key: String, for provider: ExternalProvider) throws {
        guard !key.isEmpty else { throw BYOKError.emptyKey }
        guard let data = key.data(using: .utf8) else { throw BYOKError.encodingFailed }

        // Delete existing entry first to allow update
        deleteKey(for: provider)

        let query: [String: Any] = [
            kSecClass          as String: kSecClassGenericPassword,
            kSecAttrService    as String: service,
            kSecAttrAccount    as String: provider.keychainKey,
            kSecValueData      as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BYOKError.keychainError(status, "save")
        }
        print("[BYOKManager] ✅ Key saved for \(provider.displayName).")
    }

    // MARK: - Keychain: Retrieve

    /// Retrieves an API key from the Keychain. Returns nil if not stored.
    func retrieveKey(for provider: ExternalProvider) -> String? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainKey,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    // MARK: - Keychain: Delete

    @discardableResult
    func deleteKey(for provider: ExternalProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.keychainKey
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Key Presence

    func hasKey(for provider: ExternalProvider) -> Bool {
        retrieveKey(for: provider) != nil
    }

    func availableProviders() -> [ExternalProvider] {
        ExternalProvider.allCases.filter { hasKey(for: $0) }
    }

    // MARK: - OpenAI Streaming

    /// Streams a response from OpenAI using Server-Sent Events.
    func streamOpenAI(
        messages: [ChatMessage],
        model: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = retrieveKey(for: .openAI) else {
                        throw BYOKError.noKeyStored(.openAI)
                    }

                    let selectedModel = model ?? ExternalProvider.openAI.defaultModel
                    var request       = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body: [String: Any] = [
                        "model":    selectedModel,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "stream":   true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw BYOKError.httpError(http.statusCode, .openAI)
                    }

                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        guard payload != "[DONE]" else { break }

                        if let data   = payload.data(using: .utf8),
                           let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta  = choices.first?["delta"] as? [String: Any],
                           let token  = delta["content"] as? String {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Anthropic Streaming

    /// Streams a response from Anthropic (Claude) using Server-Sent Events.
    func streamAnthropic(
        messages: [ChatMessage],
        systemPrompt: String,
        model: String? = nil,
        maxTokens: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = retrieveKey(for: .anthropic) else {
                        throw BYOKError.noKeyStored(.anthropic)
                    }

                    let selectedModel = model ?? ExternalProvider.anthropic.defaultModel
                    var request       = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    request.httpMethod = "POST"
                    request.setValue(apiKey,                      forHTTPHeaderField: "x-api-key")
                    request.setValue("application/json",          forHTTPHeaderField: "Content-Type")
                    request.setValue("2023-06-01",                forHTTPHeaderField: "anthropic-version")

                    // Filter out system messages — Anthropic uses a dedicated system field
                    let userAssistantMessages = messages.filter { $0.role != "system" }

                    let body: [String: Any] = [
                        "model":      selectedModel,
                        "max_tokens": maxTokens,
                        "system":     systemPrompt,
                        "messages":   userAssistantMessages.map { ["role": $0.role, "content": $0.content] },
                        "stream":     true
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw BYOKError.httpError(http.statusCode, .anthropic)
                    }

                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)

                        if let data  = payload.data(using: .utf8),
                           let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let type  = json["type"] as? String, type == "content_block_delta",
                           let delta = json["delta"] as? [String: Any],
                           let token = delta["text"] as? String {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()

                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Unified Streaming Interface

    /// Streams from whichever provider the caller specifies.
    func stream(
        provider: ExternalProvider,
        messages: [ChatMessage],
        systemPrompt: String,
        model: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        switch provider {
        case .openAI:
            return streamOpenAI(messages: messages, model: model)
        case .anthropic:
            return streamAnthropic(messages: messages, systemPrompt: systemPrompt, model: model)
        }
    }

    /// Collects full streamed response into a single string.
    func generate(
        provider: ExternalProvider,
        messages: [ChatMessage],
        systemPrompt: String,
        model: String? = nil
    ) async throws -> String {
        var result = ""
        for try await token in stream(provider: provider, messages: messages,
                                      systemPrompt: systemPrompt, model: model) {
            result += token
        }
        return result
    }
}

// MARK: - BYOK Errors

enum BYOKError: LocalizedError {
    case emptyKey
    case encodingFailed
    case keychainError(OSStatus, String)
    case noKeyStored(ExternalProvider)
    case httpError(Int, ExternalProvider)

    var errorDescription: String? {
        switch self {
        case .emptyKey:                     return "API key cannot be empty."
        case .encodingFailed:               return "Failed to encode API key."
        case .keychainError(let s, let op): return "Keychain \(op) failed with status \(s)."
        case .noKeyStored(let p):           return "No API key stored for \(p.displayName)."
        case .httpError(let c, let p):      return "\(p.displayName) API returned HTTP \(c)."
        }
    }
}
