import Foundation
import XCTest
@testable import Ghostype

/// File overview:
/// Replays a person typing three paragraphs into one field through the production
/// `SuggestionCoordinator` and the real local model, and measures what that person sees: whether a
/// ghost is on screen when they press the next key, whether its first Tab chunk matches what they
/// type next, how long after a keystroke it appeared, and, when nothing is on screen, which
/// coordinator stage explains the gap.
///
/// Why its own eval: `LlamaTypingSessionEvalTests` calls the engine directly and
/// `TypingExperienceEvalTests` scripts a few acceptance moments. Neither runs the per-keystroke
/// path a long text takes: the event tap firing before the host publishes the key to
/// Accessibility, the host-publish poll, adaptive debounce, predict-ahead, streaming, the typo gate
/// (including silent automatic fixes), the seam guard, and type-through.
///
/// Boundaries: real coordinator and `LlamaSuggestionEngine`; `ReplayEditor` stands in for the host
/// app and the 50 ms `FocusTracker` poll, exposing each edit to Accessibility only after a
/// configurable publish delay (about 40 ms for a native field, 120 ms for a WebKit/Chromium host).
/// Not covered: real AX cost, the overlay controller's own holds (pixel caret reads, caret lag)
/// and fade-in, compositor latency, screen-excerpt refreshes, clipboard and typing history, and Tab
/// acceptance (the typist never presses Tab, so every number is "offered"). Visibility here is
/// therefore an upper bound for hosts where `OverlayController` holds presentations.
///
/// Run in Release for meaningful latency. xcodebuild forwards `TEST_RUNNER_`-prefixed variables to
/// the app-hosted runner with the prefix removed:
///
///     TEST_RUNNER_COTABBY_EVAL_MODEL_PATH=/absolute/model.gguf xcodebuild test \
///       -workspace build/cotabby-dependencies/Ghostype.xcworkspace -scheme Ghostype \
///       -destination 'platform=macOS' -configuration Release ENABLE_TESTABILITY=YES \
///       SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' CODE_SIGNING_ALLOWED=NO \
///       -only-testing:GhostypeTests/TypingReplayEvalTests -derivedDataPath build/DerivedData
///
/// `TEST_RUNNER_COTABBY_REPLAY_CONFIGS=user-40ms,typo-off-40ms` runs a subset. The report is
/// printed and written to `build/eval/typing-replay-<model>.json` (synthetic text only).
@MainActor
final class TypingReplayEvalTests: XCTestCase {
    /// Runs in every pass so the gated eval's arithmetic and attribution cannot rot unnoticed.
    func testReplayScoring() {
        XCTAssertTrue(TypingReplayScoring.isUseful(ghost: " the plan", upcoming: " the planning"))
        XCTAssertTrue(TypingReplayScoring.isUseful(ghost: "ing the plan", upcoming: "ing then"))
        XCTAssertTrue(TypingReplayScoring.isUseful(ghost: "ct. The plan", upcoming: "ct before"))
        XCTAssertFalse(TypingReplayScoring.isUseful(ghost: " a plan", upcoming: " the plan"))
        XCTAssertFalse(TypingReplayScoring.isUseful(ghost: "  ", upcoming: "  x"))
        XCTAssertEqual(TypingReplayScoring.matchedCharacters(ghost: "ing the plan", upcoming: "ing the pilot"), 9)
        XCTAssertEqual(TypingReplayScoring.percentile([30, 10, 20, 40], 0.5), 20)
        XCTAssertEqual(TypingReplayScoring.percentile([30, 10, 20, 40], 0.9), 40)
        XCTAssertNil(TypingReplayScoring.percentile([], 0.5))

        XCTAssertEqual(TypingReplayScoring.reason(after: [.stage("debouncing"), .stage("generating")], sync: [], key: "a"),
                       "generation-in-flight")
        XCTAssertEqual(TypingReplayScoring.reason(
            after: [.stage("stale-drop"), .hidden("Overlay hidden because a stale result was dropped.")], sync: [], key: "a"),
            "stale-result-dropped")
        XCTAssertEqual(TypingReplayScoring.reason(after: [.stage("typed-match-advanced")], sync: [], key: "a"),
                       "waiting-host-publish", "Unmapped stages fall through to the fallback.")
        XCTAssertEqual(TypingReplayScoring.reason(after: [], sync: [.stage("typing-prediction-retained")], key: "a"),
                       "typing-prediction-held")
        XCTAssertEqual(TypingReplayScoring.reason(after: [], sync: [], key: "\n"), "return-dismissal")

        let keys = TypingReplayScoring.schedule(for: "Hi. Ok", seed: 7)
        XCTAssertEqual(keys.map(\.character), Array("Hi. Ok"))
        XCTAssertTrue(zip(keys, keys.dropFirst()).allSatisfy { $0.atMilliseconds < $1.atMilliseconds })
        XCTAssertGreaterThan(keys[4].atMilliseconds - keys[3].atMilliseconds, 300, "A new sentence starts after a pause.")
    }

