import XCTest
@testable import NotesCore

/// The citation line arrives split at arbitrary points, so these tests run
/// every chunking of the input rather than one convenient one. That is the
/// whole reason this is a state machine and not a `hasSuffix` check.
final class SourcesLineFilterTests: XCTestCase {

    /// Feed `text` in chunks of `size` and return everything released.
    func run(_ text: String, chunk size: Int) -> String {
        var filter = SourcesLineFilter()
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out += filter.push(String(text[index..<end]))
            index = end
        }
        out += filter.finish()
        return out
    }

    /// Every chunk size from one character to the whole string must agree.
    func assertAllChunkings(_ input: String, equals expected: String) {
        for size in 1...max(1, input.count) {
            XCTAssertEqual(
                run(input, chunk: size), expected,
                "disagreed at chunk size \(size)"
            )
        }
    }

    func testPlainAnswerPassesThroughUntouched() {
        assertAllChunkings("You have two films saved.", equals: "You have two films saved.")
    }

    func testMultilineAnswerPassesThrough() {
        let text = "Two films:\n\n- Interstellar\n- Dune"
        assertAllChunkings(text, equals: text)
    }

    func testTrailingCitationLineIsRemoved() {
        assertAllChunkings(
            "You have two films saved.\nSources: 1, 2",
            equals: "You have two films saved.\n"
        )
    }

    func testCitationLineIsRemovedWhateverFollowsTheColon() {
        for tail in ["", " 1", " 1, 2", " none", " 1, W2"] {
            assertAllChunkings("Answer.\nSources:\(tail)", equals: "Answer.\n")
        }
    }

    /// The near miss that a naive check gets wrong: a line that starts with
    /// the same letters but is part of the answer.
    func testWordsThatMerelyLookLikeTheMarkerSurvive() {
        for line in ["Sourdough is proofing.", "So that is two.", "Sorry, nothing saved."] {
            assertAllChunkings("Answer.\n\(line)", equals: "Answer.\n\(line)")
        }
    }

    func testMarkerMidAnswerIsNotRemoved() {
        let text = "Sources: are listed below.\nAnd here they are."
        assertAllChunkings(text, equals: text)
    }

    func testCitationLineIsMatchedCaseInsensitively() {
        assertAllChunkings("Answer.\nsources: 1", equals: "Answer.\n")
        assertAllChunkings("Answer.\nSOURCES: 1", equals: "Answer.\n")
    }

    func testEmptyStreamIsEmpty() {
        var filter = SourcesLineFilter()
        XCTAssertEqual(filter.push(""), "")
        XCTAssertEqual(filter.finish(), "")
    }

    /// An answer that is only a citation line leaves nothing, which is right:
    /// the sources already went out as their own event.
    func testAnswerThatIsNothingButCitationsCollapses() {
        assertAllChunkings("\nSources: 1", equals: "\n")
    }

    func testNothingIsEverLostOrDuplicated() {
        // Property check over a mix of shapes: the output must always be a
        // prefix of the input, since the filter only ever withholds a tail.
        let inputs = [
            "a", "a\nb", "Answer.\nSources: 1", "Sou", "x\nSou",
            "line one\nline two\nSources: 3", "Sources:", "\n\n\n",
            "tokens arrive\nin pieces\nSources: 1, 2, 3"
        ]
        for input in inputs {
            for size in 1...max(1, input.count) {
                let out = run(input, chunk: size)
                XCTAssertTrue(
                    input.hasPrefix(out),
                    "output \(out.debugDescription) is not a prefix of \(input.debugDescription) at size \(size)"
                )
            }
        }
    }

    func testMarkerPrefixDetection() {
        for viable in ["", "S", "So", "Sou", "sourc", "Sources:", "Sources: 1"] {
            XCTAssertTrue(SourcesLineFilter.couldBecomeMarker(viable), viable)
        }
        for notViable in ["Sorry", "X", "Sourdough", "A", "Soup"] {
            XCTAssertFalse(SourcesLineFilter.couldBecomeMarker(notViable), notViable)
        }
    }
}
