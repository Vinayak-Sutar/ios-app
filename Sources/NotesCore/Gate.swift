import Foundation

/// The gate a proposed new collection has to get through.
///
/// A request to create a collection is a *request*, not a command. The checks
/// run cheapest first, so most duplicates are settled by string work and never
/// reach a similarity comparison at all.
///
/// Ported from `mnemo/gate.py`, which exists because the alternative — letting
/// a model make folders freely — produces `Gaming`, `Games`, `Video Games`,
/// `Gaming Stuff` and `PC Gaming` within a week.
public enum Gate {

    /// What the gate knows about the collections that already exist.
    public struct Existing: Sendable {
        public var path: String
        public var noteCount: Int
        /// The collection's content centroid, for the expensive check.
        public var centroid: [Float]

        public init(path: String, noteCount: Int, centroid: [Float] = []) {
            self.path = path
            self.noteCount = noteCount
            self.centroid = centroid
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Use this existing collection instead.
        case useExisting(path: String, why: String)
        /// Create it, but nested under an existing collection.
        case nestUnder(parent: String, name: String, why: String)
        /// Create it as a new top-level collection.
        case create(name: String)
        /// Refuse, and leave the note unfiled.
        case refuse(why: String)

        public var describe: String {
            switch self {
            case let .useExisting(path, why): return "used \(path): \(why)"
            case let .nestUnder(parent, name, _): return "nested \(name) under \(parent)"
            case let .create(name): return "created \(name)"
            case let .refuse(why): return "refused: \(why)"
            }
        }
    }

    public static let maxDepth = 3

    /// Decide what to do with a proposed collection name.
    ///
    /// - Parameters:
    ///   - aliases: names refused before, mapped to what they resolved to. A
    ///     synonym turned down once resolves instantly forever after, which is
    ///     what stops the same argument recurring every time a note arrives.
    ///   - proposedVector: the embedding of the **name alone**. Never the name
    ///     plus a rationale: a model that emits boilerplate reasoning makes
    ///     every proposal vector nearly identical, and the gate then merges
    ///     unrelated collections into whichever was created first.
    public static func decide(
        proposed rawName: String,
        existing: [Existing],
        aliases: [String: String],
        proposedVector: [Float] = [],
        thresholds: Thresholds
    ) -> Outcome {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.uppercased() != "NONE" else {
            return .refuse(why: "no name given")
        }

        let key = NormKey.key(name)

        // 1. Alias — the cheapest possible answer, and the one that makes the
        //    gate get faster the longer it runs.
        if let resolved = aliases[key] ?? aliases[Slug.slugify(name)] {
            if existing.contains(where: { $0.path == resolved }) {
                return .useExisting(path: resolved, why: "\"\(name)\" was resolved to this before")
            }
        }

        // 2. Exact name, ignoring case and punctuation.
        let slug = Slug.slugify(name)
        if let match = existing.first(where: { Slug.slugify($0.path) == slug }) {
            return .useExisting(path: match.path, why: "same name")
        }

        // 3. Same normalised key: Games, Gamer, My Games, Gaming Stuff.
        if let match = existing.first(where: { NormKey.key($0.path) == key }) {
            return .useExisting(path: match.path, why: "\"\(name)\" is the same subject")
        }

        // 4. Near key: Web Dev against Web Development.
        var bestNear: (Existing, Double)?
        for candidate in existing {
            let score = NormKey.similarity(NormKey.key(candidate.path), key)
            if score >= 0.5, score > (bestNear?.1 ?? 0) { bestNear = (candidate, score) }
        }
        if let (match, score) = bestNear {
            return .useExisting(path: match.path, why: String(format: "very close to %@ (%.2f)", match.path, score))
        }

        // 5. Containment means NESTING, not merging. "Gaming Hardware" is a
        //    subtopic of "Gaming", so it goes underneath rather than becoming
        //    a rival top-level folder — or being swallowed by it.
        //
        //    Checked AFTER the near-key test, which means a short name like
        //    "Video Games" is treated as a variant of "Gaming" rather than a
        //    subtopic of it — the two share enough tokens to score 0.5. Only a
        //    more distinctive name, "Gaming Hardware Reviews", falls through
        //    to here and nests. I tried the other order first; it made
        //    "Video Games" a child of "Gaming", which is worse.
        var host: Existing?
        for candidate in existing where NormKey.contains(outer: key, inner: NormKey.key(candidate.path)) {
            if host == nil || candidate.path.count > host!.path.count { host = candidate }
        }
        if let host {
            let depth = host.path.components(separatedBy: "/").count
            guard depth < maxDepth else {
                return .useExisting(path: host.path, why: "nesting any deeper would be unmanageable")
            }
            return .nestUnder(
                parent: host.path,
                name: name,
                why: "\(name) is a part of \(host.path)"
            )
        }

        // 6. Similarity, last because it is the only check that costs
        //    anything. Compared against each collection's content centroid: a
        //    name close to what a collection is *about* is a duplicate of it,
        //    whatever it is called.
        if !proposedVector.isEmpty {
            for candidate in existing where !candidate.centroid.isEmpty {
                let score = Vectors.cosine(proposedVector, candidate.centroid)
                if score >= thresholds.dedupeCentroid {
                    return .useExisting(
                        path: candidate.path,
                        why: String(format: "about the same things as %@ (%.3f)", candidate.path, score)
                    )
                }
            }
        }

        // 7. Shape. A cap is a blunt instrument, but an unbounded taxonomy is
        //    not a taxonomy.
        if existing.count >= thresholds.maxCollections {
            return .refuse(why: "already at \(thresholds.maxCollections) collections")
        }

        return .create(name: Slug.safeDirname(name))
    }

    /// The alias to remember after a refusal.
    ///
    /// Recording these is what makes the gate cheaper over time: the second
    /// time a model proposes "Video Games", the answer comes from a dictionary
    /// rather than from five checks and an embedding comparison.
    public static func aliasToRecord(for proposed: String, outcome: Outcome) -> (key: String, path: String)? {
        switch outcome {
        case let .useExisting(path, _):
            return (NormKey.key(proposed), path)
        case .nestUnder, .create, .refuse:
            return nil
        }
    }
}
