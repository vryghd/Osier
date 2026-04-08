//
//  LLMCoordinator.swift
//  Osier — LLM Engine
//
//  Unified pipeline coordinator. Single entry point for all agent commands.
//
//  Pipeline:
//  Raw user input
//    → ContextManager: inject session history
//    → Provider selection: LocalGemma or BYOK (OpenAI / Anthropic)
//    → Inference: AsyncStream<String> token output
//    → CommandParser: JSON → ActionPlan
//    → SafetyProtocolEngine: queue for user confirmation
//    → ContextManager: record result
//

import Foundation

// MARK: - LLM Provider Selection

enum LLMProvider: Equatable {
    case local                              // On-device Gemma via CoreML
    case external(ExternalProvider)         // BYOK (OpenAI, Anthropic)

    var displayName: String {
        switch self {
        case .local:             return "Gemma (Local)"
        case .external(let p):  return p.displayName
        }
    }

    /// The preferred provider falls back gracefully: external if key exists, else local.
    static func preferred() -> LLMProvider {
        if BYOKManager.shared.hasKey(for: .openAI)    { return .external(.openAI) }
        if BYOKManager.shared.hasKey(for: .anthropic)  { return .external(.anthropic) }
        return .local
    }
}

// MARK: - Processing State

enum ProcessingState: Equatable {
    case idle
    case inferring          // LLM generating tokens
    case parsing            // CommandParser working
    case awaitingConfirm    // ActionPlan queued, waiting for user
    case executing          // SafetyProtocolEngine executing
    case error(String)
}

// MARK: - LLMCoordinator

@MainActor
final class LLMCoordinator: ObservableObject {

    // MARK: - Singleton

    static let shared = LLMCoordinator()
    private init() {}

    // MARK: - Published State

    @Published var state: ProcessingState     = .idle
    @Published var activeProvider: LLMProvider = .local
    @Published var streamingBuffer: String     = ""   // Live token accumulator for UI
    @Published var lastError: String?          = nil
    @Published var lastClarification: String?  = nil  // When LLM needs more info

    // MARK: - Dependencies

    private let gemma   = LocalGemmaEngine.shared
    private let byok    = BYOKManager.shared
    private let parser  = CommandParser.shared
    private let context = ContextManager.shared
    private let safety  = SafetyProtocolEngine()

    private var streamTask: Task<Void, Never>?

    // MARK: - Provider Management

    /// Switches the active provider. Respects BYOK availability.
    func setProvider(_ provider: LLMProvider) {
        switch provider {
        case .local:
            activeProvider = .local
        case .external(let p):
            guard byok.hasKey(for: p) else {
                lastError = "No key stored for \(p.displayName). Add one via BYOKManager."
                return
            }
            activeProvider = .external(p)
        }
        print("[LLMCoordinator] 🔄 Provider: \(provider.displayName)")
    }

    /// Forces local-only mode (e.g., when user is offline or prefers privacy).
    func forceLocal() { activeProvider = .local }

    // MARK: - Main Entry Point

    /// Processes a raw text command end-to-end:
    /// context inject → infer → parse → queue ActionPlan.
    /// Returns the `ActionPlan` if parsing succeeded, nil if clarification needed.
    @discardableResult
    func process(input: String) async -> ActionPlan? {
        guard state == .idle else {
            print("[LLMCoordinator] ⚠️ Already processing. Ignoring input.")
            return nil
        }

        lastError         = nil
        lastClarification = nil
        streamingBuffer   = ""
        state             = .inferring

        // Build full prompt with injected context
        let systemPrompt = CommandParser.buildSystemPrompt()
        let contextBlock = context.buildContextBlock()
        let fullPrompt   = contextBlock.isEmpty
            ? input
            : "\(contextBlock)\n\nUSER: \(input)"

        // Run inference
        let llmOutput: String
        do {
            llmOutput = try await runInference(userInput: fullPrompt, systemPrompt: systemPrompt)
        } catch {
            state     = .error(error.localizedDescription)
            lastError = error.localizedDescription
            return nil
        }

        // Parse LLM output → ActionPlan
        state = .parsing
        let result: ParseResult
        do {
            result = try parser.parse(llmOutput: llmOutput, rawUserInput: input)
        } catch {
            state     = .error(error.localizedDescription)
            lastError = error.localizedDescription
            return nil
        }

        switch result {
        case .plan(let plan):
            // Queue for user confirmation via SafetyProtocolEngine
            state = .awaitingConfirm
            safety.queuePlan(plan)

            // Record to context
            context.record(
                userInput:   input,
                llmResponse: llmOutput,
                module:      plan.actions.first?.type.rawValue ?? nil,
                intent:      plan.title
            )
            return plan

        case .clarificationNeeded(let question):
            state             = .idle
            lastClarification = question
            context.record(userInput: input, llmResponse: llmOutput)
            return nil

        case .parseError(let reason):
            state     = .error(reason)
            lastError = reason
            context.record(userInput: input, llmResponse: llmOutput)
            return nil
        }
    }

