import Combine
import Foundation

/// File overview:
/// Owns the user-editable autocomplete preferences that are shared across the app:
/// engine selection, completion length, and the local-model prompt mode preference.
///
/// This type is the right owner for those values because they are product settings, not
/// `SuggestionCoordinator` session state. The coordinator should react to settings changes, not
/// persist them itself.
@MainActor
final class SuggestionSettingsModel: ObservableObject {
    @Published private(set) var isGloballyEnabled: Bool
    @Published private(set) var showCaretIndicator: Bool
    @Published private(set) var selectedEngine: SuggestionEngineKind
    @Published private(set) var selectedWordCountPreset: SuggestionWordCountPreset
    @Published private(set) var selectedLocalPromptMode: SuggestionPromptMode

    private let userDefaults: UserDefaults

    private static let isGloballyEnabledDefaultsKey = "tabbyGloballyEnabled"
    private static let showCaretIndicatorDefaultsKey = "tabbyShowCaretIndicator"
    private static let selectedEngineDefaultsKey = "selectedSuggestionEngine"
    private static let selectedWordCountPresetDefaultsKey = "selectedSuggestionWordCountPreset"
    private static let selectedLocalPromptModeDefaultsKey = "selectedLocalSuggestionPromptMode"

    init(
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults

        // Default to enabled and showing the caret indicator on first launch.
        let resolvedGloballyEnabled = userDefaults.object(forKey: Self.isGloballyEnabledDefaultsKey) as? Bool ?? true
        let resolvedShowCaretIndicator = userDefaults.object(forKey: Self.showCaretIndicatorDefaultsKey) as? Bool ?? true

        let resolvedEngine =
            userDefaults
            .string(forKey: Self.selectedEngineDefaultsKey)
            .flatMap(SuggestionEngineKind.init(rawValue:))
            ?? .llamaOpenSource
        let resolvedWordCountPreset =
            userDefaults
            .string(forKey: Self.selectedWordCountPresetDefaultsKey)
            .flatMap(SuggestionWordCountPreset.init(rawValue:))
            ?? configuration.defaultWordCountPreset
        let resolvedLocalPromptMode =
            userDefaults
            .string(forKey: Self.selectedLocalPromptModeDefaultsKey)
            .flatMap(SuggestionPromptMode.init(rawValue:))
            ?? configuration.defaultPromptMode

        isGloballyEnabled = resolvedGloballyEnabled
        showCaretIndicator = resolvedShowCaretIndicator
        selectedEngine = resolvedEngine
        selectedWordCountPreset = resolvedWordCountPreset
        selectedLocalPromptMode = resolvedLocalPromptMode

        userDefaults.set(resolvedGloballyEnabled, forKey: Self.isGloballyEnabledDefaultsKey)
        userDefaults.set(resolvedShowCaretIndicator, forKey: Self.showCaretIndicatorDefaultsKey)
        persistSelectedEngine(resolvedEngine)
        persistSelectedWordCountPreset(resolvedWordCountPreset)
        persistSelectedLocalPromptMode(resolvedLocalPromptMode)
    }

    var availablePromptModes: [SuggestionPromptMode] {
        selectedEngine.supportedPromptModes
    }

    var effectivePromptMode: SuggestionPromptMode {
        Self.effectivePromptMode(
            engine: selectedEngine,
            localPromptMode: selectedLocalPromptMode
        )
    }

    var snapshot: SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: isGloballyEnabled,
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            effectivePromptMode: effectivePromptMode
        )
    }

    func selectEngine(_ engine: SuggestionEngineKind) {
        guard selectedEngine != engine else {
            return
        }

        selectedEngine = engine
        persistSelectedEngine(engine)
    }

    func selectWordCountPreset(_ preset: SuggestionWordCountPreset) {
        guard selectedWordCountPreset != preset else {
            return
        }

        selectedWordCountPreset = preset
        persistSelectedWordCountPreset(preset)
    }

    func selectLocalPromptMode(_ mode: SuggestionPromptMode) {
        guard selectedLocalPromptMode != mode else {
            return
        }

        selectedLocalPromptMode = mode
        persistSelectedLocalPromptMode(mode)
    }

    func setGloballyEnabled(_ enabled: Bool) {
        guard isGloballyEnabled != enabled else { return }
        isGloballyEnabled = enabled
        userDefaults.set(enabled, forKey: Self.isGloballyEnabledDefaultsKey)
    }

    func setShowCaretIndicator(_ show: Bool) {
        guard showCaretIndicator != show else { return }
        showCaretIndicator = show
        userDefaults.set(show, forKey: Self.showCaretIndicatorDefaultsKey)
    }

    private static func effectivePromptMode(
        engine: SuggestionEngineKind,
        localPromptMode: SuggestionPromptMode
    ) -> SuggestionPromptMode {
        if engine.supportedPromptModes.contains(localPromptMode) {
            return localPromptMode
        }

        return engine.defaultPromptMode
    }

    private func persistSelectedEngine(_ engine: SuggestionEngineKind) {
        userDefaults.set(engine.rawValue, forKey: Self.selectedEngineDefaultsKey)
    }

    private func persistSelectedWordCountPreset(_ preset: SuggestionWordCountPreset) {
        userDefaults.set(preset.rawValue, forKey: Self.selectedWordCountPresetDefaultsKey)
    }

    private func persistSelectedLocalPromptMode(_ mode: SuggestionPromptMode) {
        userDefaults.set(mode.rawValue, forKey: Self.selectedLocalPromptModeDefaultsKey)
    }
}

extension SuggestionSettingsModel: SuggestionSettingsProviding {
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        Publishers.CombineLatest4(
            $isGloballyEnabled,
            $selectedEngine,
            $selectedWordCountPreset,
            $selectedLocalPromptMode
        )
        .map { globallyEnabled, engine, wordCountPreset, localPromptMode in
            SuggestionSettingsSnapshot(
                isGloballyEnabled: globallyEnabled,
                selectedEngine: engine,
                selectedWordCountPreset: wordCountPreset,
                effectivePromptMode: Self.effectivePromptMode(
                    engine: engine,
                    localPromptMode: localPromptMode
                )
            )
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }
}