    func testReportTypingReplay() async throws {
        #if RUN_LLAMA_EVAL
        let manager = try LlamaEvalRuntime.makeManager()
        do { try await manager.prepare() } catch {
            if ProcessInfo.processInfo.environment["COTABBY_EVAL_MODEL_PATH"] != nil { throw error }
            throw XCTSkip("Download a local model before running the typing replay: \(error)")
        }
        defer { manager.shutdownSync(timeoutSeconds: 5) }
        let engine = LlamaSuggestionEngine(runtimeManager: manager)
        let model = manager.diagnostics.modelFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
        let selected = ProcessInfo.processInfo.environment["COTABBY_REPLAY_CONFIGS"]
            .map { Set($0.split(separator: ",").map(String.init)) }

        var runs: [ReplayRunReport] = []
        for configuration in ReplayConfiguration.standard where selected?.contains(configuration.name) ?? true {
            let recording = ExperienceRecordingEngine(engine: engine)
            let keys = TypingReplayScoring.schedule(
                for: TypingReplayFixture.text, meanMilliseconds: configuration.meanKeyMilliseconds, seed: 20_261_018)
            let run = try await replay(configuration, keys: keys, engine: recording)
            print(run.summary)
            XCTAssertFalse(recording.records.contains { $0.outcome.hasPrefix("failed") }, "\(configuration.name): engine failures")
            runs.append(run)
        }

        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/eval")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let artifact = directory.appendingPathComponent("typing-replay-\(model).json")
        try encoder.encode(ReplayReport(model: model, runs: runs)).write(to: artifact)
        print("Typing replay model: \(model)\nTyping replay artifact: \(artifact.path)")
        #else
        throw XCTSkip("Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' to run the typing replay.")
        #endif
    }

