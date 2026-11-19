import XCTest
@testable import NotesCore

final class ThresholdsTests: XCTestCase {

    /// The 1.97 bug, made impossible. A deriver once produced a cosine
    /// threshold above 1.0; the gate then stopped refusing anything and
    /// nothing crashed, so the sprawl it was meant to prevent arrived silently.
    func testImpossibleCosineThresholdIsRejected() {
        var t = Thresholds.appleGuess(embedderID: "test")
        t.dedupeName = 1.97
        XCTAssertThrowsError(try t.validated()) { error in
            guard let invalid = error as? Thresholds.Invalid,
                  case .outOfRange(let field, let value) = invalid else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(field, "dedupeName")
            XCTAssertEqual(value, 1.97)
        }
    }

    func testNegativeThresholdIsRejected() {
        var t = Thresholds.appleGuess(embedderID: "test")
        t.fileFloor = -0.1
        XCTAssertThrowsError(try t.validated())
    }

    func testInvertedFloorsAreRejected() {
        var t = Thresholds.appleGuess(embedderID: "test")
        t.fileFloor = 0.8
        t.reviewFloor = 0.2
        XCTAssertThrowsError(try t.validated()) { error in
            guard let invalid = error as? Thresholds.Invalid,
                  case .inverted = invalid else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testTheShippedGuessIsItselfValid() {
        XCTAssertNoThrow(try Thresholds.appleGuess(embedderID: "test").validated())
    }

    func testOverridesApplyAndImpossibleOnesAreReported() {
        var t = Thresholds.appleGuess(embedderID: "test")
        let rejected = t.apply(overrides: [
            "fileFloor": 0.33,
            "minMargin": 2.5,
            "maxCollections": 20,
            "notAThreshold": 0.5
        ])
        XCTAssertEqual(t.fileFloor, 0.33)
        XCTAssertEqual(t.maxCollections, 20)
        XCTAssertEqual(rejected, ["minMargin=2.5"])
    }

    func testRoundTripsThroughJSON() throws {
        let t = Thresholds.appleGuess(embedderID: "nl-contextual-512-latin")
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(Thresholds.self, from: data), t)
    }
}

final class RouterTests: XCTestCase {

    let t = Thresholds(
        embedderID: "test",
        fileFloor: 0.50,
        reviewFloor: 0.58,
        minMargin: 0.04,
        dedupeName: 0.65,
        dedupeCentroid: 0.60
    )

    func candidates(_ sims: [Double]) -> [Candidate] {
        sims.enumerated().map { Candidate(path: "C\($0.offset + 1)", similarity: $0.element, noteCount: 5) }
    }

    // MARK: - Margin and confidence

    func testMarginIsTheGapToTheRunnerUp() {
        XCTAssertEqual(Router.margin(candidates([0.9, 0.6])), 0.3, accuracy: 1e-9)
        XCTAssertEqual(Router.margin(candidates([0.7])), 0.7, accuracy: 1e-9)
        XCTAssertEqual(Router.margin([]), 0)
    }

    /// Retrieval alone measured 40/40 against a 4B model's 34/40, so when it is
    /// sure the model is not asked at all -- saving a slow call and the risk of
    /// it being overruled wrongly.
    func testRetrievalIsConfidentOnlyWithBothHeightAndMargin() {
        XCTAssertTrue(Router.retrievalIsConfident(candidates([0.80, 0.40]), t))
        XCTAssertFalse(Router.retrievalIsConfident(candidates([0.80, 0.79]), t), "no margin")
        XCTAssertFalse(Router.retrievalIsConfident(candidates([0.55, 0.10]), t), "below reviewFloor")
        XCTAssertFalse(Router.retrievalIsConfident([], t))
    }

    // MARK: - Tiering

    func testClearMatchIsFiled() {
        let d = Router.decideFromRetrieval(candidates([0.80, 0.30]), t)
        XCTAssertEqual(d.outcome, .filed)
        XCTAssertEqual(d.topicPath, "C1")
        XCTAssertFalse(d.usedModel)
    }

    func testMiddlingMatchIsFiledButFlagged() {
        let d = Router.decideFromRetrieval(candidates([0.52, 0.51]), t)
        XCTAssertEqual(d.outcome, .review)
        XCTAssertEqual(d.topicPath, "C1")
    }

    func testWeakMatchGoesToInbox() {
        let d = Router.decideFromRetrieval(candidates([0.20, 0.10]), t)
        XCTAssertEqual(d.outcome, .inbox)
    }

    func testEmptyVaultGoesToInbox() {
        let d = Router.decideFromRetrieval([], t)
        XCTAssertEqual(d.outcome, .inbox)
        XCTAssertNil(d.topicPath)
    }

