import Foundation

/// Matches user-defined slash triggers before built-in macro families. The snippet list is read
/// live so edits in Settings apply on the next keystroke without rebuilding the macro engine.
struct SnippetMacroEvaluator: MacroEvaluating {
    private let snippets: () -> [UserSnippet]

    init(snippets: @escaping () -> [UserSnippet]) {
        self.snippets = snippets
    }

    func evaluate(_ query: String) -> MacroResult? {
        guard let snippet = snippets().first(where: { $0.trigger == query.lowercased() }) else {
            return nil
        }
        let preview = snippet.expansion.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return MacroResult(
            previewText: preview.count > 60 ? String(preview.prefix(60)) + "…" : preview,
            insertionText: snippet.expansion
        )
    }
}
