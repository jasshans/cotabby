import Foundation

/// File overview:
/// Decides whether a fresh screen-context capture differs enough from the one already in use to
/// be worth swapping into the prompt.
///
/// Why this exists: the visual-context session re-captures the focused window every few seconds,
/// and that capture always contains the text the user just typed (and often the ghost text). Any
/// byte difference used to count as "the screen changed": the coordinator then hid the visible
/// suggestion, cancelled generation, and the new excerpt rewrote the prompt head before the caret
/// text, so the llama KV cache could not be reused and the next suggestion paid a full prefill
/// (~1s on a 2B model instead of ~50ms). Typing changes a line or two; navigating to another chat
/// or document replaces most of them. Comparing the sets of lines tells those apart.
///
/// Pure; `VisualContextCoordinator` asks it when a capture finishes.
enum ScreenExcerptChangePolicy {
    /// Below this share of lines in common, the capture shows different content. Typing into one
    /// paragraph of a 20-line capture keeps ~90% overlap; switching chats keeps little beyond chrome.
    // ponytail: fixed line-overlap threshold; tune from real captures if navigation slips through.
    static let minimumSharedLineFraction = 0.6

    static func isMaterialChange(from old: String?, to new: String) -> Bool {
        guard let old, !old.isEmpty else { return true }
        let oldLines = lines(old), newLines = lines(new)
        guard !oldLines.isEmpty, !newLines.isEmpty else { return oldLines != newLines }
        let shared = Double(oldLines.intersection(newLines).count)
        return shared / Double(max(oldLines.count, newLines.count)) < minimumSharedLineFraction
    }

    private static func lines(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }
}