    #if RUN_LLAMA_EVAL
    /// One configuration, one fresh coordinator, one engine cache: the typist clicks into an empty
    /// field, waits for prewarm, types the fixture on its schedule, and pauses at the end.
    private func replay(
        _ configuration: ReplayConfiguration, keys: [ReplayKey], engine: ExperienceRecordingEngine
    ) async throws -> ReplayRunReport {
        await engine.resetCachedGenerationContext()
        let previousField = ReplayEditor.context("", element: "previous-field", focusSequence: 1)
        let rig = makeCoordinatorRig(
            snapshot: previousField,
            settingsSnapshot: configuration.settings,
            generationEngine: engine,
            configuration: LlamaEvalRuntime.configuration
        )
        rig.visualContext.excerptValue = TypingReplayFixture.screenExcerpt
        let editor = ReplayEditor(rig: rig, publishDelayMilliseconds: configuration.publishDelayMilliseconds)
        let recorder = ReplayRecorder()
        rig.coordinator.logger.stageObserver = { recorder.observe(.stage($0)) }
        // Chain in front of the coordinator's own overlay callback; it still drives the accept tap.
        let coordinatorOverlayCallback = rig.overlayController.onStateChange
        rig.overlayController.onStateChange = { state in
            switch state {
            case let .visible(text, _, _): recorder.observe(.shown(text))
            case let .hidden(reason): recorder.observe(.hidden(reason))
            }
            coordinatorOverlayCallback?(state)
        }

        rig.coordinator.start()
        // The typist was in another field; landing on the empty replay field is then a field
        // change, which prewarms the engine exactly as switching fields does in the app.
        _ = rig.interactionState.materializeContext(from: previousField)
        editor.capture()
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(TypingReplayFixture.focusPollMilliseconds))
                rig.focusProvider.refreshNow()
            }
        }
        var stopped = false
        defer {
            poller.cancel()
            if !stopped { rig.coordinator.stop() }
        }
        try await Task.sleep(for: .milliseconds(1_500))

        let characters = keys.map(\.character)
        let origin = ContinuousClock.now
        for (index, key) in keys.enumerated() {
            try await ContinuousClock().sleep(until: origin.advanced(by: .milliseconds(key.atMilliseconds)))
            recorder.close(state: rig.overlayController.state, upcoming: String(characters[index...].prefix(80)))
            recorder.open(character: key.character, visible: rig.overlayController.state.isVisible)
            // The event tap sees the key before the host applies it; the editor publishes it later.
            _ = rig.coordinator.handleInputEvent(key.character == "\n"
                ? CotabbyTestFixtures.inputEvent(kind: .dismissal, keyCode: 36)
                : CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: String(key.character)))
            editor.type(key.character)
            recorder.endDispatch(visible: rig.overlayController.state.isVisible)
        }
        try await Task.sleep(for: .milliseconds(1_500))
        recorder.close(state: rig.overlayController.state, upcoming: "")

        poller.cancel()
        rig.coordinator.stop()
        stopped = true
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
        // Fire-and-forget continuation prefetches still hold the engine; drain before the next run.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while engine.inFlightCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty, "The typist never accepts, so nothing may be inserted.")
        return ReplayRunReport(configuration: configuration, recorder: recorder, editor: editor, requests: engine.records)
    }
    #endif
}

// MARK: - Pure scoring

/// One scheduled key press, in milliseconds after the typist starts.
struct ReplayKey {
    let character: Character
    let atMilliseconds: Int
}

/// What the replay observed between two keystrokes: a coordinator stage name, or an overlay change.
enum ReplayEvent: Equatable {
    case stage(String)
    case shown(String)
    case hidden(String)

    var label: String {
        switch self {
        case let .stage(name): return "stage:\(name)"
        case let .shown(text): return "shown:\(text.prefix(40))"
        case let .hidden(reason): return "hidden:\(reason)"
        }
    }
}

