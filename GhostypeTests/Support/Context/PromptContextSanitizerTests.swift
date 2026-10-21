import XCTest
@testable import Ghostype

/// Pure-function tests for the clipboard/OCR prompt-context sanitizer. `sanitize` keeps prose and the
/// punctuation facts are written with, dropping terminal and markup shapes; `sanitizeOCR` additionally scores each token and drops
/// lines that are mostly OCR noise. Outputs are asserted exactly because whatever survives is
/// copied verbatim into the prompt.
final class PromptContextSanitizerTests: XCTestCase {

    private func assertSanitizedOCR(
        _ cases: [(input: String, expected: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.sanitizeOCR(testCase.input),
                testCase.expected,
                "input \(testCase.input.debugDescription)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - sanitize

    /// The facts people copy from a screen or clipboard keep their punctuation: a time, a price, a
    /// date, a product code, a contraction, a URL. Before 2026-10-21 everything but letters, digits,
    /// `@` and `.` became a space, so a suggestion copied "6 15 PM" and "don t" into the field.
    func test_sanitize_keepsThePunctuationFactsAreWrittenWith() {
        let cases: [(input: String, expected: String)] = [
            ("Departs 6:15 PM, Gate B22.", "Departs 6:15 PM, Gate B22."),
            ("Total: $1,249.00 (incl. tax)", "Total: $1,249.00 (incl. tax)"),
            ("Due 2024-10-21 — don't forget!", "Due 2024-10-21 — don't forget!"),
            ("Sony WF-1000XM5 & case #2", "Sony WF-1000XM5 & case #2"),
            ("https://zoom.us/j/98234571209", "https://zoom.us/j/98234571209"),
            ("“Quoted,” she said; 50% off?", "“Quoted,” she said; 50% off?"),
            ("東京、大阪。「会議」", "東京、大阪。「会議」")
        ]
        for testCase in cases {
            XCTAssertEqual(PromptContextSanitizer.sanitize(testCase.input), testCase.expected, "input \(testCase.input.debugDescription)")
        }
    }

    /// What the sanitizer exists for: terminal and markup shapes a small model copies back as text.
    /// Code fences, angle/pipe/brace markup, box drawing and divider runs become spaces.
    func test_sanitize_removesTerminalAndMarkupShapes() {
        let cases: [(input: String, expected: String)] = [
            ("```swift\nlet x = 1\n```", "swift\nlet x 1"),
            ("<|im_start|>user", "im_start user"),
            ("──────────\nStatus ═══ OK", "Status OK"),
            ("-----\nNotes\n=====", "Notes"),
            ("[09:27] priya: {ok}", "09:27 priya: ok"),
            ("path\\to\\file | grep x ~ y ^ z", "path to file grep x y z")
        ]
        for testCase in cases {
            XCTAssertEqual(PromptContextSanitizer.sanitize(testCase.input), testCase.expected, "input \(testCase.input.debugDescription)")
        }
    }

    /// Whitespace runs collapse, blank lines disappear, and ANSI escapes are removed whole.
    func test_sanitize_normalizesToPromptSafeText() {
        let cases: [(input: String, expected: String)] = [
            ("raw-output", "raw-output"),
            ("hello    world", "hello world"),
            ("a\t\tb", "a b"),
            ("first\n   \n\nsecond", "first\nsecond"),
            ("one\r\ntwo", "one\ntwo"),
            ("Hello world 123 user@host.com", "Hello world 123 user@host.com"),
            ("\u{001B}[31mERROR\u{001B}[0m something broke", "ERROR something broke"),
            ("\u{001B}[32mHello\u{001B}[0m world", "Hello world"),
            ("   \n  \n  ", ""),
            ("", "")
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.sanitize(testCase.input),
                testCase.expected,
                "input \(testCase.input.debugDescription)"
            )
        }
    }

    /// The bound applies after normalization, and a cut that lands on a space is trimmed.
    func test_sanitize_boundsToMaxCharacters() {
        XCTAssertEqual(PromptContextSanitizer.sanitize("abcdefghij", maxCharacters: 5), "abcde")
        XCTAssertEqual(PromptContextSanitizer.sanitize("hello", maxCharacters: 5), "hello")
        XCTAssertEqual(PromptContextSanitizer.sanitize("hello   world", maxCharacters: 6), "hello")
    }

    // MARK: - sanitizeOCR token scoring

    /// Standalone numbers, unlisted 1-2 letter tokens, repeated glyphs, letterless dotted numbers,
    /// and lowercase-led mixed-case blobs are noise; the rest of the line survives when at least
    /// half its tokens do.
    func test_sanitizeOCR_dropsNoiseTokensFromOtherwiseRealLines() {
        assertSanitizedOCR([
            ("hello 50 world 424", "hello world"),        // exactly half survive: kept
            ("I like if x", "I like if"),                 // "I"/"if" are preserved short words
            ("meeting notes aaaa", "meeting notes"),
            ("meeting notes 12.34", "meeting notes"),
            ("meeting notes abeW", "meeting notes"),
            ("meeting notes swift5 abc123", "meeting notes swift5") // letters+digits need a known word
        ])
    }

    /// Short technical words and uppercase acronyms are strong signal even without vowels.
    func test_sanitizeOCR_keepsTechnicalTokensAcronymsFilesAndEmails() {
        let technical = "Ghostype CoHamster PR API context needs GeneralPaneView.swift "
            + "normalizedBundleIdentifier jane@example.com"
        assertSanitizedOCR([
            (technical, technical),
            ("CPU ui ok", "CPU ui")
        ])
    }

    // MARK: - sanitizeOCR line filtering

    /// A line is dropped whole when more than half its tokens are noise, or when every survivor is
    /// a weak short word (UI chrome like "we go to it").
    func test_sanitizeOCR_dropsNoiseDominatedAndWeakOnlyLines() {
        assertSanitizedOCR([
            ("50 x 99 hello", ""),
            ("50 424 102 99", ""),
            ("gLVWrt 54tbdbDX bDokE User", ""),
            ("we go to it", ""),
            ("*** ---", ""),   // sanitizes to one empty line: no tokens, no crash
            ("", "")
        ])
    }

    func test_sanitizeOCR_dropsGarbageLineButKeepsRealLine() {
        let input = """
        gLVWrt bDokE 54tbdbDX
        Visible task update Screen Recording copy for Ghostype
        """
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR(input),
            "Visible task update Screen Recording copy for Ghostype"
        )
    }

    /// CJK, Cyrillic, and accented Latin carry real context but have no ASCII vowel and never match
    /// the English word lists; they must survive so non-English users keep visual context. The
    /// allowance must not become a backdoor for ASCII garbage (or unlisted short Latin words like
    /// "la") on the same line.
    func test_sanitizeOCR_preservesNonLatinScriptsWithoutAdmittingAsciiNoise() {
        let input = """
        会議の議題を確認してください
        Привет команда смотрите задачу
        Préparez la réunion à Zürich
        """
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR(input),
            "会議の議題を確認してください\nПривет команда смотрите задачу\nPréparez réunion à Zürich"
        )
        XCTAssertEqual(PromptContextSanitizer.sanitizeOCR("東京 gLVWrt オフィス 54tbdbDX"), "東京 オフィス")
    }

