import XCTest
@testable import NotesCore

final class VectorsTests: XCTestCase {

    func testCosineOfIdenticalNormalisedVectorsIsOne() {
        let v = Vectors.l2Normalise([1, 2, 3, 4])
        XCTAssertEqual(Vectors.cosine(v, v), 1.0, accuracy: 1e-9)
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        let a = Vectors.l2Normalise([1, 0])
        let b = Vectors.l2Normalise([0, 1])
        XCTAssertEqual(Vectors.cosine(a, b), 0.0, accuracy: 1e-9)
    }

    func testCosineOfOppositeVectorsIsMinusOne() {
        let a = Vectors.l2Normalise([1, 1])
        let b = Vectors.l2Normalise([-1, -1])
        XCTAssertEqual(Vectors.cosine(a, b), -1.0, accuracy: 1e-9)
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
        XCTAssertEqual(Vectors.cosine(mean, mean), 1.0, accuracy: 1e-9)
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
        XCTAssertEqual(Vectors.cosine(folded, newcomer), 1.0, accuracy: 1e-9)
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
        XCTAssertEqual(Vectors.cosine(v, decoded), 1.0, accuracy: 1e-9)
    }

    func testDecodingGarbageYieldsEmptyRatherThanCrashing() {
        XCTAssertEqual(Vectors.decodeBase64("not base64 at all !!"), [])
        XCTAssertEqual(Vectors.unpack(Data([1, 2])), [])
    }
}
