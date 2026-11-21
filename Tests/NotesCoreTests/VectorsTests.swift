import XCTest
@testable import NotesCore

final class VectorsTests: XCTestCase {

    func testCosineOfIdenticalNormalisedVectorsIsOne() {
        let v = Vectors.l2Normalise([1, 2, 3, 4])
        XCTAssertEqual(Vectors.cosine(v, v), 1.0, accuracy: 1e-6)
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        let a = Vectors.l2Normalise([1, 0])
        let b = Vectors.l2Normalise([0, 1])
        XCTAssertEqual(Vectors.cosine(a, b), 0.0, accuracy: 1e-6)
    }

    func testCosineOfOppositeVectorsIsMinusOne() {
        let a = Vectors.l2Normalise([1, 1])
        let b = Vectors.l2Normalise([-1, -1])
        XCTAssertEqual(Vectors.cosine(a, b), -1.0, accuracy: 1e-6)
    }

    /// A vector left over from a previous embedder revision has a different
    /// dimension. It must score 0, not trap -- capture has to survive it.
    func testDimensionMismatchScoresZeroRatherThanCrashing() {
        XCTAssertEqual(Vectors.cosine([1, 0, 0], [1, 0]), 0)
        XCTAssertEqual(Vectors.cosine([], []), 0)
    }

    func testNormaliseLeavesZeroVectorAlone() {
        XCTAssertEqual(Vectors.l2Normalise([0, 0, 0]), [0, 0, 0])
    }

    func testNormalisedVectorHasUnitLength() {
        let v = Vectors.l2Normalise([3, 4])
        XCTAssertEqual(Double(v[0]), 0.6, accuracy: 1e-6)
        XCTAssertEqual(Double(v[1]), 0.8, accuracy: 1e-6)
    }

    func testMeanIsNormalisedAndIgnoresMismatchedVectors() {
        let mean = Vectors.mean([[1, 0], [0, 1], [1, 2, 3]])
        XCTAssertEqual(mean.count, 2)
        XCTAssertEqual(Vectors.cosine(mean, mean), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Double(mean[0]), Double(mean[1]), accuracy: 1e-6)
    }

    func testMeanOfNothingIsEmpty() {
        XCTAssertEqual(Vectors.mean([]), [])
    }

    /// The pooling scheme leans on the first window, which holds the title and
    /// the opening of the body -- where nearly all the topical signal is.
    func testWeightedMeanFavoursEarlierWindows() {
        let first = Vectors.l2Normalise([1, 0])
        let second = Vectors.l2Normalise([0, 1])
        let pooled = Vectors.weightedMean([first, second], weights: [0.75, 0.25])
        XCTAssertGreaterThan(Vectors.cosine(pooled, first), Vectors.cosine(pooled, second))
    }

    func testFoldIntoCentroidMovesTowardTheNewMember() {
        let centroid = Vectors.l2Normalise([1, 0])
        let newcomer = Vectors.l2Normalise([0, 1])
        let folded = Vectors.foldIntoCentroid(centroid, count: 1, adding: newcomer)
        XCTAssertEqual(Double(folded[0]), Double(folded[1]), accuracy: 1e-6)
    }

    func testFoldIntoEmptyCentroidAdoptsTheMember() {
        let newcomer = Vectors.l2Normalise([0, 3, 4])
        let folded = Vectors.foldIntoCentroid([], count: 0, adding: newcomer)
        XCTAssertEqual(Vectors.cosine(folded, newcomer), 1.0, accuracy: 1e-6)
    }

    /// A large collection should barely move for one new note; a small one
    /// should move a lot. That asymmetry is what makes centroids stable.
    func testBigCentroidsMoveLessThanSmallOnes() {
        let centroid = Vectors.l2Normalise([1, 0])
        let newcomer = Vectors.l2Normalise([0, 1])
        let small = Vectors.foldIntoCentroid(centroid, count: 2, adding: newcomer)
        let large = Vectors.foldIntoCentroid(centroid, count: 100, adding: newcomer)
        XCTAssertGreaterThan(Vectors.cosine(large, centroid), Vectors.cosine(small, centroid))
    }

    func testTopKIsSortedHighestFirstAndTruncated() {
        let query = Vectors.l2Normalise([1, 0])
        let candidates: [(id: String, vector: [Float])] = [
            ("far", Vectors.l2Normalise([0, 1])),
            ("near", Vectors.l2Normalise([1, 0.1])),
            ("mid", Vectors.l2Normalise([1, 1])),
            ("wrongdim", [1, 0, 0])
        ]
        let hits = Vectors.topK(query: query, candidates: candidates, k: 2)
        XCTAssertEqual(hits.map { $0.id }, ["near", "mid"])
        XCTAssertGreaterThan(hits[0].similarity, hits[1].similarity)
    }