/// Deterministic schedule, usefulness, and attribution rules, kept pure so `testReplayScoring`
/// checks them without a model.
@MainActor
enum TypingReplayScoring {
    /// Useful means the first Tab would insert exactly what the typist types next. Trailing
    /// punctuation is its own Tab, as with the user's `autoAcceptTrailingPunctuation = false`.
    static func isUseful(ghost: String, upcoming: String) -> Bool {
        let chunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: ghost, autoAcceptTrailingPunctuation: false)
        return !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && upcoming.hasPrefix(chunk)
    }

    static func matchedCharacters(ghost: String, upcoming: String) -> Int {
        zip(ghost, upcoming).prefix { $0 == $1 }.count
    }

    /// Nearest-rank percentile; nil for no samples.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1)]
    }

    /// About 160 ms per key with ±40% jitter, a longer pause before a new sentence, a short one
    /// after a comma, and a long one after Return. Seeded so every configuration types identically.
    static func schedule(for text: String, meanMilliseconds: Double = 160, seed: UInt64) -> [ReplayKey] {
        var random = SplitMix64(state: seed)
        var at = 0
        var previous: Character?
        var beforePrevious: Character?
        return text.map { character in
            defer { (beforePrevious, previous) = (previous, character) }
            guard let previous else { return ReplayKey(character: character, atMilliseconds: 0) }
            var gap = meanMilliseconds * Double.random(in: 0.6...1.4, using: &random)
            if previous == "\n" {
                gap += Double.random(in: 1_000...1_600, using: &random)
            } else if previous == " ", let beforePrevious, ".?!".contains(beforePrevious) {
                gap += Double.random(in: 350...800, using: &random)
            } else if previous == " ", beforePrevious == "," {
                gap += Double.random(in: 100...250, using: &random)
            }
            at += Int(gap)
            return ReplayKey(character: character, atMilliseconds: at)
        }
    }

    /// Why no ghost was visible at the next keystroke: the newest event after the keystroke's own
    /// synchronous handling that names a cause. With none, the pipeline was still waiting for the
    /// host to publish the key (or Return dismissed it).
    static func reason(after events: [ReplayEvent], sync: [ReplayEvent], key: Character) -> String {
        for event in events.reversed() {
            switch event {
            case let .stage(name):
                if let reason = stageReasons[name] { return reason }
            case let .hidden(text):
                return hiddenReasons.first { text.contains($0.needle) }?.reason ?? "hidden: \(text.prefix(70))"
            case .shown:
                return "shown"
            }
        }
        let heldByTypingPrediction = sync.contains { event in
            switch event {
            case .stage("typing-prediction-retained"): return true
            case let .hidden(text): return text.contains("matching prediction continues")
            default: return false
            }
        }
        if heldByTypingPrediction { return "typing-prediction-held" }
        return key == "\n" ? "return-dismissal" : "waiting-host-publish"
    }

    private static let stageReasons: [String: String] = [
        "debouncing": "debounce-pending",
        "generating": "generation-in-flight",
        "speculative-generating": "generation-in-flight",
        "typing-prediction-retained": "typing-prediction-held",
        "typing-prediction-restarted": "prediction-restarted",
        "typo-suppressed": "typo-gate-suppressed",
        "typo-auto-corrected": "auto-fixed-typo",
        "typo-auto-correction-stale": "auto-fix-target-changed",
        "seam-suppressed": "seam-guard",
        "stale-drop": "stale-result-dropped",
        "stale-punctuation": "stale-after-space",
        "empty-result": "empty-normalization",
        "failed": "generation-failed",
        "typed-match-exhausted": "typed-through-exhausted",
        "session-exhausted": "typed-through-exhausted"
    ]

    private static let hiddenReasons: [(needle: String, reason: String)] = [
        ("looks misspelled", "typo-gate-suppressed"),
        ("automatically fixed a typo", "auto-fixed-typo"),
        ("automatic correction target changed", "auto-fix-target-changed"),
        ("seam guard", "seam-guard"),
        ("stale result was dropped", "stale-result-dropped"),
        ("had already ended", "stale-after-space"),
        ("empty continuation", "empty-normalization"),
        ("suggestion text was empty", "empty-normalization"),
        ("word boundary", "waiting-word-boundary"),
        ("explicitly dismissed", "dismissal-memory"),
        ("diverged typing prediction", "prediction-restarted"),
        ("matching prediction continues", "typing-prediction-held"),
        ("typing invalidated", "typed-mismatch"),
        ("dismissal key", "return-dismissal"),
        ("no typed text", "empty-field"),
        ("screen context", "screen-context-changed"),
        ("fully consumed", "typed-through-exhausted"),
        ("typed through the rest", "typed-through-exhausted"),
        ("generation failed", "generation-failed")
    ]
}

/// SplitMix64: the smallest seedable generator; the standard library ships none.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Neutral synthetic prose in a conversational, explanatory register. Three misspellings
/// ("realy", "becuase", "teh") exercise the typo gate the way real typing does; usefulness is
/// scored against the text as typed, so those three words count against the model.
enum TypingReplayFixture {
    static let focusPollMilliseconds = 50

    static let text = [
        "Hi team, I wanted to share a quick update on the onboarding project before our meeting on Thursday. "
            + "We finished the first version of the welcome flow last week, "
            + "and the early feedback has been realy positive. "
            + "Most people said the new checklist makes it much easier to understand "
            + "what they need to do on their first day.",
        "There are still a few things we need to sort out before we can launch it to everyone. "
            + "The biggest one is the reminder emails, becuase some of them are going out "
            + "at the wrong time for people in other time zones. "
            + "I think we can fix that by sending them based on the local time of each person instead of our office time.",
        "For the next step, I would like to run a small pilot with two of teh regional teams "
            + "and collect their feedback over the next couple of weeks. "
            + "If that goes well, we can plan the full rollout for the start of next month. "
            + "Let me know if you have any questions or if there is anything you think we should change before then."
    ].joined(separator: "\n")

