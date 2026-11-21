import XCTest
@testable import NotesCore

final class NormKeyTests: XCTestCase {

    /// The whole point: five names, one subject, one key.
    func testVariantsOfOneSubjectCollapse() {
        let key = NormKey.key("Gaming")
        for variant in ["Games", "Gamer", "My Games", "Gaming Stuff", "The Games", "gaming notes"] {
            XCTAssertEqual(NormKey.key(variant), key, "\(variant) did not collapse to \(key)")
        }
    }

    /// Sorted tokens, so word order is not an identity.
    func testOrderDoesNotMatter() {
        XCTAssertEqual(NormKey.key("AI Notes"), NormKey.key("Notes AI"))
        XCTAssertEqual(NormKey.key("Web Development"), NormKey.key("Development Web"))
    }

    func testDistinctSubjectsStayDistinct() {
        let pairs = [("Gaming", "Cooking"), ("Technology", "Music"), ("Work", "Travel")]
        for (a, b) in pairs {
            XCTAssertNotEqual(NormKey.key(a), NormKey.key(b), "\(a) collided with \(b)")
        }
    }

    func testEmptyAndNoiseNamesHaveAKey() {
        XCTAssertEqual(NormKey.key(""), "untitled")
        XCTAssertEqual(NormKey.key("Misc Stuff"), "untitled", "all stopwords")
        XCTAssertEqual(NormKey.key("!!!"), "untitled")
    }

    // MARK: - Similarity

    func testPrefixTokensCountAsMatches() {
        XCTAssertGreaterThanOrEqual(
            NormKey.similarity(NormKey.key("Web Dev"), NormKey.key("Web Development")), 0.5
        )
        XCTAssertGreaterThanOrEqual(
            NormKey.similarity(NormKey.key("Tech"), NormKey.key("Technology")), 0.5
        )
    }

    func testUnrelatedNamesScoreLow() {
        XCTAssertLessThan(NormKey.similarity(NormKey.key("Gaming"), NormKey.key("Cooking")), 0.5)
        XCTAssertEqual(NormKey.similarity("", "anything"), 0)
    }

    /// Two letters is not a prefix match, or every short word would collide.
    func testVeryShortTokensDoNotPrefixMatch() {
        XCTAssertFalse(NormKey.matches("ai", in: ["aircraft"]))
        XCTAssertTrue(NormKey.matches("air", in: ["aircraft"]))
    }

    // MARK: - Containment

    func testContainmentDetectsSubtopics() {
        XCTAssertTrue(NormKey.contains(outer: NormKey.key("Gaming Hardware"), inner: NormKey.key("Gaming")))
        XCTAssertTrue(NormKey.contains(outer: NormKey.key("Elden Ring Builds"), inner: NormKey.key("Elden Ring")))
    }

    func testContainmentIsNotSymmetricAndNeedsMore() {
        XCTAssertFalse(NormKey.contains(outer: NormKey.key("Gaming"), inner: NormKey.key("Gaming Hardware")))
        XCTAssertFalse(NormKey.contains(outer: NormKey.key("Gaming"), inner: NormKey.key("Gaming")))
    }
}

final class GateTests: XCTestCase {

    let thresholds = Thresholds.appleGuess(embedderID: "test")

    func existing(_ names: [String]) -> [Gate.Existing] {
        names.map { Gate.Existing(path: $0, noteCount: 5) }
    }

    func decide(_ name: String, _ names: [String], aliases: [String: String] = [:]) -> Gate.Outcome {
        Gate.decide(
            proposed: name, existing: existing(names), aliases: aliases,
            proposedVector: [], thresholds: thresholds
        )
    }

    // MARK: - The checks, cheapest first

    func testAnAliasResolvesInstantly() {
        let outcome = decide(
            "Video Games", ["Gaming"],
            aliases: [NormKey.key("Video Games"): "Gaming"]
        )
        XCTAssertEqual(outcome, .useExisting(path: "Gaming", why: "\"Video Games\" was resolved to this before"))
    }

    func testExactNameIsReused() {
        guard case let .useExisting(path, _) = decide("gaming", ["Gaming"]) else {
            return XCTFail("should have reused it")
        }
        XCTAssertEqual(path, "Gaming")
    }

    func testNameVariantsAreRefused() {
        for variant in ["Games", "Gamer", "My Games", "Gaming Stuff"] {
            guard case let .useExisting(path, _) = decide(variant, ["Gaming"]) else {
                return XCTFail("\(variant) created a new collection")
            }
            XCTAssertEqual(path, "Gaming", variant)
        }
    }

    func testNearNamesAreRefused() {
        guard case let .useExisting(path, _) = decide("Web Dev", ["Web Development"]) else {
            return XCTFail("Web Dev should resolve to Web Development")
        }
        XCTAssertEqual(path, "Web Development")
    }

    /// Containment nests rather than merging. A subtopic swallowed into its
    /// parent loses information; a subtopic made into a rival root folder
    /// flattens the taxonomy. Nesting keeps both.
    ///
    /// It takes a genuinely distinctive name to get here, because the
    /// near-key check runs first — see the test below, which pins why.
    func testDistinctiveSubtopicsNest() {
        guard case let .nestUnder(parent, name, _) = decide("Gaming Hardware Reviews", ["Gaming"]) else {
            return XCTFail("should have nested")
        }
        XCTAssertEqual(parent, "Gaming")
        XCTAssertEqual(name, "Gaming Hardware Reviews")
    }

