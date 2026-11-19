import XCTest
@testable import NotesCore

/// The frontmatter codec is the one place a bug loses a note rather than
/// breaking a query, so these are the tests worth having before anything else.
/// They mirror `tests/test_core.py`'s vault cases.
final class FrontmatterTests: XCTestCase {

    func testRoundTripPreservesEveryField() {
        let note = Note(
            id: "01M1M1302B6TXC84AMG9DETTN7",
            title: "Malenia waterfowl timing",
            body: "Bloodhound step on the second swing.\n\nSecond paragraph.",
            kind: "note",
            status: "open",
            topics: ["Gaming/Elden Ring"],
            entities: ["malenia"],
            tags: ["souls"],
            source: "https://example.com/a?b=1",
            media: ".mnemo/media/abc123.png",
            due: "2026-11-15T18:00:00",
            remind: "2026-11-15T17:00:00",
            repeatRule: "weekly",
            checkin: "09:00",
            quietUntil: "2026-11-20T00:00:00",
            parent: "01M1M1302B6TXC84AMG9DETTN8",
            order: 1.5,
            created: "2026-09-03T16:19:32Z",
            updated: "2026-11-02T18:40:33Z"
        )

        let rendered = FrontmatterCodec.render(note)
        let reloaded = FrontmatterCodec.load(rendered)

        XCTAssertEqual(reloaded, note)
    }

    func testRenderedShapeMatchesThePythonVault() {
        let note = Note(
            id: "01M1M1302B6TXC84AMG9DETTN7",
            title: "rag chunking with 200 token overlap",
            body: "rag chunking with 200 token overlap",
            topics: ["technology"],
            created: "2026-09-03T16:19:32Z",
            updated: "2026-09-03T16:19:32Z"
        )

        let expected = """
        ---
        id: 01M1M1302B6TXC84AMG9DETTN7
        title: rag chunking with 200 token overlap
        kind: note
        status: open
        topics: [technology]
        entities: []
        tags: []
        created: 2026-09-03T16:19:32Z
        updated: 2026-09-03T16:19:32Z
        ---

        rag chunking with 200 token overlap

        """

        XCTAssertEqual(FrontmatterCodec.render(note), expected)
    }

    /// A title with a colon is the single most likely thing to corrupt a
    /// hand-rolled codec, and exactly why a real YAML parser is not used here.
    func testTitlesThatWouldBreakNaiveYAMLSurvive() {
        let awkward = [
            "Meeting: notes",
            "a, b, c",
            "[bracketed]",
            "{braced}",
            "# not a heading",
            "it\u{27}s fine",
            "quote \" inside",
            "back\\slash",
            "  leading and trailing  ",
            "",
            "no",
            "true",
            "false",
            "1.0",
            "0123456789"
        ]

        for title in awkward {
            let note = Note(id: "01M1M1302B6TXC84AMG9DETTN7", title: title, topics: ["Inbox"])
            let reloaded = FrontmatterCodec.load(FrontmatterCodec.render(note))
            XCTAssertEqual(reloaded.title, title, "title did not survive: \(title.debugDescription)")
        }
    }

    /// A known limitation, pinned rather than hidden: the bare words `null` and
    /// `~` mean "no value", so a note titled exactly that comes back empty.
    ///
    /// The Python app loses them in the same way, and matching it is worth more
    /// than rescuing a title nobody will ever type — quoting these on the way
    /// out would make every file we write differ from the ones it writes.
    func testNullAndTildeTitlesAreLostJustAsPythonLosesThem() {
        for title in ["null", "~"] {
            let note = Note(id: "01M1M1302B6TXC84AMG9DETTN7", title: title)
            XCTAssertEqual(FrontmatterCodec.load(FrontmatterCodec.render(note)).title, "")
        }
    }

    func testFlowListKeepsCommasInsideQuotes() {
        let note = Note(
            id: "01M1M1302B6TXC84AMG9DETTN7",
            title: "t",
            topics: ["Work/Q4, planning", "Ideas"]
        )
        let reloaded = FrontmatterCodec.load(FrontmatterCodec.render(note))
        XCTAssertEqual(reloaded.topics, ["Work/Q4, planning", "Ideas"])
    }

    /// Git on Windows will hand us CRLF files sooner or later, and a note
    /// edited in the Files app may arrive either way.
    func testParseToleratesCRLF() {
        let text = "---\r\nid: 01M1M1302B6TXC84AMG9DETTN7\r\ntitle: hello\r\ntopics: [Work]\r\n---\r\nbody line\r\n"
        let note = FrontmatterCodec.load(text)
        XCTAssertEqual(note.id, "01M1M1302B6TXC84AMG9DETTN7")
        XCTAssertEqual(note.title, "hello")
        XCTAssertEqual(note.topics, ["Work"])
        XCTAssertEqual(note.body, "body line")
    }

    /// Someone can create a plain .md file in the Files app. It should read as
    /// a note with a generated id rather than being skipped.
    func testFileWithNoFrontmatterBecomesABody() {
        let note = FrontmatterCodec.load("just some text\nand more")
        XCTAssertEqual(note.body, "just some text\nand more")
        XCTAssertTrue(ULID.isValid(note.id))
        XCTAssertEqual(note.topics, [])
    }

    func testUnterminatedFrontmatterIsTreatedAsBodyNotSwallowed() {
        let text = "---\nid: x\ntitle: y\n"
        let (fm, body) = FrontmatterCodec.parse(text)
        XCTAssertTrue(fm.scalars.isEmpty)
        XCTAssertEqual(body, text)
    }

    func testEmptyOptionalFieldsAreOmitted() {
        let note = Note(id: "01M1M1302B6TXC84AMG9DETTN7", title: "t", due: "", remind: nil)
        let rendered = FrontmatterCodec.render(note)
        XCTAssertFalse(rendered.contains("due:"))
        XCTAssertFalse(rendered.contains("remind:"))
        XCTAssertFalse(rendered.contains("order:"))
    }

    func testOrderFormatsWithoutTrailingZeros() {
        XCTAssertEqual(FrontmatterCodec.emitOrder(1.5), "1.5")
        XCTAssertEqual(FrontmatterCodec.emitOrder(2), "2")
        XCTAssertEqual(FrontmatterCodec.emitOrder(0.000001), "0.000001")
        XCTAssertEqual(FrontmatterCodec.emitOrder(0), "0")
    }

    func testBodyWithTrailingBlankLinesIsNormalised() {
        let note = Note(id: "01M1M1302B6TXC84AMG9DETTN7", title: "t", body: "text\n\n\n")
        let reloaded = FrontmatterCodec.load(FrontmatterCodec.render(note))
        XCTAssertEqual(reloaded.body, "text")
    }

    func testEmbeddingTextMatchesThePythonForm() {
        let note = Note(title: "Title", body: "Body")
        XCTAssertEqual(note.embeddingText, "Title\nBody")
        XCTAssertEqual(Note(title: "", body: "Body").embeddingText, "Body")
    }
}
