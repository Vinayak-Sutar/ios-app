import XCTest
@testable import NotesCore

/// What happens when a value contains something the format cannot hold.
///
/// The Markdown file is the truth and the index is a cache, so a codec that
/// mangles a value loses a note rather than inconveniencing a query. A title
/// arrives from a paste or from a model, so none of these inputs is exotic.
final class FrontmatterEscapingTests: XCTestCase {

    private func roundTrip(_ note: Note) -> Note {
        FrontmatterCodec.load(FrontmatterCodec.render(note))
    }

    // MARK: - The one that truncated notes

    func testAMultiLineTitleSurvives() {
        let note = Note(title: "first line\nsecond line", body: "the body")
        let back = roundTrip(note)
        XCTAssertEqual(back.title, "first line\nsecond line")
        XCTAssertEqual(back.body, "the body")
    }

    /// The worst case: a stray line that happens to be the closing marker
    /// moved the end of the frontmatter, and everything the user wrote after
    /// it was read as metadata and dropped.
    func testATitleContainingTheMarkerDoesNotEatTheBody() {
        let note = Note(title: "about\n---\nnothing: here", body: "the body I wrote")
        let back = roundTrip(note)
        XCTAssertEqual(back.body, "the body I wrote")
        XCTAssertEqual(back.title, "about\n---\nnothing: here")
    }

    func testTheRenderedFrontmatterStaysThreeLinesPlusItsFields() {
        let rendered = FrontmatterCodec.render(Note(title: "a\nb", body: "x"))
        // Exactly two markers: a newline inside a value must not add one.
        XCTAssertEqual(rendered.components(separatedBy: "\n").filter { $0 == "---" }.count, 2)
    }

    // MARK: - Escapes that must not eat each other

    func testABackslashSurvives() {
        XCTAssertEqual(roundTrip(Note(title: "C:\\Users\\me", body: "x")).title, "C:\\Users\\me")
    }

    /// A literal backslash followed by an n is not a newline. Unescaping with
    /// sequential replacements turns one into the other, whichever order you
    /// pick.
    func testALiteralBackslashNIsNotANewline() {
        let title = "a\\nb"
        let back = roundTrip(Note(title: title, body: "x"))
        XCTAssertEqual(back.title, title)
        XCTAssertFalse(back.title.contains("\n"))
    }

    func testATabSurvives() {
        XCTAssertEqual(roundTrip(Note(title: "before\tafter", body: "x")).title, "before\tafter")
    }

    func testQuotesStillSurvive() {
        XCTAssertEqual(roundTrip(Note(title: "she said \"no\"", body: "x")).title, "she said \"no\"")
    }

    /// Swift reads CRLF as a single Character, so escaping per Character would
    /// miss it entirely — the same trap that once made every note written on
    /// Windows parse as a bodyless blob.
    func testCarriageReturnsAreEscapedTooRatherThanSplittingTheLine() {
        let rendered = FrontmatterCodec.render(Note(title: "a\r\nb", body: "x"))
        let titleLines = rendered
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("title:") }
        XCTAssertEqual(titleLines.count, 1, rendered)
        XCTAssertEqual(FrontmatterCodec.load(rendered).title, "a\r\nb")
    }

    func testAnUnknownEscapeIsLeftAlone() {
        XCTAssertEqual(FrontmatterCodec.unescape("a\\qb"), "a\\qb")
    }

    func testATrailingBackslashIsNotDropped() {
        XCTAssertEqual(FrontmatterCodec.unescape("ends with\\"), "ends with\\")
    }

    // MARK: - Values YAML would act on

    /// The Python vault reads these files with a real YAML parser, which treats
    /// a leading `|`, `&`, `*` or `!` as an instruction rather than as text.
    func testLeadingIndicatorsAreQuoted() {
        for title in ["| pipe", "> quote", "& anchor", "* alias", "! tag", "- dash", "@ at", "% directive"] {
            let rendered = FrontmatterCodec.render(Note(title: title, body: "x"))
            XCTAssertTrue(
                rendered.contains("title: \"\(title)\""),
                "did not quote \(title): \(rendered.components(separatedBy: "\n")[2])"
            )
            XCTAssertEqual(FrontmatterCodec.load(rendered).title, title)
        }
    }

    func testOrdinaryTitlesAreStillWrittenPlainly() {
        let rendered = FrontmatterCodec.render(Note(title: "Sourdough timings", body: "x"))
        XCTAssertTrue(rendered.contains("title: Sourdough timings"), rendered)
    }

    // MARK: - Lists

    func testACollectionNameWithAwkwardCharactersSurvivesTheFlowList() {
        var note = Note(title: "t", body: "b")
        note.topics = ["Food, drink", "Tabs\there"]
        let back = roundTrip(note)
        XCTAssertEqual(back.topics, ["Food, drink", "Tabs\there"])
    }
}
