import XCTest
@testable import NotesCore

/// Parses the real notes copied out of the Windows app's `samples/demo-vault`.
///
/// This is the acceptance test for the codec: these files were written by the
/// Python side, so if they do not read back here the two apps disagree about
/// the format and the vault is not portable after all. Synthetic cases can
/// agree with a wrong implementation; these cannot.
final class GoldenVaultTests: XCTestCase {

    /// Fixtures sit next to this file. Resolved from `#filePath` rather than a
    /// bundle so the test needs no SwiftPM resource plumbing and behaves the
    /// same on Windows and macOS. Paths are never asserted on, only walked.
    static var goldenVaultURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Golden/demo-vault")
    }

    static func markdownFiles() -> [URL] {
        let root = goldenVaultURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" }
            .sorted { $0.path < $1.path }
    }

    func testFixturesArePresent() {
        let files = Self.markdownFiles()
        XCTAssertGreaterThanOrEqual(
            files.count, 10,
            "demo-vault fixtures missing -- re-copy them from the Windows app's samples/demo-vault"
        )
    }

    func testEveryRealNoteParsesWithAnIDAndATitle() throws {
        let files = Self.markdownFiles()
        try XCTSkipIf(files.isEmpty, "no fixtures")

        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let note = FrontmatterCodec.load(text)

            XCTAssertTrue(
                ULID.isValid(note.id),
                "\(url.lastPathComponent): id is not a ULID (\(note.id))"
            )
            XCTAssertFalse(note.title.isEmpty, "\(url.lastPathComponent): lost the title")
            XCTAssertFalse(note.kind.isEmpty, "\(url.lastPathComponent): lost the kind")
            XCTAssertFalse(note.created.isEmpty, "\(url.lastPathComponent): lost created")
        }
    }

    /// Re-rendering a note the Python app wrote must produce the same bytes.
    /// Any drift here means the iOS app would rewrite every file it touched,
    /// turning a diff between the two vaults into noise.
    ///
    /// Newlines are normalised first, and that is not a fudge: the Python app
    /// writes these through `Path.write_text`, which on Windows translates to
    /// CRLF, while this writes raw UTF-8 and so always emits LF. Both sides
    /// read either form, so the content is what has to match.
    func testReRenderingMatchesWhatPythonWrote() throws {
        let files = Self.markdownFiles()
        try XCTSkipIf(files.isEmpty, "no fixtures")

        var mismatches: [String] = []
        for url in files {
            let original = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")
            let rendered = FrontmatterCodec.render(FrontmatterCodec.load(original))
            if rendered != original {
                mismatches.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(mismatches, [], "these notes did not round-trip byte for byte")
    }

    func testTopicsMatchTheFoldersTheNotesLiveIn() throws {
        let files = Self.markdownFiles()
        try XCTSkipIf(files.isEmpty, "no fixtures")

        for url in files {
            let folder = url.deletingLastPathComponent().lastPathComponent
            let note = FrontmatterCodec.load(try String(contentsOf: url, encoding: .utf8))

            if folder == "Inbox" {
                XCTAssertTrue(
                    note.topics.isEmpty,
                    "\(url.lastPathComponent): an Inbox note should have no collection"
                )
            } else {
                XCTAssertEqual(
                    note.primaryTopic.map { Slug.slugify($0) },
                    Slug.slugify(folder),
                    "\(url.lastPathComponent): frontmatter and folder disagree"
                )
            }
        }
    }
}