    /// The OCR bound applies to the filtered, joined text, then trims a trailing cut space.
    func test_sanitizeOCR_boundsToMaxCharacters() {
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("alpha beta gamma delta epsilon", maxCharacters: 10),
            "alpha beta"
        )
        XCTAssertEqual(
            PromptContextSanitizer.sanitizeOCR("50 424\nalpha beta gamma", maxCharacters: 11),
            "alpha beta"
        )
    }

    // MARK: - significantTokens

    /// Lowercased tokens split on any non-alphanumeric boundary, deduplicated, and length-filtered.
    func test_significantTokens_splitsLowercasesAndFiltersByLength() {
        XCTAssertEqual(
            PromptContextSanitizer.significantTokens(from: "Hello, hello WORLD! swift-ui an"),
            ["hello", "world", "swift"]
        )
        XCTAssertEqual(
            PromptContextSanitizer.significantTokens(from: "an ox ran far", minimumLength: 2),
            ["an", "ox", "ran", "far"]
        )
        XCTAssertEqual(PromptContextSanitizer.significantTokens(from: "--- ,,,"), [])
    }

    // MARK: - containsAlphanumericSignal

    func test_containsAlphanumericSignal() {
        let cases: [(text: String, expected: Bool)] = [
            ("---a---", true),
            ("--- 7", true),
            ("東", true),
            ("--- ---", false),
            ("", false)
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.containsAlphanumericSignal(testCase.text),
                testCase.expected,
                "text \(testCase.text.debugDescription)"
            )
        }
    }

    // MARK: - looksLikeCredential

    func test_looksLikeCredential() {
        let cases: [(text: String, expected: Bool)] = [
            // Password-shaped: single token, 8+ chars, 3+ character classes.
            ("Tr0ub4dor&3", true),
            ("Kx7!mQ2#zR9p", true),
            ("sk-live-a1B2c3D4e5", true),
            ("  Tr0ub4dor&3\n", true), // surrounding whitespace is trimmed
            // Not credentials: too short, has whitespace, or too few classes.
            ("shor1A!", false), // 7 chars
            ("correct horse battery staple", false), // whitespace
            ("https://example.com/some/path", false), // URL: two classes
            ("user@example.com", false), // email: two classes
            ("hello", false), // one class
            ("DE89370400440532013000", false), // IBAN: two classes (handled by the scrubber)
            ("Rindfleischetikettierungsüberwachungsaufgaben", false), // long single-class word
            ("", false)
        ]
        for testCase in cases {
            XCTAssertEqual(
                PromptContextSanitizer.looksLikeCredential(testCase.text),
                testCase.expected,
                "text \(testCase.text.debugDescription)"
            )
        }
    }
}