    // MARK: - Streaming Token Feed

    /// Returns a live `AsyncStream<String>` of tokens while inference runs.
    /// Subscribe from the CommandBar view to display tokens as they arrive.
    func liveStream(for input: String) -> AsyncStream<String> {
        let systemPrompt = CommandParser.buildSystemPrompt()
        let contextBlock = context.buildContextBlock()
        let fullPrompt   = contextBlock.isEmpty ? input : "\(contextBlock)\n\nUSER: \(input)"

        switch activeProvider {
        case .local:
            return gemma.generate(
                prompt:        buildLocalPrompt(system: systemPrompt, user: fullPrompt),
                stopSequences: ["USER:", "<context>"]
            )

        case .external(let provider):
            // Wrap AsyncThrowingStream → AsyncStream (swallow errors, print locally)
            let messages = buildChatMessages(system: systemPrompt, user: fullPrompt)
            let throwing = byok.stream(provider: provider, messages: messages,
                                        systemPrompt: systemPrompt)
            return AsyncStream { continuation in
                Task {
                    do {
                        for try await token in throwing { continuation.yield(token) }
                    } catch {
                        print("[LLMCoordinator] ❌ Stream error: \(error)")
                    }
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Cancel

    func cancel() {
        streamTask?.cancel()
        gemma.cancelGeneration()
        state = .idle
        print("[LLMCoordinator] ⛔ Processing cancelled.")
    }

    // MARK: - Private: Inference Runner

    private func runInference(userInput: String, systemPrompt: String) async throws -> String {
        switch activeProvider {

        case .local:
            guard gemma.isModelLoaded else {
                // Attempt load on first use
                try await gemma.loadModel()
            }
            let prompt = buildLocalPrompt(system: systemPrompt, user: userInput)
            var output = ""
            for await token in gemma.generate(prompt: prompt, stopSequences: ["USER:", "<context>"]) {
                output         += token
                streamingBuffer = output
            }
            return output

        case .external(let provider):
            let messages = buildChatMessages(system: systemPrompt, user: userInput)
            var output   = ""
            for try await token in byok.stream(provider: provider, messages: messages,
                                               systemPrompt: systemPrompt) {
                output         += token
                streamingBuffer = output
            }
            return output
        }
    }

    // MARK: - Private: Prompt Builders

    /// Formats a Gemma-style instruction prompt.
    private func buildLocalPrompt(system: String, user: String) -> String {
        "<start_of_turn>system\n\(system)<end_of_turn>\n<start_of_turn>user\n\(user)<end_of_turn>\n<start_of_turn>model\n"
    }

    /// Converts system + user input into ChatMessage array for BYOK providers.
    private func buildChatMessages(system: String, user: String) -> [ChatMessage] {
        var messages = context.asChatMessages()
        messages.insert(ChatMessage(role: "system",    content: system), at: 0)
        messages.append(ChatMessage(role: "user",      content: user))
        return messages
    }

    // MARK: - Execution Feedback (called by SafetyProtocolEngine after user confirms)

    /// Called after SafetyProtocolEngine finishes executing a plan.
    /// Updates state and records the execution result in context.
    func recordExecutionResult(_ result: ExecutionResult, for plan: ActionPlan) {
        let summary: String = {
            switch result {
            case .success(let msg):         return msg
            case .partialSuccess(let done, let failed):
                return "\(done.count) succeeded, \(failed.count) failed."
            case .failure(let err, _):      return "Failed: \(err.localizedDescription)"
            case .cancelledByUser:          return "Cancelled by user."
            }
        }()

        if let last = context.entries.last {
            context.record(
                userInput:        last.userInput,
                llmResponse:      last.llmResponse,
                module:           last.resolvedModule,
                intent:           last.resolvedIntent,
                executionSummary: summary
            )
        }
        state = .idle
    }
}
