import SwiftUI

/// Local editor for user-defined `/trigger` expansions, wired through the settings model so the
/// same validation and persistence apply to UI edits and loaded preferences.
struct SnippetMacroEditor: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    @State private var triggerText = ""
    @State private var expansionText = ""

    private var snippets: [UserSnippet] { suggestionSettings.userSnippets }
    private var normalizedTrigger: String? { UserSnippetCatalog.normalizedTrigger(triggerText) }
    private var isUpdating: Bool {
        normalizedTrigger.map { trigger in snippets.contains { $0.trigger == trigger } } ?? false
    }
    private var canAdd: Bool {
        (snippets.count < UserSnippetCatalog.maxSnippets || isUpdating) && normalizedTrigger != nil &&
            !expansionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Snippets")
                .font(.system(size: 13, weight: .medium))
            Text("Type / and a trigger, then accept to insert your saved text. Snippets are stored on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(snippets) { snippet in
                HStack(spacing: 10) {
                    Text("/\(snippet.trigger)")
                        .font(.system(.body, design: .monospaced))
                    Text(snippet.expansion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button {
                        suggestionSettings.removeSnippet(trigger: snippet.trigger)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove /\(snippet.trigger) snippet")
                }
            }
            HStack(spacing: 8) {
                TextField("trigger", text: $triggerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 110)
                TextField("Expansion text", text: $expansionText, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addSnippet)
                Button(isUpdating ? "Update" : "Add", action: addSnippet)
                    .disabled(!canAdd)
            }
            if !triggerText.isEmpty && normalizedTrigger == nil {
                Text("Triggers start with a letter and use only letters, digits, hyphens, and dots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func addSnippet() {
        guard canAdd else { return }
        suggestionSettings.addSnippet(trigger: triggerText, expansion: expansionText)
        triggerText = ""
        expansionText = ""
    }
}
