import Foundation
import NotesCore

/// Thresholds measured on this device, kept, and put into force.
///
/// Calibration used to measure, recommend, and stop. The six numbers it
/// derived had to be copied by hand into `overrides.json` — on a phone
/// keyboard, from a JSON blob on a diagnostics page — which is the kind of
/// step that never actually happens, so the app went on filing with a preset
/// guess while a measurement of the real geometry sat in the log.
///
/// It is also the one number in the app that genuinely cannot be guessed off
/// the device: `fileFloor` was 0.23 for the Python app's hashing embedder and
/// 0.656 for `nomic-embed-text`, the same code three times apart. A preset is
/// a placeholder for exactly this file.
///
/// Stored in the vault rather than in Application Support, next to
/// `_lab/embeddings.json`: it is readable in the Files app, which is how
/// everything else in this project is inspected, and deleting it is a clean
/// way back to the preset.
///
/// Deliberately not isolated. It holds no state, and the isolation traps on
/// this project have all come from helpers that inherited an actor they did
/// not need — see `Respond`.
enum CalibratedThresholds {

    static let relativePath = "_lab/calibrated.json"

    struct Stored: Codable {
        var measuredAt: String
        /// Kept alongside the numbers so a later reader can see what they were
        /// derived from. A set of thresholds from a 0.055 gap and one from a
        /// 0.30 gap deserve different amounts of trust, and the numbers alone
        /// do not say which is which.
        var gap: Double
        var verdict: String
        var thresholds: Thresholds
    }

    static func url(in vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(relativePath)
    }

    static func save(_ stored: Stored, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: url, options: .atomic)
    }

    /// Never throws. A corrupt file means the preset is used, which is the
    /// state the app was in before this existed — not a reason to fail to
    /// start.
    static func load(from url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            Log.vault.error("calibrated.json could not be read; using the preset")
            return nil
        }
        return stored
    }

    /// The numbers actually in force, and what to say about how they got there.
    ///
    /// Three sources in order of authority:
    ///
    /// 1. the shipped preset, which is a guess;
    /// 2. a calibration measured on this device, which is evidence;
    /// 3. `overrides.json`, which is someone typing a number on purpose.
    ///
    /// A measurement beats a guess, and a person beats both — they may be
    /// testing a hunch, and an app that silently reverted their edit would be
    /// unusable for that. The one rule with teeth is the embedder check:
    /// thresholds are a property of a vector space, so a calibration measured
    /// against another embedder or another asset revision is not merely stale,
    /// it is meaningless.
    static func effective(
        preset: Thresholds,
        calibrated: Stored?,
        overrides: DevOverrides,
        embedderID: String
    ) -> (thresholds: Thresholds, notes: [String]) {
        var notes: [String] = []
        var base = preset

        if let calibrated {
            if calibrated.thresholds.embedderID == embedderID {
                base = calibrated.thresholds
                notes.append(
                    "using thresholds measured here on \(calibrated.measuredAt) "
                        + String(format: "(gap %.4f, %@)", calibrated.gap, calibrated.verdict)
                )
            } else {
                notes.append(
                    "ignored a calibration measured against \(calibrated.thresholds.embedderID); "
                        + "this device reports \(embedderID)"
                )
            }
        }

        let (merged, rejected) = overrides.apply(to: base)
        return (merged, notes + rejected)
    }
}