    /// Stands in for the screen excerpt the user's Screen Recording context provides.
    static let screenExcerpt = """
    Onboarding project
    Status: in progress
    Welcome flow v1 - done
    Checklist page - done
    Reminder emails - bug: wrong send time for some regions
    Pilot - not started
    Next sync: Thursday
    """
}

#if RUN_LLAMA_EVAL
/// The user's saved preferences (com.jasshans.ghostype, October 2026), varied by the host's
/// publish delay, by switching both typo options off, and by a faster typist (100 ms per key).
struct ReplayConfiguration {
    let name: String
    let publishDelayMilliseconds: Int
    let typoOptionsOn: Bool
    var meanKeyMilliseconds: Double = 160

    static let standard = [
        ReplayConfiguration(name: "user-40ms", publishDelayMilliseconds: 40, typoOptionsOn: true),
        ReplayConfiguration(name: "user-120ms-webkit", publishDelayMilliseconds: 120, typoOptionsOn: true),
        ReplayConfiguration(name: "typo-off-40ms", publishDelayMilliseconds: 40, typoOptionsOn: false),
        ReplayConfiguration(name: "user-40ms-fast-typist", publishDelayMilliseconds: 40, typoOptionsOn: true,
                            meanKeyMilliseconds: 100)
    ]

    @MainActor var settings: SuggestionSettingsSnapshot {
        CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .llamaOpenSource, selectedWordCountPreset: .fourToSeven,
            isClipboardContextEnabled: true, isSurfaceContextEnabled: true,
            debounceMilliseconds: 20, focusPollIntervalMilliseconds: TypingReplayFixture.focusPollMilliseconds,
            isMultiLineEnabled: false, suggestWithinWords: true, showFollowingWords: true,
            autoAcceptTrailingPunctuation: false, addSpaceAfterAccept: true,
            streamSuggestionsWhileGenerating: true, predictAheadWhileTyping: true, isFastModeEnabled: false,
            mirrorPreference: .alwaysInline, acceptanceGranularity: .word,
            suppressCompletionsOnTypo: typoOptionsOn, offerTypoCorrections: true,
            automaticallyFixTypos: typoOptionsOn
        )
    }
}

/// The host editor plus its Accessibility view. Every edit (the typist's keys and Ghostype's own
/// replacements) applies to `text` at once and becomes readable `publishDelay` later, in order.
/// `capture()` is one AX read, called by the coordinator's `refreshNow` and by the replay's poll.
@MainActor
private final class ReplayEditor {
    private(set) var text = ""
    private(set) var replacements: [String] = []
    private var published = ""
    private var pending: [(due: ContinuousClock.Instant, edit: (inout String) -> Void)] = []
    private var lastCapture: ContinuousClock.Instant?
    private var lastSnapshot: FocusSnapshot?
    private let publishDelay: Duration
    private let provider: RigFocusProvider

    init(rig: CoordinatorRig, publishDelayMilliseconds: Int) {
        publishDelay = .milliseconds(publishDelayMilliseconds)
        provider = rig.focusProvider
        provider.onRefresh = { [weak self] in self?.capture() }
        provider.captureAge = { [weak self] in
            self?.lastCapture.map { Int(ReplayRecorder.milliseconds($0.duration(to: .now))) }
        }
        rig.inserter.onReplace = { [weak self] count, replacement in
            self?.replace(deletingUTF16Count: count, with: replacement)
        }
    }

    func type(_ character: Character) {
        apply { $0.append(character) }
    }

    private func replace(deletingUTF16Count count: Int, with replacement: String) {
        let removed = (text as NSString).substring(from: max(0, (text as NSString).length - count))
        replacements.append("\(removed.debugDescription) -> \(replacement.debugDescription)")
        apply { text in
            let string = text as NSString
            text = string.substring(to: max(0, string.length - count)) + replacement
        }
    }

