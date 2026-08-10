import XCTest
@testable import Bilakh

final class MascotTests: XCTestCase {
    func testDefaultEmojiIsMiddleFinger() {
        XCTAssertEqual(EmojiMascot.defaultValue, "🖕🏻")
    }

    func testEmptyEmojiResolvesToDefault() {
        XCTAssertEqual(EmojiMascot.resolved(from: ""), EmojiMascot.defaultValue)
        XCTAssertEqual(EmojiMascot.resolved(from: "😈"), "😈")
    }

    func testSuggestionsAreNonEmpty() {
        XCTAssertFalse(EmojiMascot.suggestions.isEmpty)
    }
}
