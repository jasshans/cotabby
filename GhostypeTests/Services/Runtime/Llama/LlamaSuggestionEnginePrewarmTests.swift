import Foundation
import XCTest
@testable import Ghostype

/// Tests for the llama half of prewarm-on-focus: a focus change used to leave the llama engine's
/// `prewarm` as the protocol no-op while the focus reset destroyed the native sequence, so the
/// first suggestion in every field paid the full cold prompt decode. These pin the new contract:
/// prewarm prefills through the runtime. Whether that prefill can be reused is the native core's
/// call (it compares against what it actually decoded), so the engine always offers the whole prompt.
@MainActor
final class LlamaSuggestionEnginePrewarmTests: XCTestCase {

    func test_prewarm_prefillsAndPrimesTheReuseHint() async throws {
        let runtime = RecordingPrewarmRuntime()
        let engine = LlamaSuggestionEngine(runtimeManager: runtime)
        let request = makeRequest(prompt: "hello wor")

        await engine.prewarm(for: request)

        XCTAssertEqual(runtime.prefillPrompts, ["hello wor"])

        _ = try await engine.generateSuggestion(for: request)
        XCTAssertEqual(
            runtime.generateCachedPrefixBytes,
            ["hello wor".utf8.count],
            "A successful prefill should let the next identical-context request advertise full reuse."
        )
    }

    // MARK: - Helpers

    private func makeRequest(prompt: String) -> SuggestionRequest {
        CotabbyTestFixtures.suggestionRequest(prefixText: prompt, prompt: prompt)
    }
}

/// Records prefill calls and the reuse hints later generations advertise, so the prewarm contract
/// can be exercised without loading a real model.
@MainActor
private final class RecordingPrewarmRuntime: LlamaRuntimeGenerating {
    var prefillError: Error?
    var generateResult: Result<LlamaGenerationOutput, Error> = .success(.text("ok"))
    private(set) var prefillPrompts: [String] = []
    private(set) var generateCachedPrefixBytes: [Int?] = []

    func generate(
        prompt: String,
        cachedPrefixBytes: Int?,
        options: LlamaGenerationOptions
    ) async throws -> LlamaGenerationOutput {
        generateCachedPrefixBytes.append(cachedPrefixBytes)
        return try generateResult.get()
    }

    func resetPromptCache() {}

    func prefill(prompt: String, cachedPrefixBytes: Int?, options: LlamaGenerationOptions) async throws {
        if let prefillError {
            throw prefillError
        }
        prefillPrompts.append(prompt)
    }
}
