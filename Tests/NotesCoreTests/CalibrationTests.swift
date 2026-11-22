import XCTest
@testable import NotesCore

final class CorpusTests: XCTestCase {

    func testGeneratesTheAskedForSize() {
        let notes = Corpus.generate(count: 60, topicCount: 5)
        XCTAssertEqual(notes.count, 60)
        XCTAssertEqual(Corpus.labels(of: notes).count, 5)
    }

    func testIsReproducible() {
        XCTAssertEqual(Corpus.generate(count: 30, seed: 7), Corpus.generate(count: 30, seed: 7))
        XCTAssertNotEqual(Corpus.generate(count: 30, seed: 7), Corpus.generate(count: 30, seed: 8))
    }

    func testTopicsAreEvenlySpread() {
        let notes = Corpus.generate(count: 60, topicCount: 5)
        var counts: [String: Int] = [:]
        for note in notes { counts[note.topic, default: 0] += 1 }
        for (topic, count) in counts {
            XCTAssertEqual(count, 12, "\(topic) got \(count)")
        }
    }

    /// Notes must share some vocabulary across topics. A corpus of perfectly
    /// separated subjects would make any threshold look good, and the
    /// thresholds have to survive the awkward cases.
    func testTopicsOverlapSomewhat() {
        let notes = Corpus.generate(count: 120, topicCount: 5)
        var vocabularies: [String: Set<String>] = [:]
        for note in notes {
            vocabularies[note.topic, default: []].formUnion(note.text.components(separatedBy: " "))
        }
        var sharedAnywhere = false
        let topics = Array(vocabularies.keys)
        for i in 0..<topics.count {
            for j in (i + 1)..<topics.count where !vocabularies[topics[i]]!
                .intersection(vocabularies[topics[j]]!).isEmpty {
                sharedAnywhere = true
            }
        }
        XCTAssertTrue(sharedAnywhere, "no vocabulary overlap: the corpus is too easy")
    }

    func testDegenerateRequests() {
        XCTAssertTrue(Corpus.generate(count: 0).isEmpty)
        XCTAssertGreaterThanOrEqual(Corpus.labels(of: Corpus.generate(count: 10, topicCount: 1)).count, 2)
    }
}

final class CalibrationTests: XCTestCase {

    /// Vectors with a controllable gap between same-topic and different-topic.
    func labelled(gap: Double, shared: Float = 0) -> (vectors: [[Float]], topics: [String]) {
        var vectors: [[Float]] = []
        var topics: [String] = []
        let jitter = Float(Swift.max(0.0, 0.3 - gap))
        for (index, axis) in [0, 1, 2].enumerated() {
            for step in 0..<4 {
                var v = [Float](repeating: shared, count: 4)
                v[axis] = 1
                v[3] = jitter * Float(step) * 0.1
                vectors.append(Vectors.l2Normalise(v))
                topics.append("T\(index)")
            }
        }
        return (vectors, topics)
    }

    func testMeasuresBothDistributions() {
        let (vectors, topics) = labelled(gap: 0.3)
        guard let measurement = Calibration.measure(
            vectors: vectors, topics: topics, embedderID: "test"
        ) else {
            return XCTFail("no measurement")
        }
        XCTAssertGreaterThan(measurement.withinMean, measurement.acrossMean)
        XCTAssertEqual(measurement.gap, measurement.withinMean - measurement.acrossMean, accuracy: 1e-9)
        XCTAssertEqual(measurement.sampleCount, 12)
    }

    func testRefusesTooLittleData() {
        XCTAssertNil(Calibration.measure(vectors: [[1, 0]], topics: ["A"], embedderID: "t"))
        XCTAssertNil(Calibration.measure(vectors: [], topics: [], embedderID: "t"))
    }

    func testDerivedThresholdsAreOrderedAndInRange() throws {
        let (vectors, topics) = labelled(gap: 0.3)
        let measurement = Calibration.measure(vectors: vectors, topics: topics, embedderID: "test")!
        let thresholds = try Calibration.derive(measurement)

        XCTAssertLessThanOrEqual(thresholds.fileFloor, thresholds.reviewFloor)
        XCTAssertLessThanOrEqual(thresholds.reviewFloor, thresholds.dedupeCentroid)
        for value in [thresholds.fileFloor, thresholds.reviewFloor, thresholds.minMargin,
                      thresholds.dedupeName, thresholds.dedupeCentroid] {
            XCTAssertTrue((0.0...1.0).contains(value), "\(value) out of range")
        }
        XCTAssertEqual(thresholds.embedderID, "test")
    }

