import Foundation
import NotesCore

/// Runs a calibration on the device, and exports the result so it never has
/// to run there again.
///
/// The export is the point. Embedding has to happen on the phone — iOS gives
/// 512 dimensions where macOS gives 768, and the Simulator cannot load the
/// model at all — but *everything after that* is arithmetic over a matrix of
/// floats. Writing that matrix to a file the Files app can reach takes the
/// device out of the loop: the threshold sweep, the scoring and every
/// re-derivation then run on Windows, in seconds, offline.
///
/// About a megabyte for 500 notes at 512 dimensions.
@MainActor
final class CalibrationRun {

    private let embedding: EmbedderBox
    private let vault: Vault

    init(embedding: EmbedderBox, vault: Vault) {
        self.embedding = embedding
        self.vault = vault
    }

    struct Report: Encodable {
        var ranAt: String
        var embedderID: String
        var noteCount: Int
        var elapsedMS: Int

        var measurement: Calibration.Measurement?
        /// Measured again after removing the shared mean direction.
        var centredMeasurement: Calibration.Measurement?
        var derived: Thresholds?
        var derivedCentred: Thresholds?

        /// What filing would achieve with the derived thresholds.
        var score: Calibration.Score?
        var centredScore: Calibration.Score?

        var recommendation: String
        var exportedTo: String?
        var error: String?
    }

    func run(noteCount: Int = 120) async -> Report {
        let start = Date()
        await embedding.prepare()

        guard embedding.info != nil else {
            return Report(
                ranAt: Timestamp.utcNow(), embedderID: embedding.identifier,
                noteCount: 0, elapsedMS: 0,
                recommendation: "the embedder is not available on this device",
                error: embedding.failure
            )
        }

        let notes = Corpus.generate(count: noteCount)
        var vectors: [[Float]] = []
        for note in notes { vectors.append(await embedding.embed(note.text)) }

        let topics = notes.map(\.topic)
        let usable = vectors.allSatisfy { !$0.isEmpty }
        guard usable else {
            return Report(
                ranAt: Timestamp.utcNow(), embedderID: embedding.identifier,
                noteCount: notes.count, elapsedMS: Int(Date().timeIntervalSince(start) * 1000),
                recommendation: "some notes embedded to nothing",
                error: "empty vectors"
            )
        }

        let centred = Vectors.centred(vectors)
        let raw = Calibration.measure(vectors: vectors, topics: topics, embedderID: embedding.identifier)
        let cooked = Calibration.measure(
            vectors: centred, topics: topics, embedderID: embedding.identifier + "+centred"
        )

        let derived = raw.flatMap { try? Calibration.derive($0) }
        let derivedCentred = cooked.flatMap { try? Calibration.derive($0) }

        let score = derived.map { simulate(vectors: vectors, topics: topics, thresholds: $0) }
        let centredScore = derivedCentred.map { simulate(vectors: centred, topics: topics, thresholds: $0) }

        let exported = export(notes: notes, vectors: vectors)

        return Report(
            ranAt: Timestamp.utcNow(),
            embedderID: embedding.identifier,
            noteCount: notes.count,
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000),
            measurement: raw,
            centredMeasurement: cooked,
            derived: derived,
            derivedCentred: derivedCentred,
            score: score,
            centredScore: centredScore,
            recommendation: Self.recommend(raw: raw, centred: cooked, score: score, centredScore: centredScore),
            exportedTo: exported,
            error: nil
        )
    }

    /// File every note against collections built from the other notes, and
    /// score the result.
    ///
    /// Leave-one-out rather than scoring against the centroids a note helped
    /// build: including it makes every note look well-filed and the number
    /// means nothing.
    private func simulate(
        vectors: [[Float]], topics: [String], thresholds: Thresholds
    ) -> Calibration.Score {
        var predicted: [String?] = []

        for index in vectors.indices {
            var centroids: [String: [[Float]]] = [:]
            for other in vectors.indices where other != index {
                centroids[topics[other], default: []].append(vectors[other])
            }
            let candidates = centroids
                .map { topic, members in
                    Candidate(
                        path: topic,
                        similarity: Vectors.cosine(vectors[index], Vectors.mean(members)),
                        noteCount: members.count
                    )
                }
                .sorted { $0.similarity > $1.similarity }

            let decision = Router.decideFromRetrieval(candidates, thresholds)
            predicted.append(decision.topicPath)
        }
        return Calibration.score(predicted: predicted, actual: topics)
    }

    static func recommend(
        raw: Calibration.Measurement?,
        centred: Calibration.Measurement?,
        score: Calibration.Score?,
        centredScore: Calibration.Score?
    ) -> String {
        guard let raw else { return "could not measure anything" }
        guard let centred else { return "raw gap \(fmt(raw.gap)): \(raw.verdict)" }

        let better = centred.gap > raw.gap * 1.25
        var out = "raw gap \(fmt(raw.gap)) (\(raw.verdict)); centred \(fmt(centred.gap)) (\(centred.verdict)). "

        if better {
            out += "Centring is worth applying to routing — it is "
                + String(format: "%.1f", centred.gap / Swift.max(0.001, raw.gap))
                + " times wider."
        } else {
            out += "Centring does not help here; keep raw similarity."
        }

        if let score, let centredScore {
            out += " Filing would reach "
                + String(format: "%.0f%% purity at %.0f%% coverage", score.purity * 100, score.coverage * 100)
                + " raw, "
                + String(format: "%.0f%%/%.0f%%", centredScore.purity * 100, centredScore.coverage * 100)
                + " centred."
        }
        return out
    }

    static func fmt(_ value: Double) -> String { String(format: "%.4f", value) }

    /// Write the corpus and its vectors where the Files app can reach them.
    ///
    /// Base64 float32, the same packing the index uses, so the matrix can be
    /// read straight back by the Windows tests.
    private func export(notes: [Corpus.Note], vectors: [[Float]]) -> String? {
        let folder = vault.root.appendingPathComponent("_lab", isDirectory: true)
        let url = folder.appendingPathComponent("embeddings.json")

        let payload: [String: Any] = [
            "embedderID": embedding.identifier,
            "dimension": embedding.info?.dimension ?? 0,
            "maximumSequenceLength": embedding.info?.maximumSequenceLength ?? 0,
            "exportedAt": Timestamp.utcNow(),
            "notes": notes.enumerated().map { index, note in
                [
                    "text": note.text,
                    "topic": note.topic,
                    "vector": Vectors.encodeBase64(vectors[index])
                ]
            }
        ]

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
            Log.embed.notice("exported \(notes.count, privacy: .public) vectors to _lab/embeddings.json")
            return "Files ▸ On My iPhone ▸ Advanced Notes ▸ _lab ▸ embeddings.json"
        } catch {
            Log.embed.error("export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
