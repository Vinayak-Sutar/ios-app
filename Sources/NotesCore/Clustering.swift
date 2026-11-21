import Foundation

/// A seeded random source, so clustering is reproducible.
///
/// Swift's default generator is seeded per process, which would make every
/// clustering run produce a different taxonomy from identical notes — and make
/// any test of it meaningless. SplitMix64: small, fast, and good enough for
/// picking starting points.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64 = 0x9E3779B97F4A7C15) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Grouping notes by what they are about, with no labels to learn from.
///
/// Used twice: once at cold start, to derive a starting taxonomy from real
/// notes rather than letting collections form one at a time from whichever
/// note happened to arrive first; and later by the gardener, to notice that
/// two collections have drifted into being the same thing.
public enum Clustering {

    public struct Cluster: Sendable, Equatable {
        /// Indices into the input, not the vectors themselves.
        public var members: [Int]
        public var centroid: [Float]

        public init(members: [Int], centroid: [Float]) {
            self.members = members
            self.centroid = centroid
        }
    }

    /// How many clusters to look for.
    ///
    /// Bounded by `minCluster` because a cluster of one is not a subject, it
    /// is a note — and a taxonomy of singletons is exactly the sprawl the gate
    /// exists to prevent.
    public static func chooseK(
        count: Int, minK: Int = 2, maxK: Int = 12, minCluster: Int = 3
    ) -> Int {
        guard count >= minK * minCluster else { return 0 }
        let byMass = count / minCluster
        return max(minK, min(maxK, byMass))
    }

    /// k-means with a fixed iteration cap.
    ///
    /// Capped rather than run to convergence: this runs on a phone while
    /// someone waits, and the difference between ten iterations and
    /// convergence is rarely a different taxonomy. Empty clusters are dropped
    /// rather than reseeded — an empty cluster means k was too high, and
    /// returning fewer groups is the honest answer.
    public static func cluster(
        _ vectors: [[Float]], k: Int, seed: UInt64 = 12345, iterations: Int = 12
    ) -> [Cluster] {
        guard k > 0, vectors.count >= k, let first = vectors.first, !first.isEmpty else {
            return []
        }
        let dim = first.count
        let usable = vectors.enumerated().filter { $0.element.count == dim }
        guard usable.count >= k else { return [] }

        var random = SeededRandom(seed: seed)
        var centroids = seedCentroids(usable.map(\.element), k: k, random: &random)
        var assignment = [Int](repeating: 0, count: usable.count)

        for _ in 0..<iterations {
            var moved = false
            for (index, item) in usable.enumerated() {
                var best = 0
                var bestScore = -Double.infinity
                for (slot, centroid) in centroids.enumerated() {
                    let score = Vectors.cosine(item.element, centroid)
                    if score > bestScore {
                        bestScore = score
                        best = slot
                    }
                }
                if assignment[index] != best {
                    assignment[index] = best
                    moved = true
                }
            }

            for slot in 0..<k {
                let members = usable.indices.filter { assignment[$0] == slot }
                guard !members.isEmpty else { continue }
                centroids[slot] = Vectors.mean(members.map { usable[$0].element })
            }
            if !moved { break }
        }

        var out: [Cluster] = []
        for slot in 0..<k {
            let members = usable.indices.filter { assignment[$0] == slot }
            guard !members.isEmpty else { continue }
            out.append(Cluster(
                members: members.map { usable[$0].offset },
                centroid: centroids[slot]
            ))
        }
        // Biggest first, so the most substantial subject is named first.
        return out.sorted { $0.members.count > $1.members.count }
    }

    /// k-means++ style seeding: spread the starting points out.
    ///
    /// Picking at random routinely puts two seeds inside one subject, which
    /// splits it and merges two others — and with a fixed iteration cap there
    /// is no time to recover from that.
    static func seedCentroids(
        _ vectors: [[Float]], k: Int, random: inout SeededRandom
    ) -> [[Float]] {
        var chosen: [[Float]] = []
        chosen.append(vectors[Int(random.next() % UInt64(vectors.count))])

        while chosen.count < k {
            var furthest = vectors[0]
            var worstScore = Double.infinity
            for vector in vectors {
                // Distance to the nearest chosen seed; take the point that is
                // furthest from all of them.
                let nearest = chosen.map { Vectors.cosine(vector, $0) }.max() ?? 0
                if nearest < worstScore {
                    worstScore = nearest
                    furthest = vector
                }
            }
            chosen.append(furthest)
        }
        return chosen
    }

    // MARK: - Naming

    /// Words too common to name anything.
    ///
    /// Includes the collection-name stopwords, since a word that cannot
    /// distinguish a folder cannot distinguish a cluster either — "thing",
    /// "stuff", "notes" are exactly what a weak clustering reaches for.
    static let namingStopwords: Set<String> = NormKey.stopwords.union([
        "the", "and", "for", "with", "that", "this", "from", "have", "has",
        "was", "were", "are", "but", "not", "you", "your", "its", "it", "they",
        "them", "then", "than", "when", "what", "which", "who", "how", "why",
        "can", "will", "would", "should", "could", "about", "into", "over",
        "just", "more", "most", "some", "any", "all", "one", "two", "also",
        "very", "much", "out", "get", "got", "make", "made", "like", "need"
    ])

    /// A name for a cluster, taken from the words its members share.
    ///
    /// Ranked by **document frequency**, not raw count: a word in four of five
    /// notes describes the group, while a word forty times in one note
    /// describes that note. The Python app found this is what separates
    /// "Sourdough" from "Banneton Proofing" — the latter being what you get
    /// when one note's vocabulary wins.
    public static func name(from texts: [String], existing: Set<String> = []) -> String? {
        guard !texts.isEmpty else { return nil }

        var documentFrequency: [String: Int] = [:]
        for text in texts {
            var seen = Set<String>()
            for word in Slug.tokens(text) where word.count >= 4 && !namingStopwords.contains(word) {
                seen.insert(word)
            }
            for word in seen { documentFrequency[word, default: 0] += 1 }
        }

        // A word has to appear in at least half the notes to be describing the
        // group rather than one member of it.
        let floor = max(2, (texts.count + 1) / 2)
        let shared = documentFrequency
            .filter { $0.value >= floor }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }

        guard !shared.isEmpty else { return nil }

        let picked = shared.prefix(2).map { capitalise($0.key) }
        var candidate = picked.joined(separator: " ")
        if existing.contains(where: { NormKey.key($0) == NormKey.key(candidate) }) {
            // Already have it; a third word may distinguish the group.
            guard shared.count > 2 else { return nil }
            candidate = shared.prefix(3).map { capitalise($0.key) }.joined(separator: " ")
        }
        return candidate
    }

    static func capitalise(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }
}
