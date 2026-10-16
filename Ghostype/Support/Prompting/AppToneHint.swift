import Foundation

/// File overview:
/// Maps the focused app (by bundle identifier) to the writing tone Ghostype should adopt.
/// Both prompt renderers need this mapping, but they need it in different shapes: the
/// Foundation Models path has an instruction channel, so it gets imperative hints
/// ("Match a professional register"); the base-model path has no instruction channel,
/// so it gets descriptive conditioning ("The writer is composing an email in a
/// professional register") — a base model conditions on description, it does not obey
/// commands.
///
/// Why this file exists as its own boundary: the app-to-tone mapping is pure policy
/// (bundle ID in, tone out) with no service lifetime, no model access, and no mutable
/// state. Keeping it in `Support/Prompting` means both renderers share one mapping
/// instead of drifting apart, and the mapping is testable without a prompt renderer.
/// `FoundationModelPromptRenderer` calls `instruction(forBundleIdentifier:)`; 
/// `BaseCompletionPromptRenderer` calls `description(forBundleIdentifier:)`.

/// Shared per-app tone mapping used by both prompt renderers.
///
/// The mapping is keyed on bundle identifier prefixes for well-known apps, falling back
/// to the coarse `AppSurfaceClassifier` category. This captures the typical register of
/// each app so the user doesn't have to configure per-app instructions manually.
enum AppToneHint {
    /// Imperative tone hint for the Foundation Models (instruction-following) path.
    static func instruction(forBundleIdentifier identifier: String) -> String? {
        switch tone(forBundleIdentifier: identifier) {
        case .email:
            return "The user is writing an email. Match a professional, clear register. " +
                "Finish the current thought; don't start a new topic."
        case .slack:
            return "The user is in Slack (work chat). Keep it brief, friendly-professional, and scannable. Match the thread's tone."
        case .discord:
            return "The user is in Discord (casual chat). Keep it informal and conversational, like texting a friend."
        case .messaging:
            return "The user is in a messaging app. Keep it short and natural, like a text message. No formal sign-offs."
        case .aiAssistant:
            return "The user is prompting an AI assistant. Help them phrase a clear, specific request."
        case .codeEditor:
            return "The user is writing code, so the continuation should be code rather than prose. In comments, be concise and technical."
        case .emailGeneric:
            return "The user is writing an email, so keep a professional register and finish the current thought."
        case .chatGeneric:
            return "The user is in a chat app, so keep the continuation short and match the conversation's tone."
        case .browser:
            return "The user is typing inside a browser, so keep the continuation concise and match the page's context."
        case .none:
            return nil
        }
    }

    /// Descriptive tone line for the base-model (llama/Gemma) path. Written as a
    /// description of the writing situation, not a command.
    static func description(forBundleIdentifier identifier: String) -> String? {
        switch tone(forBundleIdentifier: identifier) {
        case .email:
            return "The writer is composing an email in a professional, clear register."
        case .slack:
            return "The writer is in Slack, a work chat — brief, friendly-professional, scannable."
        case .discord:
            return "The writer is in Discord, a casual chat — informal and conversational."
        case .messaging:
            return "The writer is sending a short, natural text message."
        case .aiAssistant:
            return "The writer is phrasing a clear, specific request to an AI assistant."
        case .codeEditor:
            return "The writer is writing code."
        case .emailGeneric:
            return "The writer is composing an email in a professional register."
        case .chatGeneric:
            return "The writer is in a chat app — short, conversational."
        case .browser:
            return "The writer is typing in a browser — concise."
        case .none:
            return nil
        }
    }

    private enum Tone {
        case email
        case slack
        case discord
        case messaging
        case aiAssistant
        case codeEditor
        case emailGeneric
        case chatGeneric
        case browser
        case none
    }

    private static func tone(forBundleIdentifier identifier: String) -> Tone {
        let lowercased = identifier.lowercased()
        if lowercased.hasPrefix("com.apple.mail") || lowercased.hasPrefix("com.microsoft.outlook") {
            return .email
        }
        if lowercased.hasPrefix("com.tinyspeck.slackmacgap") {
            return .slack
        }
        if lowercased.hasPrefix("com.hnc.discord") {
            return .discord
        }
        if lowercased.hasPrefix("net.whatsapp.whatsapp") || lowercased.hasPrefix("ru.keepcoder.telegram")
            || lowercased.hasPrefix("com.apple.mobilesms") {
            return .messaging
        }
        if lowercased.hasPrefix("com.anthropic.claudefordesktop") || lowercased.hasPrefix("com.openai.codex") {
            return .aiAssistant
        }
        switch AppSurfaceClassifier.classify(bundleIdentifier: identifier) {
        case .codeEditor:
            return .codeEditor
        case .email:
            return .emailGeneric
        case .chat:
            return .chatGeneric
        case .browser:
            return .browser
        case .terminal, .other:
            return .none
        }
    }
}
