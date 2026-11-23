import XCTest
@testable import NotesCore

final class TopicTreeTests: XCTestCase {

    func testAFlatVaultIsStillFlat() {
        let tree = TopicTree.build(counts: ["Cooking": 3, "Gaming": 2])
        XCTAssertEqual(tree.map(\.name), ["Cooking", "Gaming"])
        XCTAssertEqual(tree.map(\.total), [3, 2])
        XCTAssertTrue(tree.allSatisfy { $0.children.isEmpty })
    }

    /// The bug this exists for: "Gaming/Video Games" used to be a second
    /// top-level row called "Video Games", with Gaming's badge ignoring it.
    func testANestedCollectionHangsOffItsParent() {
        let tree = TopicTree.build(counts: ["Gaming": 2, "Gaming/Video Games": 3])
        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].name, "Gaming")
        XCTAssertEqual(tree[0].own, 2)
        XCTAssertEqual(tree[0].total, 5)
        XCTAssertEqual(tree[0].children.map(\.name), ["Video Games"])
        XCTAssertEqual(tree[0].children[0].path, "Gaming/Video Games")
        XCTAssertEqual(tree[0].children[0].total, 3)
    }

    /// A child can outlive the notes in its parent, and the row still has to
    /// hang from something.
    func testAParentWithNoNotesOfItsOwnStillAppears() {
        let tree = TopicTree.build(counts: ["Gaming/Video Games": 3])
        XCTAssertEqual(tree.map(\.name), ["Gaming"])
        XCTAssertEqual(tree[0].own, 0)
        XCTAssertEqual(tree[0].total, 3)
        XCTAssertEqual(tree[0].children.map(\.name), ["Video Games"])
    }

    func testTotalsAddUpThroughThreeLevels() {
        let tree = TopicTree.build(counts: [
            "Work": 1,
            "Work/Clients": 2,
            "Work/Clients/Acme": 4,
            "Work/Admin": 3
        ])
        XCTAssertEqual(tree.count, 1)
        let work = tree[0]
        XCTAssertEqual(work.own, 1)
        XCTAssertEqual(work.total, 10)
        XCTAssertEqual(work.children.map(\.name), ["Admin", "Clients"])
        let clients = work.children[1]
        XCTAssertEqual(clients.own, 2)
        XCTAssertEqual(clients.total, 6)
        XCTAssertEqual(clients.children[0].path, "Work/Clients/Acme")
    }

    /// Nothing may be counted twice: the badge is the number people check.
    func testEveryNoteIsCountedExactlyOnce() {
        let counts = ["A": 2, "A/B": 3, "A/B/C": 1, "D": 5, "E/F": 4]
        let tree = TopicTree.build(counts: counts)
        XCTAssertEqual(
            tree.reduce(0) { $0 + $1.total },
            counts.values.reduce(0, +)
        )
    }

    func testEmptyInEmptyOut() {
        XCTAssertTrue(TopicTree.build(counts: [:]).isEmpty)
    }

    /// A path written with a stray slash is the same collection, not a blank
    /// row hanging under it.
    func testStraySlashesAreIgnored() {
        let tree = TopicTree.build(counts: ["Gaming/": 2, "/Cooking": 1])
        XCTAssertEqual(tree.map(\.name), ["Cooking", "Gaming"])
        XCTAssertTrue(tree.allSatisfy { $0.children.isEmpty })
    }

    func testSortingIsAlphabeticalAtEveryLevel() {
        let tree = TopicTree.build(counts: ["B": 1, "A": 1, "A/z": 1, "A/a": 1])
        XCTAssertEqual(tree.map(\.name), ["A", "B"])
        XCTAssertEqual(tree[0].children.map(\.name), ["a", "z"])
    }
}
