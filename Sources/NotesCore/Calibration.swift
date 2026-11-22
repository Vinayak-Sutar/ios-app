import Foundation

/// Deriving thresholds from measured similarity, and scoring the result.
///
/// The reason this exists rather than a constant: a threshold is a property
/// of the embedder's geometry, and the geometries differ enormously. The
/// Python app measured `fileFloor` at 0.23 for feature hashing and 0.656 for
/// `nomic-embed-text`; Apple's embedder puts unrelated notes at 0.840 and
/// related ones at 0.896, squeezing everything into the top sixth of the
/// range. No amount of reasoning gets you from one of those to another.
public enum Calibration {

    /// What the two distributions look like.
    public struct Measurement: Sendable, Codable, Equatable {
        public var embedderID: String
        public var sampleCount: Int

        /// Similarity between notes of the same topic.
        public var withinMean: Double
        public var withinP25: Double
        /// Similarity between notes of different topics.
        public var acrossMean: Double
        public var acrossP75: Double
        /// The usable range: how much daylight there is to put a threshold in.
        public var gap: Double

        public var verdict: String {
            switch gap {
            case ..<0.02: return "no usable separation"
            case ..<0.08: return "weak separation — expect a lot of Inbox"
            case ..<0.20: return "workable separation"
            default: return "strong separation"
            }
        }
    }

    /// Measure both distributions over labelled vectors.
    public static func measure(
        vectors: [[Float]], topics: [String], embedderID: String
    ) -> Measurement? {
        guard vectors.count == topics.count, vectors.count >= 4 else { return nil }

        var within: [Double] = []
        var across: [Double] = []
        for i in 0..<vectors.count {
            for j in (i + 1)..<vectors.count {
                guard vectors[i].count == vectors[j].count, !vectors[i].isEmpty else { continue }
                let score = Vectors.cosine(vectors[i], vectors[j])
                if topics[i] == topics[j] { within.append(score) } else { across.append(score) }
            }
        }
        guard !within.isEmpty, !across.isEmpty else { return nil }

        let withinMean = within.reduce(0, +) / Double(within.count)
        let acrossMean = across.reduce(0, +) / Double(across.count)
        return Measurement(
            embedderID: embedderID,
            sampleCount: vectors.count,
            withinMean: withinMean,
            withinP25: percentile(within, 0.25),
            acrossMean: acrossMean,
            acrossP75: percentile(across, 0.75),
            gap: withinMean - acrossMean
        )
    }

    public static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Swift.max(0, Swift.min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction)))
        return sorted[position]
    }

    public enum Failure: Error, CustomStringConvertible {
        case notEnoughData
        case noSeparation(gap: Double)

        public var description: String {
            switch self {
            case .notEnoughData:
                return "not enough labelled vectors to measure anything"
            case let .noSeparation(gap):
                return String(
                    format: "same-topic and different-topic notes score %.4f apart — "
                        + "no threshold can separate them", gap
                )
            }
        }
    }

    /// Turn a measurement into thresholds.
    ///
    /// Interpolates between the two measured distributions rather than scaling
    /// the noise floor. That distinction is not academic: the Python app's
    /// first deriver multiplied the noise floor, which works when unrelated
    /// pairs sit near 0.05 and produces **1.97** when they sit near 0.56.
    /// Cosine cannot exceed 1.0, so the gate silently stopped refusing
    /// anything and nothing crashed.
    ///
    /// Throws rather than clamping when the distributions overlap. A clamped
    /// threshold is a working-looking number that files everything into the
    /// first collection it sees, and that failure is invisible for weeks.
    public static func derive(_ measurement: Measurement) throws -> Thresholds {
        guard measurement.sampleCount >= 4 else { throw Failure.notEnoughData }
        guard measurement.gap > 0.005 else { throw Failure.noSeparation(gap: measurement.gap) }

        let floor = measurement.acrossP75
        let ceiling = Swift.max(measurement.withinP25, floor + measurement.gap)
        let spread = ceiling - floor

        // Below fileFloor nothing is similar enough to file; above
        // reviewFloor we are confident. Both sit inside the measured gap
        // rather than at round numbers.
        let thresholds = Thresholds(
            embedderID: measurement.embedderID,
            fileFloor: clamp(floor + spread * 0.25),
            reviewFloor: clamp(floor + spread * 0.60),
            // A fraction of the gap: on a compressed geometry the margin is
            // nearly the only signal left, so it has to scale with the space
            // actually available rather than being a constant.
            minMargin: clamp(Swift.max(0.005, measurement.gap * 0.25)),
            dedupeName: clamp(floor + spread * 0.85),
            dedupeCentroid: clamp(floor + spread * 0.75)
        )
        return try thresholds.validated()
    }

    static func clamp(_ value: Double) -> Double {
        Swift.min(0.999, Swift.max(0.0, value))
    }

    // MARK: - Scoring

    /// How well a set of filing decisions matched the answer key.
    public struct Score: Sendable, Codable, Equatable {
        /// Of the notes that were filed, the fraction whose collection is
        /// dominated by their true topic.
        public var purity: Double
        /// The fraction of notes filed at all.
        public var coverage: Double
        /// Collections created against topics that exist. Above 1 is sprawl.
        public var sprawl: Double
        public var collections: Int
        public var trueTopics: Int
        public var filed: Int
        public var total: Int

        public var summary: String {
            String(
                format: "purity %.1f%%, coverage %.1f%%, %d collections for %d topics",
                purity * 100, coverage * 100, collections, trueTopics
            )
        }
    }

    /// Score predicted collections against known topics.
    ///
    /// Purity is measured over *filed* notes only, and coverage is reported
    /// beside it, because the two trade off and either alone is misleading:
    /// a system that files nothing has perfect purity, and one that files
    /// everything into a single collection has perfect coverage.
    public static func score(predicted: [String?], actual: [String]) -> Score {
        guard predicted.count == actual.count, !actual.isEmpty else {
            return Score(
                purity: 0, coverage: 0, sprawl: 0,
                collections: 0, trueTopics: 0, filed: 0, total: 0
            )
        }

        var members: [String: [String]] = [:]
        for (index, collection) in predicted.enumerated() {
            guard let collection else { continue }
            members[collection, default: []].append(actual[index])
        }

        let filed = members.values.reduce(0) { $0 + $1.count }
        var correct = 0
        for (_, topics) in members {
            var counts: [String: Int] = [:]
            for topic in topics { counts[topic, default: 0] += 1 }
            correct += counts.values.max() ?? 0
        }

        let trueTopics = Set(actual).count
        return Score(
            purity: filed > 0 ? Double(correct) / Double(filed) : 0,
            coverage: Double(filed) / Double(actual.count),
            sprawl: trueTopics > 0 ? Double(members.count) / Double(trueTopics) : 0,
            collections: members.count,
            trueTopics: trueTopics,
            filed: filed,
            total: actual.count
        )
    }
}
