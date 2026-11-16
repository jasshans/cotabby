import XCTest
@testable import Ghostype

final class UserSnippetTests: XCTestCase {
    func test_normalizeValidatesAndDeduplicatesTriggers() {
        let snippets = UserSnippetCatalog.normalize([
            UserSnippet(trigger: " /Email ", expansion: "  hello\nthere  "),
            UserSnippet(trigger: "email", expansion: "replacement"),
            UserSnippet(trigger: "2bad", expansion: "invalid trigger"),
            UserSnippet(trigger: "empty", expansion: "  ")
        ])

        XCTAssertEqual(snippets, [UserSnippet(trigger: "email", expansion: "hello\nthere")])
    }

    func test_evaluatorMatchesCaseInsensitivelyAndKeepsExactInsertionText() {
        let expansion = "Hello,\nthere!"
        let evaluator = SnippetMacroEvaluator {
            [UserSnippet(trigger: "greet", expansion: expansion)]
        }

        let result = evaluator.evaluate("GREET")

        XCTAssertEqual(result?.previewText, "Hello, there!")
        XCTAssertEqual(result?.insertionText, expansion)
    }
}
