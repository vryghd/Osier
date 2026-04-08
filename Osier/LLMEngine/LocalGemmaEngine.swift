//
//  LocalGemmaEngine.swift
//  Osier — LLM Engine
//
//  Local on-device inference using CoreML.
//  Loads a Gemma .mlpackage bundled in the app and runs inference on the
//  Apple Neural Engine (ANE) or GPU — never leaves the device.
//
//  ─── MODEL SETUP ────────────────────────────────────────────────────────
//  1. Download Gemma weights from Hugging Face (e.g., google/gemma-2b-it)
//  2. Convert to CoreML:
//       pip install coremltools transformers
//       python -c "
//           import coremltools as ct
//           from transformers import AutoModelForCausalLM, AutoTokenizer
//           model = AutoModelForCausalLM.from_pretrained('google/gemma-2b-it')
//           # See coremltools docs for full pipeline
//       "
//  3. Drag the resulting .mlpackage into Xcode → Osier/Resources/
//  4. Set GEMMA_MODEL_NAME below to match the .mlpackage filename.
//
//  ─── MLX SWIFT ALTERNATIVE ──────────────────────────────────────────────
//  Apple's MLX Swift (github.com/ml-explore/mlx-swift) provides a higher-level
//  inference API. To use it:
//  1. Add via SPM: https://github.com/ml-explore/mlx-swift
//  2. Conform to LocalLanguageModel protocol below using MLXModel
//  3. Swap LocalGemmaEngine.activeModel to your MLX implementation.
//  ─────────────────────────────────────────────────────────────────────────

import Foundation
import CoreML
import NaturalLanguage

// MARK: - Configuration

private enum GemmaConfig {
    static let modelName          = "Gemma"        // .mlpackage filename (no extension)
    static let maxNewTokens       = 512
    static let defaultTemperature: Float = 0.7
    static let eosTokenID         = 1              // Gemma EOS token ID
    static let padTokenID         = 0
}

// MARK: - Tokenizer Protocol

/// Abstraction over the tokenizer so it can be swapped (SentencePiece, BPE, etc.)
protocol Tokenizer {
    func encode(_ text: String) -> [Int]
    func decode(_ tokenIDs: [Int]) -> String
    func decodeToken(_ tokenID: Int) -> String
}

// MARK: - Scaffold Tokenizer (replace with real SentencePiece implementation)

/// Placeholder tokenizer backed by NaturalLanguage word tokenization.
/// Replace this with a real SentencePiece tokenizer loaded from vocab.model
/// bundled alongside the CoreML model.
final class ScaffoldTokenizer: Tokenizer {

    // TODO: Load vocabulary from bundled vocab.json or tokenizer.json
    // For Gemma, use the SentencePiece model at:
    // github.com/google/gemma_pytorch → tokenizer/tokenizer.model

    func encode(_ text: String) -> [Int] {
        // Stub: returns character codepoints as token IDs
        // Replace with: SPTokenizer.encode(text) from a bundled tokenizer library
        Array(text.unicodeScalars.prefix(512).map { Int($0.value) })
    }

    func decode(_ tokenIDs: [Int]) -> String {
        // Stub: maps codepoints back to characters
        String(tokenIDs.compactMap { Unicode.Scalar($0) }.map { Character($0) })
    }

    func decodeToken(_ tokenID: Int) -> String {
        guard let scalar = Unicode.Scalar(tokenID) else { return "" }
        return String(Character(scalar))
    }
}

// MARK: - Language Model Protocol

protocol LocalLanguageModel {
    /// Run one forward pass. Returns the next predicted token ID.
    func nextToken(inputIDs: [Int], temperature: Float) throws -> Int
}

// MARK: - CoreML Language Model

/// Wraps a CoreML .mlpackage for autoregressive generation.
final class CoreMLLanguageModel: LocalLanguageModel {

    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    func nextToken(inputIDs: [Int], temperature: Float) throws -> Int {
        // Build input MLMultiArray — shape [1, sequence_length]
        let seqLen  = inputIDs.count
        let shape   = [1, seqLen] as [NSNumber]
        let inputArray = try MLMultiArray(shape: shape, dataType: .int32)

        for (i, id) in inputIDs.enumerated() {
            inputArray[[0, i] as [NSNumber]] = NSNumber(value: id)
        }

        let inputFeatures = try MLDictionaryFeatureProvider(
            dictionary: ["input_ids": inputArray]
        )

        let output    = try model.prediction(from: inputFeatures)

        // Extract logits — expected output feature name: "logits"
        // Shape: [1, seqLen, vocabSize]
        guard let logitArray = output.featureValue(named: "logits")?.multiArrayValue else {
            throw GemmaError.invalidModelOutput
        }

        // Read logits for the LAST token position
        let vocabSize  = logitArray.shape[2].intValue
        let lastOffset = (seqLen - 1) * vocabSize

        var logits = [Float](repeating: 0, count: vocabSize)
        for i in 0..<vocabSize {
            logits[i] = logitArray[[0, seqLen - 1, i] as [NSNumber]].floatValue
        }

        return sampleToken(from: logits, temperature: temperature)
    }

