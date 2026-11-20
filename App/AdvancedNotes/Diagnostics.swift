import Foundation
import NaturalLanguage
import NotesCore
import UIKit

/// Everything M0 exists to find out, in one JSON document.
///
/// This is not a nicety. With no Mac there is no debugger, no Simulator and no
/// Instruments, so a page the app can render about itself is the primary
/// instrument. It keeps earning its place after M0: the threshold sliders and
/// the last routing decision live here too.
@MainActor
final class Diagnostics {

    private let intelligence: Intelligence
    private let vault: VaultProbe
    /// Shared with the capture pipeline. Two `AppleEmbedder`s would mean
    /// loading the model assets twice for no reason.
    private let embedding: EmbedderBox
    private var lastProbes: Probes?

    init(embedding: EmbedderBox) {
        self.intelligence = Intelligence()
        self.vault = VaultProbe()
        self.embedding = embedding
    }

    private var embedder: AppleEmbedder? { embedding.embedder }

    // MARK: - Report

    struct Report: Encodable {
        var app: AppInfo
        var model: ModelInfo
        var embedder: EmbedderInfo
        var sentenceEmbedding: SentenceEmbeddingInfo
        var storage: StorageInfo
        var thresholds: Thresholds
        var probes: Probes?
        /// What the build actually put in the bundle. A missing app.html is a
        /// plausible cause of a blank screen, and this says so outright.
        var bundle: [String]
        var generatedAt: String
    }

    struct AppInfo: Encodable {
        var version: String
        var build: String
        var iosVersion: String
        var device: String
    }

    struct ModelInfo: Encodable {
        /// Apple's own availability reason, verbatim. It is the only error
        /// message the framework gives, so it is not paraphrased.
        var availability: String
        var isAvailable: Bool
    }

    struct EmbedderInfo: Encodable {
        var ok: Bool
        var detail: String?
        var embedderID: String?
        /// Read at runtime, never hardcoded: Apple documents these properties
        /// without publishing their values, and they differ between iOS and
        /// macOS.
        var dimension: Int?
        var maximumSequenceLength: Int?
        var modelIdentifier: String?
        var revision: Int?
        var hasAvailableAssets: Bool?
    }

    /// Apple's own docs point at `NLEmbedding` rather than the contextual
    /// embedder for semantic similarity, so both are measured. If the simpler
    /// one separates topics just as well, the MVP should use it.
    struct SentenceEmbeddingInfo: Encodable {
        var ok: Bool
        var dimension: Int?
        var detail: String?
    }

    struct StorageInfo: Encodable {
        var vaultPath: String
        var visibleInFilesApp: Bool
        var writable: Bool
        var detail: String?
        var noteCount: Int
    }

    struct Probes: Encodable {
        var modelProbe: String
        var modelLatencyMS: Int?
        var separation: Separation?
        var ranAt: String
    }

    /// The question this prototype exists to answer, in miniature: do related
    /// notes sit closer together than unrelated ones?
    ///
    /// If `withinTopic` is not clearly above `acrossTopics`, no threshold will
    /// make auto-filing work and that is worth knowing in week one rather than
    /// week eight.
    struct Separation: Encodable {
        var withinTopic: Double
        var acrossTopics: Double
        var gap: Double
        var verdict: String
        var samples: Int
        var elapsedMS: Int
    }

    func report() async -> Report {
        let bundle = Bundle.main
        let info = AppInfo(
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            iosVersion: UIDevice.current.systemVersion,
            device: Self.hardwareIdentifier()
        )

        let availability = Intelligence.availability
        let model = ModelInfo(availability: availability.describe, isAvailable: availability.isAvailable)

        return Report(
            app: info,
            model: model,
            embedder: await embedderInfo(),
            sentenceEmbedding: Self.sentenceEmbeddingInfo(),
            storage: vault.info(),
            thresholds: Thresholds.appleGuess(embedderID: embedder?.embedderID ?? "unknown"),
            probes: lastProbes,
            bundle: Respond.bundleListing(),
            generatedAt: Timestamp.utcNow()
        )
    }