    func testTopKHandlesDegenerateInput() {
        XCTAssertTrue(Vectors.topK(query: [], candidates: [(id: 1, vector: [1.0])], k: 3).isEmpty)
        XCTAssertTrue(Vectors.topK(query: [1.0], candidates: [(id: 1, vector: [1.0])], k: 0).isEmpty)
    }

    // MARK: - Storage

    func testPackUnpackRoundTrip() {
        let v: [Float] = [0, 1, -1, 0.5, -0.25, 3.14159, Float.leastNormalMagnitude]
        XCTAssertEqual(Vectors.unpack(Vectors.pack(v)), v)
    }

    func testPackedLayoutIsFourBytesPerFloatLittleEndian() {
        let data = Vectors.pack([1.0])
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual([UInt8](data), [0x00, 0x00, 0x80, 0x3F])
    }

    func testBase64RoundTripSurvivesTheIndexFile() {
        let v = Vectors.l2Normalise((0..<512).map { Float($0 % 7) - 3 })
        let decoded = Vectors.decodeBase64(Vectors.encodeBase64(v))
        XCTAssertEqual(decoded.count, 512)
        XCTAssertEqual(Vectors.cosine(v, decoded), 1.0, accuracy: 1e-6)
    }

    func testDecodingGarbageYieldsEmptyRatherThanCrashing() {
        XCTAssertEqual(Vectors.decodeBase64("not base64 at all !!"), [])
        XCTAssertEqual(Vectors.unpack(Data([1, 2])), [])
    }
}

/// Centring reclaims the cosine range that a shared mean direction wastes.
///
/// Measured on the device, Apple's embedder scored unrelated notes at 0.840
/// and related ones at 0.896 — a 0.055 gap, with almost the whole range
/// consumed by a component every vector shares.
final class CentringTests: XCTestCase {

    /// Vectors that all lean the same way, with a small distinguishing part.
    func leaning(_ signal: [Float]) -> [Float] {
        var v = [Float](repeating: 0, count: signal.count + 1)
        v[0] = 3.0                                   // the shared component
        for (i, x) in signal.enumerated() { v[i + 1] = x }
        return Vectors.l2Normalise(v)
    }

    func testCentringWidensTheGapBetweenRelatedAndUnrelated() {
        let a1 = leaning([1, 0, 0])
        let a2 = leaning([0.9, 0.1, 0])
        let b1 = leaning([0, 0, 1])

        let rawSame = Vectors.cosine(a1, a2)
        let rawDifferent = Vectors.cosine(a1, b1)
        let rawGap = rawSame - rawDifferent

        let centred = Vectors.centred([a1, a2, b1])
        let centredGap = Vectors.cosine(centred[0], centred[1]) - Vectors.cosine(centred[0], centred[2])

        XCTAssertGreaterThan(centredGap, rawGap, "centring should widen the gap, not narrow it")
    }

    func testCentringLeavesSingleVectorsAlone() {
        let only = [Vectors.l2Normalise([1, 2, 3])]
        XCTAssertEqual(Vectors.centred(only), only)
        XCTAssertEqual(Vectors.centred([]), [])
    }

    func testCentringProducesUnitVectors() {
        let set = [leaning([1, 0, 0]), leaning([0, 1, 0]), leaning([0, 0, 1])]
        for v in Vectors.centred(set) {
            XCTAssertEqual(Vectors.cosine(v, v), 1.0, accuracy: 1e-6)
        }
    }

    /// Centring one vector against a stored mean must match centring the set,
    /// or a note embedded later would live in a different space from the ones
    /// already filed.
    func testSingleVectorCentringMatchesTheSetForm() {
        let set = [leaning([1, 0, 0]), leaning([0, 1, 0]), leaning([0, 0, 1])]
        let mean = Vectors.meanDirection(set)
        let viaSet = Vectors.centred(set)
        for (index, vector) in set.enumerated() {
            let viaMean = Vectors.centred(vector, mean: mean)
            XCTAssertEqual(Vectors.cosine(viaSet[index], viaMean), 1.0, accuracy: 1e-5)
        }
    }

    func testMeanDirectionOfNothingIsEmpty() {
        XCTAssertEqual(Vectors.meanDirection([]), [])
    }
}