    private func apply(_ edit: @escaping (inout String) -> Void) {
        edit(&text)
        pending.append((ContinuousClock.now.advanced(by: publishDelay), edit))
    }

    func capture() {
        let now = ContinuousClock.now
        lastCapture = now
        while let next = pending.first, next.due <= now {
            next.edit(&published)
            pending.removeFirst()
        }
        let context = Self.context(published, element: "replay-field", focusSequence: 2)
        let snapshot = FocusSnapshot(applicationName: context.applicationName, bundleIdentifier: context.bundleIdentifier,
                                     capability: .supported, context: context)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        // `FocusTrackingModel` republishes through `@Published`, which emits in willSet: subscribers
        // run while the provider's `snapshot` still holds the previous value. Keep that order.
        provider.snapshotSubject.send(snapshot)
        // A subscriber may have refreshed re-entrantly and published newer text; keep that one.
        if lastSnapshot == snapshot { provider.snapshot = snapshot }
    }

    /// A multi-line text area whose caret advances 7 pt per character and wraps every 80 columns.
    static func context(_ text: String, element: String, focusSequence: UInt64) -> FocusedInputSnapshot {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let column = lines.last?.count ?? 0
        let row = lines.count - 1 + column / 80
        return CotabbyTestFixtures.focusedInputSnapshot(
            applicationName: "ReplayEditor", elementIdentifier: element, role: "AXTextArea",
            caretRect: CGRect(x: 20 + 7 * CGFloat(column % 80), y: 100 + 18 * CGFloat(row), width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 80, width: 640, height: 480),
            precedingText: text, focusChangeSequence: focusSequence
        )
    }
}

/// What the typist saw after one keystroke, judged at the moment of the next one.
struct ReplayKeystroke: Encodable {
    let character: String
    let dispatchedMilliseconds: Double
    var nextGapMilliseconds: Double?
    var visibleAtNextKey = false
    var ghost: String?
    var isCorrection = false
    var useful = false
    var matchedCharacters = 0
    /// Keystroke to first visible ghost; 0 when the ghost survived the keystroke synchronously.
    var firstVisibleMilliseconds: Double?
    var visibleRightAfterKey = false
    /// A ghost was on screen when the key went down and the key's own handling removed it.
    var killedByKeystroke = false
    var reason: String?
    var trail: [String] = []
}

/// Collects stage and overlay events per keystroke. Events during `handleInputEvent` are kept
/// apart from later ones so attribution names what happened after the key, not the key itself.
@MainActor
private final class ReplayRecorder {
    private(set) var keystrokes: [ReplayKeystroke] = []
    private(set) var stageCounts: [String: Int] = [:]
    private var keyStart = ContinuousClock.now
    private let origin = ContinuousClock.now
    private var syncEvents: [ReplayEvent] = []
    private var laterEvents: [ReplayEvent] = []
    private var dispatching = false
    private var visibleBeforeKey = false

    func observe(_ event: ReplayEvent) {
        if case let .stage(name) = event { stageCounts[name, default: 0] += 1 }
        guard !keystrokes.isEmpty else { return }
        let elapsed = Self.milliseconds(keyStart.duration(to: .now))
        let last = keystrokes.count - 1
        if case .shown = event, keystrokes[last].firstVisibleMilliseconds == nil {
            keystrokes[last].firstVisibleMilliseconds = elapsed
        }
        keystrokes[last].trail.append(String(format: "+%.0fms ", elapsed) + event.label)
        if dispatching { syncEvents.append(event) } else { laterEvents.append(event) }
    }

    func open(character: Character, visible: Bool) {
        keyStart = .now
        syncEvents = []
        laterEvents = []
        visibleBeforeKey = visible
        dispatching = true
        keystrokes.append(ReplayKeystroke(character: String(character),
                                          dispatchedMilliseconds: Self.milliseconds(origin.duration(to: keyStart))))
    }

