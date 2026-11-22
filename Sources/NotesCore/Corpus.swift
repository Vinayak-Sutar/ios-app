import Foundation

/// A synthetic set of notes with known topics, for measuring the filing
/// pipeline against an answer key.
///
/// Real notes cannot do this job: nobody has labelled them, so there is
/// nothing to score against. A generated corpus trades realism for a ground
/// truth, which is the only way to say whether a threshold is right rather
/// than merely plausible.
///
/// Reproducible by seed, so a calibration run can be repeated and a
/// regression can be told from noise.
public enum Corpus {

    public struct Note: Sendable, Equatable {
        public var text: String
        /// The topic it genuinely belongs to. The thing being predicted.
        public var topic: String

        public init(text: String, topic: String) {
            self.text = text
            self.topic = topic
        }
    }

    /// Topic vocabularies, deliberately overlapping in places.
    ///
    /// A corpus of perfectly separated subjects would make any threshold look
    /// good. These share words on purpose — "build", "test", "review" turn up
    /// in several — because the thresholds have to survive the awkward cases,
    /// and the awkward cases are where a real vault lives.
    static let topics: [String: [String]] = [
        "Cooking": [
            "sourdough", "levain", "proofing", "banneton", "crumb", "hydration",
            "oven", "yeast", "flour", "knead", "bake", "recipe", "spices",
            "simmer", "roast", "marinade", "stock", "sauce"
        ],
        "Gaming": [
            "boss", "build", "playthrough", "souls", "parry", "dodge", "loadout",
            "framerate", "controller", "patch", "speedrun", "coop", "loot",
            "respec", "stamina", "summon"
        ],
        "Technology": [
            "retrieval", "embedding", "chunking", "latency", "index", "cache",
            "deploy", "build", "refactor", "compiler", "runtime", "schema",
            "query", "throughput", "regression", "review"
        ],
        "Music": [
            "fretboard", "pentatonic", "chord", "barre", "scale", "tempo",
            "metronome", "capo", "strum", "progression", "modes", "intonation",
            "practice", "rhythm", "transcribe"
        ],
        "Health": [
            "sleep", "stretching", "mobility", "hydration", "rest", "recovery",
            "cardio", "posture", "breathing", "steps", "routine", "injury",
            "warmup", "nutrition", "protein"
        ],
        "Travel": [
            "flight", "itinerary", "hostel", "visa", "packing", "layover",
            "currency", "trains", "border", "booking", "luggage", "route",
            "timezone", "sunscreen", "map"
        ]
    ]

    /// Build a corpus of `count` notes spread over the first `topicCount`
    /// topics.
    public static func generate(
        count: Int, topicCount: Int = 5, seed: UInt64 = 20261122
    ) -> [Note] {
        let names = topics.keys.sorted().prefix(max(2, min(topicCount, topics.count)))
        guard !names.isEmpty, count > 0 else { return [] }

        var random = SeededRandom(seed: seed)
        var out: [Note] = []

        for index in 0..<count {
            let topic = names[index % names.count]
            let vocabulary = topics[topic] ?? []
            guard !vocabulary.isEmpty else { continue }

            // Six to twelve words, mostly from this topic. The handful of
            // borrowed words is the point: a corpus with none would flatter
            // every threshold.
            let length = 6 + Int(random.next() % 7)
            var words: [String] = []
            for _ in 0..<length {
                if random.next() % 10 == 0 {
                    // One word in ten comes from somewhere else entirely.
                    let other = names[Int(random.next() % UInt64(names.count))]
                    let borrowed = topics[other] ?? vocabulary
                    words.append(borrowed[Int(random.next() % UInt64(borrowed.count))])
                } else {
                    words.append(vocabulary[Int(random.next() % UInt64(vocabulary.count))])
                }
            }
            out.append(Note(text: words.joined(separator: " "), topic: topic))
        }
        return out
    }

    /// The topics actually present, in a stable order.
    public static func labels(of notes: [Note]) -> [String] {
        Array(Set(notes.map(\.topic))).sorted()
    }
}
