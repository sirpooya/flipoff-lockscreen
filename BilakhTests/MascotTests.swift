import XCTest
@testable import Bilakh

final class MascotTests: XCTestCase {
    func testDefaultMascotIsEmoji() {
        XCTAssertEqual(Mascot.defaultValue, Mascot.emoji.rawValue)
    }

    func testMascotAssetNames() {
        XCTAssertEqual(Mascot.dog.assetName, "Mascot")
        XCTAssertEqual(Mascot.cat.assetName, "MascotCat")
        XCTAssertEqual(Mascot.emoji.assetName, "")
    }

    func testResolvedMascotFallsBackToDog() {
        XCTAssertEqual(Mascot.resolved(from: "cat"), .cat)
        XCTAssertEqual(Mascot.resolved(from: "emoji"), .emoji)
        XCTAssertEqual(Mascot.resolved(from: "unknown"), .dog)
    }

    func testDefaultEmojiIsMiddleFinger() {
        XCTAssertEqual(EmojiMascot.defaultValue, "🖕🏻")
    }

    func testEmptyEmojiResolvesToDefault() {
        XCTAssertEqual(EmojiMascot.resolved(from: ""), EmojiMascot.defaultValue)
        XCTAssertEqual(EmojiMascot.resolved(from: "😈"), "😈")
    }
}