    func endDispatch(visible: Bool) {
        dispatching = false
        let last = keystrokes.count - 1
        keystrokes[last].visibleRightAfterKey = visible
        keystrokes[last].killedByKeystroke = visibleBeforeKey && !visible
        if visible, keystrokes[last].firstVisibleMilliseconds == nil {
            keystrokes[last].firstVisibleMilliseconds = Self.milliseconds(keyStart.duration(to: .now))
        }
    }

    func close(state: OverlayState, upcoming: String) {
        guard !keystrokes.isEmpty else { return }
        let last = keystrokes.count - 1
        keystrokes[last].nextGapMilliseconds = Self.milliseconds(keyStart.duration(to: .now))
        if case let .visible(text, geometry, _) = state {
            keystrokes[last].visibleAtNextKey = true
            keystrokes[last].ghost = text
            keystrokes[last].isCorrection = geometry.isCorrection
            if !geometry.isCorrection {
                keystrokes[last].useful = TypingReplayScoring.isUseful(ghost: text, upcoming: upcoming)
                keystrokes[last].matchedCharacters = TypingReplayScoring.matchedCharacters(ghost: text, upcoming: upcoming)
            }
        } else {
            keystrokes[last].reason = TypingReplayScoring.reason(
                after: laterEvents, sync: syncEvents, key: Character(keystrokes[last].character))
        }
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private struct ReplayReport: Encodable {
    let model: String
    let measurementScope = "Production SuggestionCoordinator and LlamaSuggestionEngine; a synthetic editor publishes "
        + "each edit to the focus provider after a fixed delay, polled every 50 ms. Excludes real AX cost, overlay "
        + "controller holds and fade-in, screen-excerpt refreshes, and Tab acceptance."
    let runs: [ReplayRunReport]
}

/// Aggregates for one configuration plus the per-keystroke detail they were computed from.
struct ReplayRunReport: Encodable {
    let name: String
    let publishDelayMilliseconds: Int
    let typoOptionsOn: Bool
    let meanKeyMilliseconds: Double
    let keystrokeCount: Int
    let visiblePercent: Double
    let usefulPercent: Double
    let usefulOfVisiblePercent: Double
    let meanMatchedCharactersWhenVisible: Double
    /// Gap to the next key under 400 ms (mid-burst) versus a pause.
    let visiblePercentWhileTyping: Double
    let visiblePercentAtPauses: Double
    let medianKeyToVisibleMilliseconds: Double?
    let p90KeyToVisibleMilliseconds: Double?
    /// Only keystrokes whose ghost had to be produced anew (not kept through type-through).
    let medianFreshKeyToVisibleMilliseconds: Double?
    let p90FreshKeyToVisibleMilliseconds: Double?
    let ghostsKilledByKeystroke: Int
    let ghostsKilledAndNotBackByNextKey: Int
    let notVisibleReasons: [String: Int]
    let stageCounts: [String: Int]
    let correctionsOffered: Int
    let silentAutoFixes: [String]
    let requestCount: Int
    let completedRequests: Int
    let cancelledRequests: Int
    let medianCompletedRequestMilliseconds: Double?
    /// Completed requests whose text the engine withheld, by normalizer or confidence-floor reason.
    let engineSuppressions: [String: Int]
    let finalText: String
    let keystrokes: [ReplayKeystroke]
    /// Every engine request in order, with duration and outcome: cold prefills show up as outliers.
    let requests: [ExperienceRecordingEngine.RequestRecord]

    @MainActor
    fileprivate init(configuration: ReplayConfiguration, recorder: ReplayRecorder, editor: ReplayEditor,
                     requests: [ExperienceRecordingEngine.RequestRecord]) {
        let keys = recorder.keystrokes
        func percent(_ count: Int, of total: Int) -> Double {
            total == 0 ? 0 : (Double(count) * 1_000 / Double(total)).rounded() / 10
        }
        let visible = keys.filter(\.visibleAtNextKey)
        let typing = keys.filter { ($0.nextGapMilliseconds ?? 0) < 400 }
        let pauses = keys.filter { ($0.nextGapMilliseconds ?? 0) >= 400 }
        let toVisible = keys.compactMap(\.firstVisibleMilliseconds)
        let fresh = keys.filter { !$0.visibleRightAfterKey }.compactMap(\.firstVisibleMilliseconds)
        let killed = keys.filter(\.killedByKeystroke)
        let completed = requests.filter { $0.outcome == "completed" }

        name = configuration.name
        publishDelayMilliseconds = configuration.publishDelayMilliseconds
        typoOptionsOn = configuration.typoOptionsOn
        meanKeyMilliseconds = configuration.meanKeyMilliseconds
        keystrokeCount = keys.count
        visiblePercent = percent(visible.count, of: keys.count)
        usefulPercent = percent(keys.filter(\.useful).count, of: keys.count)
        usefulOfVisiblePercent = percent(keys.filter(\.useful).count, of: visible.count)
        meanMatchedCharactersWhenVisible = visible.isEmpty ? 0
            : (Double(visible.map(\.matchedCharacters).reduce(0, +)) / Double(visible.count) * 10).rounded() / 10
        visiblePercentWhileTyping = percent(typing.filter(\.visibleAtNextKey).count, of: typing.count)
        visiblePercentAtPauses = percent(pauses.filter(\.visibleAtNextKey).count, of: pauses.count)
        medianKeyToVisibleMilliseconds = TypingReplayScoring.percentile(toVisible, 0.5)?.rounded()
        p90KeyToVisibleMilliseconds = TypingReplayScoring.percentile(toVisible, 0.9)?.rounded()
        medianFreshKeyToVisibleMilliseconds = TypingReplayScoring.percentile(fresh, 0.5)?.rounded()
        p90FreshKeyToVisibleMilliseconds = TypingReplayScoring.percentile(fresh, 0.9)?.rounded()
        ghostsKilledByKeystroke = killed.count
        ghostsKilledAndNotBackByNextKey = killed.filter { !$0.visibleAtNextKey }.count
        notVisibleReasons = keys.compactMap(\.reason).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        stageCounts = recorder.stageCounts
        correctionsOffered = recorder.stageCounts["typo-correction-ready", default: 0]
        silentAutoFixes = editor.replacements
        requestCount = requests.count
        completedRequests = completed.count
        cancelledRequests = requests.filter { $0.outcome == "cancelled" }.count
        medianCompletedRequestMilliseconds = TypingReplayScoring.percentile(completed.map(\.milliseconds), 0.5)?.rounded()
        engineSuppressions = completed.compactMap(\.suppression).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        finalText = editor.text
        keystrokes = keys
        self.requests = requests
    }

    var summary: String {
        func ms(_ value: Double?) -> String { value.map { "\(Int($0))ms" } ?? "n/a" }
        let reasons = notVisibleReasons.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let typo = typoOptionsOn ? "on" : "off"
        return """
        [typing-replay] \(name) (publish \(publishDelayMilliseconds)ms, typo options \(typo), \
        \(Int(meanKeyMilliseconds))ms/key) keys=\(keystrokeCount)
          visible at next key \(visiblePercent)% (mid-burst \(visiblePercentWhileTyping)%, at pauses \(visiblePercentAtPauses)%)
          useful \(usefulPercent)% of keys, \(usefulOfVisiblePercent)% of visible; \
        mean matched chars when visible \(meanMatchedCharactersWhenVisible)
          key->visible p50 \(ms(medianKeyToVisibleMilliseconds)) p90 \(ms(p90KeyToVisibleMilliseconds)); \
        fresh p50 \(ms(medianFreshKeyToVisibleMilliseconds)) p90 \(ms(p90FreshKeyToVisibleMilliseconds))
          ghosts killed by a keystroke \(ghostsKilledByKeystroke) (not back by next key \(ghostsKilledAndNotBackByNextKey)); \
        corrections offered \(correctionsOffered); silent auto-fixes \(silentAutoFixes.count) \(silentAutoFixes)
          requests \(requestCount) (completed \(completedRequests), cancelled \(cancelledRequests), \
        completed p50 \(ms(medianCompletedRequestMilliseconds))); engine suppressions \(engineSuppressions)
          not visible: \(reasons)
        """
    }
}
#endif
