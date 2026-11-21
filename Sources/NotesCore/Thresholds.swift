import Foundation

/// The tunable numbers that decide where a note goes.
///
/// These are a property of the embedder, never a global constant. The Windows
/// app measured `fileFloor` at 0.23 for its hashing embedder and 0.656 for
/// `nomic-embed-text` -- the same code, thresholds three times apart. Apple's
/// embedder has its own geometry again, so the MVP ships a guess and exposes
/// sliders rather than pretending to know.
///
/// The range check is not decoration. The Python project's threshold deriver
/// once produced 0.86-style numbers scaled up to **1.97** for an embedder whose
/// unrelated pairs sat near 0.56. Cosine cannot exceed 1.0, so the gate
/// silently stopped refusing anything and nothing crashed. `validated()` makes
/// that failure impossible to ship quietly.
public struct Thresholds: Codable, Sendable, Equatable {

    /// Which embedder these were measured against. Vectors from two embedders
    /// share no geometry, so a preset is meaningless without this.
    public var embedderID: String

    /// Below this, nothing is similar enough to file: the note waits in Inbox.
    public var fileFloor: Double
    /// Above `fileFloor` but below this: file it, but flag it for review.
    public var reviewFloor: Double
    /// The winner must beat the runner-up by this much.
    ///
    /// Margin, not absolute similarity, is the primary signal. Absolute cosine
    /// is scale-dependent; "the winner beat the runner-up clearly" means the
    /// same thing on any scale, which is what lets a preset transfer at all.
    public var minMargin: Double

    /// A proposed collection name this close to an existing name is a duplicate.
    public var dedupeName: Double
    /// A proposed name this close to an existing collection's content centroid
    /// is a duplicate.
    ///
    /// Two axes need two thresholds. Measured on the Python side, a true
    /// duplicate scored 0.672 against the existing name but only 0.077 against
    /// its content centroid -- below the 0.216 that unrelated names reach. One
    /// shared threshold would either miss every duplicate or merge unrelated
    /// collections.
    public var dedupeCentroid: Double

    /// How many collections to offer the model. Fixed at 8 because the
    /// `CollectionChoice` slot enum is compile-time and has eight slots.
    public var topicCandidates: Int
    /// Hard cap on collections, so a prototype cannot sprawl while we are
    /// still learning what the thresholds should be.
    public var maxCollections: Int

    public init(
        embedderID: String,
        fileFloor: Double,
        reviewFloor: Double,
        minMargin: Double,
        dedupeName: Double,
        dedupeCentroid: Double,
        topicCandidates: Int = 8,
        maxCollections: Int = 12
    ) {
        self.embedderID = embedderID
        self.fileFloor = fileFloor
        self.reviewFloor = reviewFloor
        self.minMargin = minMargin
        self.dedupeName = dedupeName
        self.dedupeCentroid = dedupeCentroid
        self.topicCandidates = topicCandidates
        self.maxCollections = maxCollections
    }

    /// Measured on an iPhone 17, iOS 26.6, 2026-11-21.
    ///
    /// The first guess was pitched at `fileFloor` 0.50 on the reasoning that a
    /// BERT space sits near nomic's. The device said otherwise: unrelated
    /// notes score **0.840** and related ones **0.896**. Everything clears
    /// 0.50, so the floors did no work at all and only the margin decided
    /// anything — on a gap of 0.055.
    ///
    /// That is the whole argument for calibrating rather than reasoning. A
    /// threshold is a property of the embedder's geometry, and this one's
    /// geometry is compressed into the top sixth of the range.
    ///
    /// These are still provisional: six sentences is a measurement, not a
    /// calibration. `minMargin` is the number that matters here, because the
    /// floors sit so close together that the winner beating the runner-up is
    /// nearly the only signal available.
    public static func appleGuess(embedderID: String) -> Thresholds {
        Thresholds(
            embedderID: embedderID,
            fileFloor: 0.820,
            reviewFloor: 0.865,
            minMargin: 0.012,
            dedupeName: 0.900,
            dedupeCentroid: 0.880
        )
    }

    public enum Invalid: Error, CustomStringConvertible {
        case outOfRange(field: String, value: Double)
        case inverted(fileFloor: Double, reviewFloor: Double)

        public var description: String {
            switch self {
            case let .outOfRange(field, value):
                return "threshold \(field) is \(value), which is outside the cosine range 0...1"
            case let .inverted(file, review):
                return "reviewFloor \(review) must be at least fileFloor \(file)"
            }
        }
    }

    /// Every cosine threshold must be inside `0...1` and the two floors must be
    /// the right way round. Throws rather than clamping: a threshold that came
    /// out impossible means the thing that produced it is wrong, and clamping
    /// would hide exactly the bug worth seeing.
    public func validated() throws -> Thresholds {
        let fields: [(String, Double)] = [
            ("fileFloor", fileFloor),
            ("reviewFloor", reviewFloor),
            ("minMargin", minMargin),
            ("dedupeName", dedupeName),
            ("dedupeCentroid", dedupeCentroid)
        ]
        for (name, value) in fields where !(0.0...1.0).contains(value) {
            throw Invalid.outOfRange(field: name, value: value)
        }
        guard reviewFloor >= fileFloor else {
            throw Invalid.inverted(fileFloor: fileFloor, reviewFloor: reviewFloor)
        }
        return self
    }

    /// Merge values from `Documents/_dev/overrides.json`, so one build can
    /// answer several questions. Unknown or impossible values are ignored and
    /// the caller is told, rather than the app refusing to start.
    public mutating func apply(overrides: [String: Double]) -> [String] {
        var rejected: [String] = []
        func set(_ key: String, _ assign: (Double) -> Void) {
            guard let value = overrides[key] else { return }
            if (0.0...1.0).contains(value) {
                assign(value)
            } else {
                rejected.append("\(key)=\(value)")
            }
        }
        set("fileFloor") { self.fileFloor = $0 }
        set("reviewFloor") { self.reviewFloor = $0 }
        set("minMargin") { self.minMargin = $0 }
        set("dedupeName") { self.dedupeName = $0 }
        set("dedupeCentroid") { self.dedupeCentroid = $0 }
        if let value = overrides["maxCollections"], value >= 1, value <= 200 {
            maxCollections = Int(value)
        }
        return rejected
    }
}
