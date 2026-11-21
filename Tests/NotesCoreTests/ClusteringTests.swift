import XCTest
@testable import NotesCore

final class SeededRandomTests: XCTestCase {

    /// The whole reason this exists: Swift's default generator is seeded per
    /// process, so identical notes would produce a different taxonomy on every
    /// launch — and no test of clustering would mean anything.
    func testSameSeedGivesSameSequence() {
        var a = SeededRandom(seed: 42)
        var b = SeededRandom(seed: 42)
        for _ in 0..<50 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiverge() {
        var a = SeededRandom(seed: 1)
        var b = SeededRandom(seed: 2)
        let left = (0..<10).map { _ in a.next() }
        let right = (0..<10).map { _ in b.next() }
        XCTAssertNotEqual(left, right)
    }
}

final class ClusteringTests: XCTestCase {

    /// Three clearly separated groups in a plane, with small jitter.
    func threeGroups() -> [[Float]] {
        var out: [[Float]] = []
        for offset in [Float(0.0), 0.02, -0.02, 0.01] {
            out.append(Vectors.l2Normalise([1, offset, 0]))
        }
        for offset in [Float(0.0), 0.02, -0.02, 0.01] {
            out.append(Vectors.l2Normalise([0, 1, offset]))
        }
        for offset in [Float(0.0), 0.02, -0.02, 0.01] {
            out.append(Vectors.l2Normalise([offset, 0, 1]))
        }
        return out
    }

    func testFindsTheGroupsThatAreThere() {
        let clusters = Clustering.cluster(threeGroups(), k: 3)
        XCTAssertEqual(clusters.count, 3)

        // Every member of a cluster should come from the same block of four.
        for cluster in clusters {
            let blocks = Set(cluster.members.map { $0 / 4 })
            XCTAssertEqual(blocks.count, 1, "cluster mixed groups: \(cluster.members)")
        }
    }

    func testEveryNoteEndsInExactlyOneCluster() {
        let clusters = Clustering.cluster(threeGroups(), k: 3)
        let assigned = clusters.flatMap(\.members).sorted()
        XCTAssertEqual(assigned, Array(0..<12))
    }

    func testClustersComeBackBiggestFirst() {
        var vectors = threeGroups()
        vectors.append(Vectors.l2Normalise([1, 0.01, 0]))   // a fourth in group 0
        let clusters = Clustering.cluster(vectors, k: 3)
        let sizes = clusters.map(\.members.count)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
    }

    func testIsReproducible() {
        let first = Clustering.cluster(threeGroups(), k: 3, seed: 7).map(\.members)
        let second = Clustering.cluster(threeGroups(), k: 3, seed: 7).map(\.members)
        XCTAssertEqual(first, second)
    }

    func testDegenerateInputReturnsNothing() {
        XCTAssertTrue(Clustering.cluster([], k: 3).isEmpty)
        XCTAssertTrue(Clustering.cluster(threeGroups(), k: 0).isEmpty)
        XCTAssertTrue(Clustering.cluster([[1, 0]], k: 3).isEmpty, "fewer notes than clusters")
    }

    func testMismatchedDimensionsAreIgnoredNotCrashed() {
        var vectors = threeGroups()
        vectors.append([1, 0])            // a stale vector from another embedder
        let clusters = Clustering.cluster(vectors, k: 3)
        XCTAssertFalse(clusters.flatMap(\.members).contains(12))
    }

    // MARK: - chooseK

    /// A cluster of one is not a subject, it is a note — and a taxonomy of
    /// singletons is exactly the sprawl the gate exists to prevent.
    func testChooseKRespectsMinimumClusterSize() {
        XCTAssertEqual(Clustering.chooseK(count: 20, minCluster: 3), 6)
        XCTAssertEqual(Clustering.chooseK(count: 6, minCluster: 3), 2, "exactly enough for two")
        XCTAssertEqual(Clustering.chooseK(count: 5, minCluster: 3), 0, "five notes cannot make two groups of three")
        XCTAssertEqual(Clustering.chooseK(count: 100, maxK: 12, minCluster: 3), 12, "capped")
    }

    func testChooseKRefusesTooFewNotes() {
        XCTAssertEqual(Clustering.chooseK(count: 3, minK: 2, minCluster: 3), 0)
        XCTAssertEqual(Clustering.chooseK(count: 0), 0)
    }

    // MARK: - Naming

    /// Document frequency, not raw count. A word in four notes of five
    /// describes the group; a word forty times in one note describes that
    /// note — which is how you end up with "Banneton Proofing" instead of
    /// "Sourdough".
    func testNamesFromWordsTheNotesShare() {
        let texts = [
            "sourdough starter doubled overnight",
            "sourdough loaf came out dense",
            "the sourdough crust was better this time",
            "banneton banneton banneton banneton proofing basket for sourdough"
        ]
        let name = Clustering.name(from: texts)
        XCTAssertEqual(name?.lowercased().contains("sourdough"), true, "got \(name ?? "nil")")
        XCTAssertNotEqual(name?.lowercased(), "banneton", "one note's vocabulary won")
    }

    func testReturnsNothingWhenNotesShareNothing() {
        let texts = ["completely unrelated alpha", "nothing similar beta", "different again gamma"]
        XCTAssertNil(Clustering.name(from: texts))
    }

    func testIgnoresCommonWords() {
        let texts = [
            "this is about the thing that you have",
            "this is about the thing that you have",
            "this is about the thing that you have"
        ]
        // Every word is either a stopword or too short to name anything.
        XCTAssertNil(Clustering.name(from: texts))
    }

    func testAvoidsReusingANameThatExists() {
        let texts = [
            "elden ring malenia waterfowl",
            "elden ring malenia build",
            "elden ring malenia summons"
        ]
        let name = Clustering.name(from: texts, existing: ["Elden Ring"])
        if let name {
            XCTAssertNotEqual(NormKey.key(name), NormKey.key("Elden Ring"))
        }
    }

    func testNamesAreCapitalised() {
        let texts = ["gaming hardware notes", "gaming hardware reviews", "gaming hardware prices"]
        let name = Clustering.name(from: texts)
        XCTAssertEqual(name?.first?.isUppercase, true, "got \(name ?? "nil")")
    }

    func testEmptyInputNamesNothing() {
        XCTAssertNil(Clustering.name(from: []))
    }
}
