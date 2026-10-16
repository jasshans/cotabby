import XCTest
@testable import Ghostype

/// Tests for the shared per-app tone mapping. Both prompt renderers derive tone from
/// this one mapping, so these tests lock the app → tone contract for both engines.
final class AppToneHintTests: XCTestCase {

    func test_instruction_mailIsProfessional() {
        let hint = AppToneHint.instruction(forBundleIdentifier: "com.apple.mail")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("professional") ?? false)
    }

    func test_instruction_slackIsFriendlyProfessional() {
        let hint = AppToneHint.instruction(forBundleIdentifier: "com.tinyspeck.slackmacgap")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("Slack") ?? false)
    }

    func test_instruction_discordIsCasual() {
        let hint = AppToneHint.instruction(forBundleIdentifier: "com.hnc.discord")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("informal") ?? false)
    }

    func test_instruction_messagingIsShort() {
        let hint = AppToneHint.instruction(forBundleIdentifier: "net.whatsapp.whatsapp")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("short") ?? false)
    }

    func test_instruction_terminalIsNil() {
        // Terminals get no tone hint — a shell prompt is mostly prose, not code.
        XCTAssertNil(AppToneHint.instruction(forBundleIdentifier: "com.apple.Terminal"))
    }

    func test_description_mailIsDescriptiveNotImperative() {
        // Base models condition on description, they do not obey commands. The
        // description must not contain imperative verbs like "Match" or "Keep".
        let description = AppToneHint.description(forBundleIdentifier: "com.apple.mail")
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("email") ?? false)
        XCTAssertFalse(description?.contains("Match") ?? true)
        XCTAssertFalse(description?.contains("Keep") ?? true)
    }

    func test_description_slackIsDescriptive() {
        let description = AppToneHint.description(forBundleIdentifier: "com.tinyspeck.slackmacgap")
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Slack") ?? false)
    }

    func test_description_terminalIsNil() {
        XCTAssertNil(AppToneHint.description(forBundleIdentifier: "com.apple.Terminal"))
    }

    func test_bothVariantsAgreeOnAppCategory() {
        // The instruction and description for the same app should describe the
        // same situation, even in different shapes.
        let instruction = AppToneHint.instruction(forBundleIdentifier: "com.apple.mail")
        let description = AppToneHint.description(forBundleIdentifier: "com.apple.mail")
        XCTAssertNotNil(instruction)
        XCTAssertNotNil(description)
        XCTAssertTrue(instruction?.contains("email") ?? false)
        XCTAssertTrue(description?.contains("email") ?? false)
    }
}
