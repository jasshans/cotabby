import XCTest
@testable import Ghostype

/// Tests for the burst-scoped prompt-head freeze: preface bytes must stay stable
/// across keystrokes so the llama KV prefix hint survives.
final class PromptHeadBurstCacheTests: XCTestCase {
    private let head = PromptHeadBurstCache.Head(examples: ["a"], vocabulary: ["b"])
    private let other = PromptHeadBurstCache.Head(examples: ["x"], vocabulary: ["y"])

    func test_emptyCacheReturnsNil() {
        var cache = PromptHeadBurstCache()
        XCTAssertNil(cache.head(for: 1))
    }

    func test_storedHeadReturnedWithinBurst() {
        var cache = PromptHeadBurstCache()
        let now = Date()
        cache.store(head, identityKey: 1, now: now)
        XCTAssertEqual(
            cache.head(for: 1, now: now.addingTimeInterval(1.0)),
            head
        )
    }

    func test_headExpiresAfterBurstWindow() {
        var cache = PromptHeadBurstCache()
        let now = Date()
        cache.store(head, identityKey: 1, now: now)
        XCTAssertNil(
            cache.head(
                for: 1,
                now: now.addingTimeInterval(PromptHeadBurstCache.defaultBurstWindow + 0.1)
            )
        )
    }

    func test_identityChangeInvalidates() {
        var cache = PromptHeadBurstCache()
        let now = Date()
        cache.store(head, identityKey: 1, now: now)
        XCTAssertNil(cache.head(for: 2, now: now))
    }

    func test_hitSlidesWindowForward() {
        var cache = PromptHeadBurstCache()
        let start = Date()
        cache.store(head, identityKey: 1, now: start)
        // Hit at 1.5s slides the window: 1.5 + 2.0 = 3.5s expiry, not 2.0s.
        let t1 = start.addingTimeInterval(1.5)
        XCTAssertEqual(cache.head(for: 1, now: t1), head)
        let t2 = start.addingTimeInterval(3.0)
        XCTAssertEqual(cache.head(for: 1, now: t2), head)
        let t3 = start.addingTimeInterval(5.1)
        XCTAssertNil(cache.head(for: 1, now: t3))
    }

    func test_storeOverwrites() {
        var cache = PromptHeadBurstCache()
        let now = Date()
        cache.store(head, identityKey: 1, now: now)
        cache.store(other, identityKey: 1, now: now)
        XCTAssertEqual(cache.head(for: 1, now: now), other)
    }

    func test_invalidateClears() {
        var cache = PromptHeadBurstCache()
        let now = Date()
        cache.store(head, identityKey: 1, now: now)
        cache.invalidate()
        XCTAssertNil(cache.head(for: 1, now: now))
    }
}
