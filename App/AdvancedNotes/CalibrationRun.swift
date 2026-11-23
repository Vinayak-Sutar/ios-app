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
    /// Hands the derived thresholds to the capture pipeline, so a measurement
    /// takes effect on the next note rather than on the next launch.
    private let apply: (Thresholds) -> Void

    init(embedding: EmbedderBox, vault: Vault, apply: @escaping (Thresholds) -> Void) {
        self.embedding = embedding
        self.vault = vault
        self.apply = apply
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

        /// Whether the derived thresholds are now the ones the app files
        /// with. Measuring and then not using the measurement was the whole
        /// problem this field exists to answer.
        var applied: Bool = false
        var appliedDetail: String?
        /// What filing will actually use from here on, which can differ from
        /// `derived` because `overrides.json` still outranks a measurement.
        var inForce: Thresholds?

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
        let put = putIntoForce(derived, measurement: raw)

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
            applied: put.applied,
            appliedDetail: put.detail,
            inForce: put.inForce,
            error: nil
        )
    }

    /// Keep the derived thresholds and start using them.
    ///
    /// **The raw ones, never the centred ones.** Routing compares raw
    /// vectors, so a threshold measured after removing the shared mean
    /// direction is a number from a different space — it would read as a
    /// plausible 0.8-something and quietly mean nothing. If centring turns
    /// out to be worth it, that is a change to how notes are compared, and
    /// the thresholds follow it rather than leading.
    ///
    /// `derive` has already refused anything with no usable separation and
    /// range-checked what it returned, so a value arriving here is one worth
    /// using: measured on this device, against this embedder, which is more
    /// than the preset can say.
    private func putIntoForce(
        _ derived: Thresholds?, measurement: Calibration.Measurement?
    ) -> (applied: Bool, detail: String, inForce: Thresholds?) {
        guard let derived, let measurement else {
            return (false, "nothing usable to apply; the preset stands", nil)
        }

        let stored = CalibratedThresholds.Stored(
            measuredAt: Timestamp.utcNow(),
            gap: measurement.gap,
            verdict: measurement.verdict,
            thresholds: derived
        )
        do {
            try CalibratedThresholds.save(stored, to: CalibratedThresholds.url(in: vault.root))
        } catch {
            // Applying without keeping would file the next hour's notes to
            // one set of numbers and everything after a restart to another.
            Log.embed.error("could not keep the calibration: \(error.localizedDescription, privacy: .public)")
            return (false, "measured, but could not be saved: \(error.localizedDescription)", nil)
        }

        // The same order of authority the app uses at launch, so pressing
        // Calibrate cannot put the app into a state a relaunch undoes.
        let (overrides, _) = DevOverrides.load()
        let (inForce, notes) = CalibratedThresholds.effective(
            preset: derived,
            calibrated: stored,
            overrides: overrides,
            embedderID: derived.embedderID
        )
        apply(inForce)
        for note in notes { Log.vault.notice("thresholds: \(note, privacy: .public)") }

        var detail = String(
            format: "filing now uses fileFloor %.3f, reviewFloor %.3f, margin %.3f",
            inForce.fileFloor, inForce.reviewFloor, inForce.minMargin
        )
        let shadowed = Self.differing(derived, inForce)
        if shadowed.isEmpty {
            detail += ". Delete _lab/calibrated.json to go back to the preset."
        } else {
            // Naming them matters: a hand-written number outranking the
            // measurement is correct behaviour, but silently is not, and
            // "nothing changed" is indistinguishable from a broken button.
            detail += ". _dev/overrides.json still sets "
                + shadowed.joined(separator: ", ")
                + ", which outranks a measurement - delete those lines to use this one."
        }
        return (true, detail, inForce)
    }

    /// Which of the six numbers a later source overwrote.
    static func differing(_ measured: Thresholds, _ inForce: Thresholds) -> [String] {
        var out: [String] = []
        if measured.fileFloor != inForce.fileFloor { out.append("fileFloor") }
        if measured.reviewFloor != inForce.reviewFloor { out.append("reviewFloor") }
        if measured.minMargin != inForce.minMargin { out.append("minMargin") }
        if measured.dedupeName != inForce.dedupeName { out.append("dedupeName") }
        if measured.dedupeCentroid != inForce.dedupeCentroid { out.append("dedupeCentroid") }
        if measured.maxCollections != inForce.maxCollections { out.append("maxCollections") }
        return out
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