    /// Inbox means unfiled. A path left attached to an inbox outcome would file
    /// the note anyway and quietly empty the triage queue.
    func testInboxAlwaysHasNoCollection() {
        for sims in [[0.1, 0.05], [0.0], []] {
            let d = Router.decideFromRetrieval(candidates(sims), t)
            if d.outcome == .inbox { XCTAssertNil(d.topicPath) }
        }
        XCTAssertNil(Router.apply(
            choice: .noneFit, candidates: candidates([0.9]), thresholds: t,
            existingCollections: ["C1"], collectionCount: 1
        ).topicPath)
    }

    func testConfidenceNeverExceedsOne() {
        let d = Router.decideFromRetrieval(candidates([0.99, 0.01]), t)
        XCTAssertLessThanOrEqual(d.confidence, 1.0)
    }

    // MARK: - Applying the model's answer

    func testModelAgreeingWithRetrievalIsFiled() {
        let d = Router.apply(
            choice: .slot(1), candidates: candidates([0.80, 0.30]), thresholds: t,
            existingCollections: ["C1", "C2"], collectionCount: 2
        )
        XCTAssertEqual(d.outcome, .filed)
        XCTAssertEqual(d.topicPath, "C1")
        XCTAssertTrue(d.usedModel)
    }

    /// Overruling the similarity ranking is the thing the model measured worst
    /// at, so it is allowed but never silent.
    func testModelDisagreeingWithRetrievalIsFlagged() {
        let d = Router.apply(
            choice: .slot(2), candidates: candidates([0.80, 0.70]), thresholds: t,
            existingCollections: ["C1", "C2"], collectionCount: 2
        )
        XCTAssertEqual(d.outcome, .review)
        XCTAssertEqual(d.topicPath, "C2")
    }

    /// Apple's guided generation guides rather than strictly constrains, so an
    /// out-of-range slot is an expected answer and must not index out of bounds
    /// or be trusted.
    func testOffMenuSlotFallsBackToRetrieval() {
        for slot in [0, 3, 8, 99, -1] {
            let d = Router.apply(
                choice: .slot(slot), candidates: candidates([0.80, 0.30]), thresholds: t,
                existingCollections: ["C1", "C2"], collectionCount: 2
            )
            XCTAssertEqual(d.topicPath, "C1", "slot \(slot) should fall back to retrieval")
            XCTAssertTrue(d.reason.contains("off the menu"), "slot \(slot): \(d.reason)")
        }
    }

    func testNewCollectionIsCreatedButAlwaysFlagged() {
        let d = Router.apply(
            choice: .newCollection("Baking"), candidates: candidates([0.20]), thresholds: t,
            existingCollections: ["Gaming"], collectionCount: 1
        )
        XCTAssertEqual(d.topicPath, "Baking")
        XCTAssertEqual(d.outcome, .review, "a brand-new collection is never a silent decision")
        XCTAssertTrue(d.createdCollection)
    }

    /// The cheap half of the anti-sprawl gate: a proposal that is really an
    /// existing collection under different punctuation reuses it.
    func testProposalMatchingAnExistingCollectionReusesIt() {
        for proposal in ["gaming", "Gaming", "  gaming  ", "Gaming!"] {
            let d = Router.apply(
                choice: .newCollection(proposal), candidates: candidates([0.20]), thresholds: t,
                existingCollections: ["Gaming"], collectionCount: 1
            )
            XCTAssertEqual(d.topicPath, "Gaming", "proposal \(proposal.debugDescription)")
            XCTAssertFalse(d.createdCollection)
        }
    }

    func testCollectionCapStopsNewOnes() {
        let d = Router.apply(
            choice: .newCollection("Baking"), candidates: candidates([0.55, 0.10]), thresholds: t,
            existingCollections: (1...12).map { "C\($0)" }, collectionCount: 12
        )
        XCTAssertFalse(d.createdCollection)
        XCTAssertTrue(d.reason.contains("cap"), d.reason)
    }

    func testNewCollectionWithNoNameGoesToInbox() {
        for name in ["", "   ", "NONE", "none"] {
            let d = Router.apply(
                choice: .newCollection(name), candidates: candidates([0.2]), thresholds: t,
                existingCollections: [], collectionCount: 0
            )
            XCTAssertEqual(d.outcome, .inbox, "name \(name.debugDescription)")
        }
    }

    func testProposedNameIsMadeFilesystemSafe() {
        let d = Router.apply(
            choice: .newCollection("Work/Life"), candidates: candidates([0.2]), thresholds: t,
            existingCollections: [], collectionCount: 0
        )
        XCTAssertEqual(d.topicPath, "WorkLife", "a slash would create an accidental subfolder")
    }
}