    // MARK: - Probes

    func runProbes() async -> Report {
        let start = Date()
        let probe = await intelligence.probe()
        let latency = Int(Date().timeIntervalSince(start) * 1000)

        let answer: String
        switch probe {
        case let .success(word): answer = "ok: \(word)"
        case let .failure(error): answer = "failed: \(error)"
        }

        lastProbes = Probes(
            modelProbe: answer,
            modelLatencyMS: latency,
            separation: await measureSeparation(),
            ranAt: Timestamp.utcNow()
        )
        return await report()
    }

    private func embedderInfo() async -> EmbedderInfo {
        await embedding.prepare()
        guard let embedder else {
            return EmbedderInfo(ok: false, detail: embedding.failure ?? "not initialised")
        }
        return EmbedderInfo(
            ok: true,
            detail: nil,
            embedderID: embedder.embedderID,
            dimension: embedder.dimension,
            maximumSequenceLength: embedder.maximumSequenceLength,
            modelIdentifier: embedder.modelIdentifier,
            revision: embedder.revision,
            hasAvailableAssets: embedder.hasAvailableAssets
        )
    }

    /// Six short notes in two obvious topics. Mean similarity inside a topic
    /// versus across topics tells us immediately whether these vectors can
    /// carry the filing decision.
    private func measureSeparation() async -> Separation? {
        guard let embedder else { return nil }

        let gaming = [
            "Malenia waterfowl dance timing is brutal, bloodhound step on the second swing",
            "The RTX 4070 undervolt saves about 30 watts with no framerate loss",
            "Finished the Elden Ring DLC on NG+ without summoning"
        ]
        let cooking = [
            "Sourdough levain at 100 percent hydration doubles in about five hours",
            "Banneton proofing overnight in the fridge gives a better crumb",
            "Toast the spices before grinding them or the curry tastes flat"
        ]

        let start = Date()
        var gamingVectors: [[Float]] = []
        var cookingVectors: [[Float]] = []
        do {
            gamingVectors = try gaming.map { try embedder.embed($0) }
            cookingVectors = try cooking.map { try embedder.embed($0) }
        } catch {
            Log.embed.error("separation probe failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard gamingVectors.allSatisfy({ !$0.isEmpty }), cookingVectors.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        func meanPairwise(_ a: [[Float]], _ b: [[Float]], sameSet: Bool) -> Double {
            var total = 0.0
            var count = 0
            for (i, x) in a.enumerated() {
                for (j, y) in b.enumerated() where !(sameSet && j <= i) {
                    total += Vectors.cosine(x, y)
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 0
        }

        let within = (
            meanPairwise(gamingVectors, gamingVectors, sameSet: true)
            + meanPairwise(cookingVectors, cookingVectors, sameSet: true)
        ) / 2
        let across = meanPairwise(gamingVectors, cookingVectors, sameSet: false)
        let gap = within - across

        // Bands are a first read, not a calibration. The real thresholds come
        // from tuning against actual notes in M1.
        let verdict: String
        switch gap {
        case ..<0.02: verdict = "no usable separation — auto-filing will not work with these vectors"
        case ..<0.08: verdict = "weak separation — expect a lot of Inbox"
        case ..<0.20: verdict = "workable separation"
        default: verdict = "strong separation"
        }

        Log.embed.notice("separation within=\(within) across=\(across) gap=\(gap)")

        return Separation(
            withinTopic: within,
            acrossTopics: across,
            gap: gap,
            verdict: verdict,
            samples: gaming.count + cooking.count,
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    private static func sentenceEmbeddingInfo() -> SentenceEmbeddingInfo {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return SentenceEmbeddingInfo(ok: false, dimension: nil, detail: "no sentence embedding for English")
        }
        return SentenceEmbeddingInfo(ok: true, dimension: embedding.dimension, detail: nil)
    }

    private static func hardwareIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
}
