import Foundation

/// File overview:
/// Renders the single prompt string consumed by the local llama runtime.
///
/// Why this file exists:
/// llama.cpp does not give us a separate "instructions" channel the way Foundation Models does.
/// That means all base behavior, user preferences, and request context must be composed into one
/// prompt string. Keeping that composition isolated here prevents prompt policy from leaking into
/// `SuggestionRequestFactory` or the runtime lifecycle layer.
enum LlamaPromptRenderer {
    static func prompt(
        prefixText: String,
        applicationName: String,
        promptMode: SuggestionPromptMode,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        switch promptMode {
        case .prefixOnly:
            // Prefix-only is intentionally the old low-overhead path: send only the user's local
            // prefix text. This mode is useful precisely because it avoids extra prompt framing.
            return prefixText
        case .guided:
            return guidedPrompt(
                prefixText: prefixText,
                applicationName: applicationName,
                completionLengthInstruction: completionLengthInstruction,
                customAIInstructions: customAIInstructions
            )
        }
    }

    /// Guided mode keeps a more explicit contract for local models that benefit from stronger task
    /// framing, especially when testing how much custom style guidance the model actually follows.
    private static func guidedPrompt(
        prefixText: String,
        applicationName: String,
        completionLengthInstruction: String,
        customAIInstructions: String?
    ) -> String {
        var sections = [
            "You are Tabby's inline autocomplete engine for a macOS text field.",
            "",
            "Rules (highest priority):",
            "Continue the user's existing text at the caret.",
            "Do not answer the user as an assistant.",
            "Return exactly one continuation fragment.",
            completionLengthInstruction,
            "Do not repeat text already present before the caret.",
            "Do not add labels, bullets, markdown, quotes, or explanation.",
            "Match the surrounding tone, punctuation, and language."
        ]

        sections.append(contentsOf: CustomAIInstructionFormatter.promptSectionLines(from: customAIInstructions))
        sections.append(contentsOf: [
            "App: \(applicationName)",
            "Text before caret:",
            prefixText,
            "",
            "Continuation:"
        ])

        return sections.joined(separator: "\n")
    }
}
