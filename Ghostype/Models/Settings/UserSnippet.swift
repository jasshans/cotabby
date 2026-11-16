import Foundation

/// A saved slash trigger and its insertion text. Settings storage normalizes these values before
/// they reach the live macro evaluator.
nonisolated struct UserSnippet: Codable, Equatable, Identifiable, Sendable {
    var trigger: String
    var expansion: String

    var id: String { trigger }
}

nonisolated enum UserSnippetCatalog {
    static let maxSnippets = 50
    static let maxTriggerLength = 30
    static let maxExpansionLength = 500

    static func normalizedTrigger(_ raw: String) -> String? {
        var trigger = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trigger.hasPrefix("/") {
            trigger.removeFirst()
        }
        guard !trigger.isEmpty, trigger.count <= maxTriggerLength,
              trigger.first?.isLetter == true,
              trigger.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." })
        else {
            return nil
        }
        return trigger
    }

    static func normalize(_ snippets: [UserSnippet]) -> [UserSnippet] {
        var seen = Set<String>()
        var result: [UserSnippet] = []
        for snippet in snippets {
            guard let trigger = normalizedTrigger(snippet.trigger) else { continue }
            let expansion = String(snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxExpansionLength))
            guard !expansion.isEmpty, seen.insert(trigger).inserted else { continue }
            result.append(UserSnippet(trigger: trigger, expansion: expansion))
            if result.count == maxSnippets { break }
        }
        return result.sorted { $0.trigger < $1.trigger }
    }
}
