import XCTest
@testable import Bilakh

final class MascotTests: XCTestCase {
    func testDefaultMascotIsEmoji() {
        XCTAssertEqual(Mascot.defaultValue, Mascot.emoji.rawValue)
    }

    func testMascotAssetNames() {
        XCTAssertEqual(Mascot.finger.assetName, "MascotFinger")
        XCTAssertEqual(Mascot.poop.assetName, "MascotPoop")
        XCTAssertEqual(Mascot.emoji.assetName, "")
    }

    func testResolvedMascotFallsBackToEmoji() {
        XCTAssertEqual(Mascot.resolved(from: "finger"), .finger)
        XCTAssertEqual(Mascot.resolved(from: "poop"), .poop)
        XCTAssertEqual(Mascot.resolved(from: "unknown"), .emoji)
    }

    func testDefaultEmojiIsMiddleFinger() {
        XCTAssertEqual(EmojiMascot.defaultValue, "🖕🏻")
    }

    func testEmptyEmojiResolvesToDefault() {
        XCTAssertEqual(EmojiMascot.resolved(from: ""), EmojiMascot.defaultValue)
        XCTAssertEqual(EmojiMascot.resolved(from: "😈"), "😈")
    }
}
