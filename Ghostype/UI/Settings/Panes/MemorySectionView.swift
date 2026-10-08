import SwiftUI

/// The "Suggestion Memory" section of the Context settings pane, next to the typing-history
/// section.
///
/// Presentation only: every action goes to `MemoryRecorder`, which owns the toggle state, the
/// counts, and the deletion. The view never touches the database or the Keychain directly.
struct MemorySectionView: View {
    @ObservedObject var recorder: MemoryRecorder
    @State private var isConfirmingClear = false

    var body: some View {
        Section("Suggestion Memory") {
            Toggle(isOn: Binding(
                get: { recorder.isEnabled },
                set: { recorder.setEnabled($0) }
            )) {
                SettingsRowLabel(
                    title: "Remember what I type to improve suggestions",
                    description: "Learns words and phrases from accepted and dismissed suggestions, " +
                        "encrypted on this Mac. Only Apple Intelligence and the local model use " +
                        "it — it is never sent to an endpoint. Password fields are never recorded.",
                    systemImage: "brain"
                )
            }
            .settingsItem(.suggestionMemory)

            HStack {
                SettingsRowLabel(
                    title: "Learned vocabulary",
                    description: summaryText,
                    systemImage: "text.book.closed"
                )
                Spacer()
                Button("Clear memory…") {
                    isConfirmingClear = true
                }
                .buttonStyle(.link)
                .foregroundStyle(.red)
                .disabled(recorder.eventCount == 0 && recorder.phraseCount == 0)
            }
            .settingsItem(.suggestionMemory)

            if let clearError = recorder.clearError {
                SettingsRowLabel(
                    title: "Couldn't clear memory",
                    description: clearError,
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Clear suggestion memory?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear memory", role: .destructive) {
                recorder.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Deletes the encrypted database and rotates its encryption key, so the learned " +
                "words and phrases can never be recovered. This cannot be undone."
            )
        }
    }

    private var summaryText: String {
        switch recorder.status {
        case .loading:
            return "Loading…"
        case .unavailable(let message):
            return "Unavailable: \(message)"
        case .ready:
            let phrases = recorder.phraseCount
            let events = recorder.eventCount
            return "\(phrases) \(phrases == 1 ? "phrase" : "phrases") learned " +
                "from \(events) \(events == 1 ? "event" : "events")"
        }
    }
}