    /// A two-word name sharing its only meaningful token with an existing
    /// collection is a variant, not a subtopic.
    ///
    /// Worth pinning because it is a real tension and I got it wrong first.
    /// Running containment before the near-key check makes "Video Games" a
    /// *child* of "Gaming", which is plainly worse than treating it as the
    /// same thing — so near-key goes first, and only more distinctive names
    /// reach the nesting rule.
    func testShortVariantsMergeRatherThanNesting() {
        for variant in ["Video Games", "PC Gaming"] {
            guard case let .useExisting(path, _) = decide(variant, ["Gaming"]) else {
                return XCTFail("\(variant) should resolve to Gaming, not nest under it")
            }
            XCTAssertEqual(path, "Gaming", variant)
        }
    }

    func testNestingStopsAtTheDepthCap() {
        let deep = ["Technology/AI/Models"]
        let outcome = decide("Technology AI Models Training", deep)
        if case .nestUnder = outcome {
            XCTFail("should not nest past the depth cap")
        }
    }

    func testGenuinelyNewCollectionsAreCreated() {
        guard case let .create(name) = decide("Baking", ["Gaming", "Technology"]) else {
            return XCTFail("Baking is not a duplicate of anything")
        }
        XCTAssertEqual(name, "Baking")
    }

    func testCreatedNamesAreFilesystemSafe() {
        guard case let .create(name) = decide("Work/Life", ["Gaming"]) else {
            return XCTFail("should have created it")
        }
        XCTAssertEqual(name, "WorkLife", "a slash would make an accidental subfolder")
    }

    func testEmptyNamesAreRefused() {
        for name in ["", "   ", "NONE"] {
            guard case .refuse = decide(name, ["Gaming"]) else {
                return XCTFail("accepted \(name.debugDescription)")
            }
        }
    }

    func testTheCapIsEnforced() {
        let many = (1...thresholds.maxCollections).map { "C\($0)" }
        guard case .refuse = decide("Something New", many) else {
            return XCTFail("should refuse past the cap")
        }
    }

    // MARK: - The expensive check

    /// A name close to what a collection is *about* is a duplicate of it,
    /// whatever it happens to be called.
    func testContentSimilarityCatchesASynonymWithNoSharedLetters() {
        let centroid = Vectors.l2Normalise([1, 0, 0])
        let proposed = Vectors.l2Normalise([0.99, 0.1, 0])
        let outcome = Gate.decide(
            proposed: "Automobiles",
            existing: [Gate.Existing(path: "Cars", noteCount: 5, centroid: centroid)],
            aliases: [:],
            proposedVector: proposed,
            thresholds: thresholds
        )
        guard case let .useExisting(path, _) = outcome else {
            return XCTFail("should have matched on content, got \(outcome)")
        }
        XCTAssertEqual(path, "Cars")
    }

    func testUnrelatedContentStillCreates() {
        let centroid = Vectors.l2Normalise([1, 0, 0])
        let proposed = Vectors.l2Normalise([0, 1, 0])
        let outcome = Gate.decide(
            proposed: "Baking",
            existing: [Gate.Existing(path: "Cars", noteCount: 5, centroid: centroid)],
            aliases: [:],
            proposedVector: proposed,
            thresholds: thresholds
        )
        guard case .create = outcome else {
            return XCTFail("unrelated content should create, got \(outcome)")
        }
    }

    // MARK: - Aliases

    /// Recording a refusal is what makes the gate cheaper over time: the
    /// second time the model proposes this, the answer is a dictionary lookup.
    func testRefusalsAreRecordedAsAliases() {
        let outcome = decide("Video Games", ["Gaming"])
        let alias = Gate.aliasToRecord(for: "Video Games", outcome: outcome)
        XCTAssertEqual(alias?.key, NormKey.key("Video Games"))
        XCTAssertEqual(alias?.path, "Gaming")
    }

    func testCreationsAreNotAliased() {
        let outcome = decide("Baking", ["Gaming"])
        XCTAssertNil(Gate.aliasToRecord(for: "Baking", outcome: outcome))
    }

    // MARK: - The property that matters

    /// Feed the gate many variants of a few subjects and it must not sprawl.
    /// This is the stress test reduced to its smallest honest form.
    func testManyVariantsOfThreeSubjectsDoNotSprawl() {
        var collections: [Gate.Existing] = []
        var aliases: [String: String] = [:]

        let proposals = [
            "Gaming", "Games", "Video Games", "My Gaming Notes", "Gaming Stuff", "Gamer",
            "Cooking", "Cook", "Recipes and Cooking", "My Cooking Notes",
            "Technology", "Tech", "Tech Stuff", "Technology Notes"
        ]

        for name in proposals {
            let outcome = Gate.decide(
                proposed: name, existing: collections, aliases: aliases,
                proposedVector: [], thresholds: thresholds
            )
            if case let .create(created) = outcome {
                collections.append(Gate.Existing(path: created, noteCount: 1))
            }
            if let alias = Gate.aliasToRecord(for: name, outcome: outcome) {
                aliases[alias.key] = alias.path
            }
        }

        XCTAssertLessThanOrEqual(
            collections.count, 4,
            "14 names for 3 subjects produced \(collections.map(\.path))"
        )
        XCTAssertGreaterThanOrEqual(collections.count, 3, "should not have merged distinct subjects")
    }
}
