import SwiftUI

/// File overview:
/// "Speed" detail pane: the switches that trade context for latency. The two prompt toggles are
/// stored in `UserDefaults` under `SpeedSettings` keys and read by the coordinator per request, so
/// `@AppStorage` is the whole binding. Predict Ahead is the existing General setting, repeated here
/// because it is the third speed lever and users look for it next to the other two.
struct SpeedPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    @AppStorage(SpeedSettings.stablePrefixWindowKey) private var stablePrefixWindow = true
    @AppStorage(SpeedSettings.shortContextKey) private var shortContext = false

    var body: some View {
        SettingsPaneScaffold {
            Section("Speed") {
                Toggle(isOn: $stablePrefixWindow) {
                    SettingsRowLabel(
                        title: "Reuse context between keystrokes",
                        description: "Keep the start of the text the model reads steady while you type, so it only " +
                            "processes your new letters instead of re-reading the whole passage. Biggest win in long " +
                            "documents. Applies to Open Source models.",
                        systemImage: "memorychip"
                    )
                }
                .settingsItem(.reuseContextBetweenKeystrokes)

                Toggle(isOn: $shortContext) {
                    SettingsRowLabel(
                        title: "Shorter context",
                        description: "Read about \(SpeedSettings.shortPrefixCharacters) characters before the caret " +
                            "instead of the full window. Faster first suggestion in a new field or after an edit, " +
                            "at some cost to how well suggestions follow the earlier text.",
                        systemImage: "text.badge.minus"
                    )
                }
                .settingsItem(.shorterContext)

                Toggle(isOn: Binding(
                    get: { suggestionSettings.predictAheadWhileTyping },
                    set: { suggestionSettings.setPredictAheadWhileTyping($0) }
                )) {
                    SettingsRowLabel(
                        title: "Predict Ahead While Typing",
                        description: "Keep the running prediction alive while your typed letters match it, so a " +
                            "suggestion is ready the moment you pause. Same setting as in General.",
                        systemImage: "bolt.horizontal.circle"
                    )
                }
            }
        }
    }
}
