import Foundation
import NotesCore

/// Settings read from `Documents/_dev/overrides.json` at launch.
///
/// This exists because of the build loop, not in spite of it. A round trip to
/// a CI runner and back through Sideloadly is minutes, so a build that can
/// only answer one question is expensive. The file is visible in the Files app
/// under *On My iPhone ▸ Advanced Notes ▸ _dev*, so thresholds can be changed
/// on the phone and the app relaunched.
///
/// It is also the only practical way to tune `fileFloor`. Apple's embedder has
/// its own geometry and nobody knows the right value yet: the Python app
/// measured 0.23 for feature hashing and 0.656 for `nomic-embed-text`, three
/// times apart for the same code.
struct DevOverrides: Decodable {

    /// How many notes to accumulate before collections may form.
    ///
    /// Defaults to the Python app's measured 20. Lower it to see filing
    /// happen without typing twenty notes first — the reason for 20 is real
    /// (an empty vault has no centroids, so early notes would each invent a
    /// collection from their own incidental wording), but a prototype needs to
    /// reach the interesting part in one sitting.
    var coldStartNotes: Int?

    var fileFloor: Double?
    var reviewFloor: Double?
    var minMargin: Double?
    var dedupeName: Double?
    var dedupeCentroid: Double?
    var maxCollections: Double?

    /// Skip the model entirely and file on retrieval alone. Useful for
    /// separating two questions that otherwise arrive together: whether the
    /// embeddings cluster, and whether the model picks well from them.
    var retrievalOnly: Bool?

    static let relativePath = "_dev/overrides.json"

    /// Never throws. A malformed file must not stop the app starting — that
    /// would turn a debugging aid into a way to brick the install.
    static func load() -> (overrides: DevOverrides, notes: [String]) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent(relativePath)

        guard let data = try? Data(contentsOf: url) else {
            return (DevOverrides(), [])
        }
        guard let decoded = try? JSONDecoder().decode(DevOverrides.self, from: data) else {
            Log.vault.error("overrides.json could not be read; ignoring it")
            return (DevOverrides(), ["overrides.json is not valid JSON; ignored"])
        }
        Log.vault.notice("overrides.json applied")
        return (decoded, ["overrides.json applied"])
    }

    /// Merge into a preset, reporting anything refused rather than silently
    /// clamping it. An impossible threshold means the thing that produced it is
    /// wrong, and that is worth seeing.
    func apply(to base: Thresholds) -> (thresholds: Thresholds, rejected: [String]) {
        var values: [String: Double] = [:]
        if let fileFloor { values["fileFloor"] = fileFloor }
        if let reviewFloor { values["reviewFloor"] = reviewFloor }
        if let minMargin { values["minMargin"] = minMargin }
        if let dedupeName { values["dedupeName"] = dedupeName }
        if let dedupeCentroid { values["dedupeCentroid"] = dedupeCentroid }
        if let maxCollections { values["maxCollections"] = maxCollections }

        var merged = base
        let rejected = merged.apply(overrides: values)

        // If the two floors end up the wrong way round, keep the preset and
        // say so. Silently repairing it would hide a typo that changes every
        // filing decision.
        if (try? merged.validated()) == nil {
            return (base, rejected + ["the merged thresholds were not valid; kept the defaults"])
        }
        return (merged, rejected)
    }

    /// The threshold lines the old template shipped, with the values it
    /// shipped them at.
    ///
    /// Written by the app, not chosen by anyone: the template had all three
    /// live, carrying the preset's own numbers.
    static let shippedThresholds = [
        ("fileFloor", "0.820"),
        ("reviewFloor", "0.865"),
        ("minMargin", "0.012")
    ]

    /// Retire those lines, once, on a file that still has them.
    ///
    /// An override outranks a measurement on purpose - someone typing a number
    /// means it. But these three were typed by the app, so on any phone that
    /// ran an earlier build they would shadow every calibration: you would
    /// press Calibrate, watch it measure, and see filing behave exactly as
    /// before. Commented out with the file's own underscore convention, values
    /// intact, so nothing is lost and switching one back on is one character.
    ///
    /// Matched on the exact text the template wrote. A value that has been
    /// changed does not match, and is left alone - which is the entire point
    /// of the file.
    @discardableResult
    static func retireShippedThresholds(in vaultRoot: URL) -> [String] {
        let url = vaultRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var updated = text
        var retired: [String] = []
        for (key, value) in shippedThresholds {
            let line = "\"\(key)\": \(value)"
            guard updated.contains(line) else { continue }
            updated = updated.replacingOccurrences(of: line, with: "\"_\(key)\": \(value)")
            retired.append(key)
        }
        guard !retired.isEmpty else { return [] }

        do {
            try AtomicFile.write(updated, to: url)
            return retired
        } catch {
            Log.vault.error("could not tidy overrides.json: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Written on first launch so the file is there to edit, rather than
    /// something you have to know to create.
    static func writeTemplateIfMissing(in vaultRoot: URL) {
        let url = vaultRoot.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let template = """
            {
              "_comment": "Edit, then reopen the app. Delete a line to use the default.",

              "_coldStartNotes": "notes before collections may form. 20 is the measured default and the one in force; remove the underscore below to use 5 instead, which reaches filing in one sitting while trying it out.",
              "_coldStartNotes_tryItOut": 5,

              "_thresholds": "Calibrate on the diagnostics page measures these on this device and they are used automatically. Remove the underscore from a key below to pin it by hand instead - a number here outranks the measurement.",

              "_fileFloor": 0.820,
              "_fileFloor_note": "below this similarity a note waits in Inbox. The preset: unrelated notes score ~0.840, related ~0.896",
              "_reviewFloor": 0.865,
              "_reviewFloor_note": "above fileFloor but below this: filed, but flagged",
              "_minMargin": 0.012,
              "_minMargin_note": "the winner must beat the runner-up by this much",

              "_retrievalOnly": "true skips the language model and files on similarity alone",
              "retrievalOnly": false
            }

            """
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(template.utf8).write(to: url)
    }
}