    /// The 1.97 bug, from the other side. The Python app's first deriver
    /// scaled the noise floor, which is fine when unrelated pairs sit near
    /// 0.05 and produces an impossible threshold when they sit near 0.56.
    /// Interpolating between the measured distributions cannot do that.
    func testAHighNoiseFloorStillProducesPossibleThresholds() throws {
        // Everything crammed into the top of the range, as Apple's embedder
        // actually behaves: unrelated 0.84, related 0.90.
        let measurement = Calibration.Measurement(
            embedderID: "compressed",
            sampleCount: 500,
            withinMean: 0.896, withinP25: 0.880,
            acrossMean: 0.840, acrossP75: 0.852,
            gap: 0.056
        )
        let thresholds = try Calibration.derive(measurement)
        for value in [thresholds.fileFloor, thresholds.reviewFloor,
                      thresholds.dedupeName, thresholds.dedupeCentroid] {
            XCTAssertTrue((0.0...1.0).contains(value), "\(value) is impossible for a cosine")
        }
        // And they must sit in the gap, not below the noise.
        XCTAssertGreaterThanOrEqual(thresholds.fileFloor, measurement.acrossP75 - 0.001)
    }

    /// A clamped threshold is a working-looking number that files everything
    /// into whichever collection it meets first, and that is invisible for
    /// weeks. Refusing is the only honest answer.
    func testOverlappingDistributionsAreRefusedNotClamped() {
        let hopeless = Calibration.Measurement(
            embedderID: "flat", sampleCount: 100,
            withinMean: 0.900, withinP25: 0.898,
            acrossMean: 0.899, acrossP75: 0.901,
            gap: 0.001
        )
        XCTAssertThrowsError(try Calibration.derive(hopeless)) { error in
            guard case Calibration.Failure.noSeparation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testVerdictsMatchTheBands() {
        func verdict(_ gap: Double) -> String {
            Calibration.Measurement(
                embedderID: "t", sampleCount: 10,
                withinMean: 0, withinP25: 0, acrossMean: 0, acrossP75: 0, gap: gap
            ).verdict
        }
        XCTAssertTrue(verdict(0.005).contains("no usable"))
        XCTAssertTrue(verdict(0.055).contains("weak"))
        XCTAssertTrue(verdict(0.15).contains("workable"))
        XCTAssertTrue(verdict(0.4).contains("strong"))
    }

    // MARK: - Scoring

    func testPerfectFilingScoresPerfectly() {
        let actual = ["A", "A", "B", "B"]
        let score = Calibration.score(predicted: ["A", "A", "B", "B"], actual: actual)
        XCTAssertEqual(score.purity, 1.0)
        XCTAssertEqual(score.coverage, 1.0)
        XCTAssertEqual(score.sprawl, 1.0)
    }

    /// Purity alone is not a score: filing nothing achieves 100% of it.
    /// Coverage is reported beside it for exactly that reason.
    func testFilingNothingHasNoCoverage() {
        let score = Calibration.score(predicted: [nil, nil, nil], actual: ["A", "B", "C"])
        XCTAssertEqual(score.coverage, 0)
        XCTAssertEqual(score.filed, 0)
    }

    /// And coverage alone is not a score either: one collection for everything
    /// achieves 100% of it.
    func testFilingEverythingIntoOneCollectionIsImpure() {
        let score = Calibration.score(
            predicted: ["X", "X", "X", "X"], actual: ["A", "A", "B", "B"]
        )
        XCTAssertEqual(score.coverage, 1.0)
        XCTAssertEqual(score.purity, 0.5, accuracy: 1e-9)
        XCTAssertLessThan(score.sprawl, 1.0, "fewer collections than topics")
    }

    func testSprawlIsVisible() {
        let score = Calibration.score(
            predicted: ["A1", "A2", "B1", "B2"], actual: ["A", "A", "B", "B"]
        )
        XCTAssertEqual(score.purity, 1.0, "each collection is pure")
        XCTAssertEqual(score.sprawl, 2.0, "but twice as many collections as topics")
    }

    func testMismatchedInputScoresZero() {
        let score = Calibration.score(predicted: ["A"], actual: ["A", "B"])
        XCTAssertEqual(score.total, 0)
    }
}
