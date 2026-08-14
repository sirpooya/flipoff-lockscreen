import XCTest
@testable import FlipOff

final class LockVisualTests: XCTestCase {
    func testEmojiIsTheDefault() {
        // Video mode hides the message and sound rows, so a stored value that
        // fails to parse must not silently switch an existing user over to it.
        XCTAssertEqual(LockVisual.defaultValue, .emoji)
        XCTAssertEqual(LockVisual.resolved(from: nil), .emoji)
        XCTAssertEqual(LockVisual.resolved(from: "nonsense"), .emoji)
    }

    func testResolvesKnownRawValues() {
        XCTAssertEqual(LockVisual.resolved(from: "video"), .video)
        XCTAssertEqual(LockVisual.resolved(from: "emoji"), .emoji)
    }

    func testEmptyVideoPathUsesTheTemplate() {
        XCTAssertEqual(LockVideo.resolvedURL(from: ""), LockVideo.templateURL)
        XCTAssertEqual(LockVideo.displayName(for: ""), LockVideo.templateDisplayName)
        XCTAssertFalse(LockVideo.isMissing(""))
    }

    func testMissingImportFallsBackToTemplateButKeepsItsName() {
        let path = "/nowhere/this-file-does-not-exist.mp4"
        XCTAssertTrue(LockVideo.isMissing(path))
        // Falls back so the lock never plays nothing…
        XCTAssertEqual(LockVideo.resolvedURL(from: path), LockVideo.templateURL)
        // …but Settings still names what was picked, rather than claiming the
        // template is the current choice.
        XCTAssertEqual(LockVideo.displayName(for: path), "this-file-does-not-exist.mp4")
    }

    func testTemplateIsBundled() {
        // Guards the resource actually landing in the app bundle — an .mp4 that
        // silently fails to copy would leave video mode with a black screen.
        XCTAssertNotNil(LockVideo.templateURL, "creepy-face-jump-scare.mp4 is missing from the bundle")
    }

    func testImportCopiesRatherThanReferences() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipoff-test-clip-\(UUID().uuidString).mp4")
        try Data("not really a video".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let importedPath = try LockVideo.importVideo(from: source)
        defer { LockVideo.deleteImport(at: importedPath) }

        XCTAssertNotEqual(importedPath, source.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedPath))

        // The whole point of copying: deleting the original leaves the lock
        // screen's copy intact.
        try FileManager.default.removeItem(at: source)
        XCTAssertFalse(LockVideo.isMissing(importedPath))
    }

    func testImportKeepsTheOriginalNameAndDisambiguatesCollisions() throws {
        let name = "flipoff-test-collide-\(UUID().uuidString.prefix(6))"
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
        try Data("clip one".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        // The dropdown shows these filenames, so the first import keeps its own.
        let first = try LockVideo.importVideo(from: source)
        defer { LockVideo.deleteImport(at: first) }
        XCTAssertEqual(URL(fileURLWithPath: first).lastPathComponent, "\(name).mp4")

        // A second clip with the same name must not clobber the first.
        let second = try LockVideo.importVideo(from: source)
        defer { LockVideo.deleteImport(at: second) }
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first))
        XCTAssertEqual(URL(fileURLWithPath: second).lastPathComponent, "\(name)-2.mp4")
    }

    func testLibraryListsTemplateFirstAndIncludesImports() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("flipoff-test-library-\(UUID().uuidString.prefix(6)).mp4")
        try Data("clip".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let importedPath = try LockVideo.importVideo(from: source)
        defer { LockVideo.deleteImport(at: importedPath) }

        let options = LockVideo.libraryOptions(selecting: importedPath)
        XCTAssertEqual(options.first?.path, "", "the built-in has to lead the menu")
        XCTAssertEqual(options.first?.title, LockVideo.templateDisplayName)
        XCTAssertTrue(options.contains { $0.path == importedPath })
    }

    func testDeletedSelectionStillGetsAMenuRow() {
        // A Picker whose selection matches no tag renders blank — a clip deleted
        // from outside the app must still show up, flagged.
        let ghost = "/nowhere/vanished.mp4"
        let options = LockVideo.libraryOptions(selecting: ghost)
        let row = options.first { $0.path == ghost }
        XCTAssertNotNil(row)
        XCTAssertTrue(row?.title.contains("missing") == true)
    }

    func testTemplateCannotBeDeleted() {
        XCTAssertFalse(LockVideo.deleteImport(at: ""))
    }
}