    // MARK: - Sampling

    /// Greedy (temperature=0) or temperature-scaled sampling.
    private func sampleToken(from logits: [Float], temperature: Float) -> Int {
        guard temperature > 0 else {
            // Greedy: return argmax
            return logits.indices.max(by: { logits[$0] < logits[$1] }) ?? 0
        }

        // Temperature scaling
        let scaled   = logits.map { $0 / temperature }
        let maxLogit = scaled.max() ?? 0
        let exps     = scaled.map { expf($0 - maxLogit) }
        let sumExps  = exps.reduce(0, +)
        let probs    = exps.map { $0 / sumExps }

        // Sample from distribution
        let r    = Float.random(in: 0..<1)
        var cumulative: Float = 0
        for (i, p) in probs.enumerated() {
            cumulative += p
            if r <= cumulative { return i }
        }
        return probs.indices.max(by: { probs[$0] < probs[$1] }) ?? 0
    }
}

// MARK: - LocalGemmaEngine

@MainActor
final class LocalGemmaEngine: ObservableObject {

    // MARK: - Singleton

    static let shared = LocalGemmaEngine()
    private init() {}

    // MARK: - State

    @Published var isModelLoaded: Bool = false
    @Published var isGenerating:  Bool = false

    private var model:     LocalLanguageModel?
    private var tokenizer: Tokenizer = ScaffoldTokenizer()

    // MARK: - Model Loading

    /// Call once at app launch. Loads the CoreML model on a background thread.
    func loadModel() async throws {
        guard !isModelLoaded else { return }

        guard let modelURL = Bundle.main.url(
            forResource: GemmaConfig.modelName,
            withExtension: "mlpackage"
        ) else {
            throw GemmaError.modelNotFound(GemmaConfig.modelName)
        }

        let config              = MLModelConfiguration()
        config.computeUnits     = .all   // ANE + GPU + CPU; falls back gracefully

        let mlModel = try await MLModel.load(contentsOf: modelURL, configuration: config)
        model       = CoreMLLanguageModel(model: mlModel)
        isModelLoaded = true

        print("[LocalGemmaEngine] ✅ Model loaded: \(GemmaConfig.modelName)")
    }

    /// Swap the underlying model implementation (e.g., for MLX Swift).
    func setModel(_ custom: LocalLanguageModel, tokenizer: Tokenizer) {
        self.model     = custom
        self.tokenizer = tokenizer
        isModelLoaded  = true
    }

    // MARK: - Streaming Inference

    /// Runs autoregressive generation and streams decoded tokens as they are produced.
    /// Returns an `AsyncStream<String>` so callers receive tokens in real time.
    func generate(
        prompt: String,
        maxNewTokens: Int         = GemmaConfig.maxNewTokens,
        temperature: Float        = GemmaConfig.defaultTemperature,
        stopSequences: [String]   = []
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                guard let model else {
                    continuation.finish()
                    return
                }

                await MainActor.run { isGenerating = true }

                var inputIDs = tokenizer.encode(prompt)
                var generated = ""

                for _ in 0..<maxNewTokens {
                    // Check cancellation
                    if Task.isCancelled { break }

                    do {
                        let nextID = try model.nextToken(
                            inputIDs:    inputIDs,
                            temperature: temperature
                        )

                        // EOS check
                        if nextID == GemmaConfig.eosTokenID { break }

                        let token = tokenizer.decodeToken(nextID)
                        generated += token
                        continuation.yield(token)

                        inputIDs.append(nextID)

                        // Stop sequence check
                        if stopSequences.contains(where: { generated.hasSuffix($0) }) { break }

                    } catch {
                        print("[LocalGemmaEngine] ❌ Inference error: \(error)")
                        break
                    }
                }

                await MainActor.run { isGenerating = false }
                continuation.finish()
            }
        }
    }

    /// Convenience: collects the full streamed output into a single string.
    func generateFull(
        prompt: String,
        maxNewTokens: Int       = GemmaConfig.maxNewTokens,
        temperature: Float      = GemmaConfig.defaultTemperature,
        stopSequences: [String] = []
    ) async -> String {
        var result = ""
        for await token in generate(prompt: prompt, maxNewTokens: maxNewTokens,
                                    temperature: temperature, stopSequences: stopSequences) {
            result += token
        }
        return result
    }

    // MARK: - Cancel

    func cancelGeneration() {
        isGenerating = false
    }
}

// MARK: - Errors

enum GemmaError: LocalizedError {
    case modelNotFound(String)
    case invalidModelOutput
    case tokenizerNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let n):   return "CoreML model \"\(n).mlpackage\" not found in app bundle."
        case .invalidModelOutput:     return "Model output did not contain expected 'logits' feature."
        case .tokenizerNotLoaded:     return "Tokenizer is not loaded."
        }
    }
}
