import Foundation

/// File overview:
/// Decides whether a superseded llama request's prompt decode is worth letting finish.
///
/// A keystroke cancels the running request, but its prompt decode is left to run: the next prompt
/// usually differs only in the last few characters, so that decode is exactly the KV cache the next
/// request reuses (~50 ms instead of a cold read). When the next prompt diverges early instead (a
/// backspace or edit far back, the context window sliding), the finished decode is mostly useless,
/// and the new request would wait for it behind the runtime lock (up to ~1 s on a 2B model) before
/// paying its own cold read. Then the stale decode is aborted.
///
/// Pure; `LlamaRuntimeManager` asks it when a new request starts while another is still running.
enum StalePromptDecodePolicy {
    // ponytail: fixed half-prompt threshold; hybrid models (Bonsai, Gemma SWA) restore only from a
    // checkpoint near the prompt tail, so for them any early divergence is waste. Tune per model if
    // a measurement shows the wait paying off below half.
    /// Below this share of the running prompt in common, its decode is not worth waiting for.
    static let minimumSharedFraction = 0.5

    static func shouldAbort(running: String, next: String) -> Bool {
        let runningBytes = running.utf8
        guard !runningBytes.isEmpty else { return false }
        let shared = zip(runningBytes, next.utf8).prefix { $0 == $1 }.count
        return Double(shared) < Double(runningBytes.count) * minimumSharedFraction
    }
}
