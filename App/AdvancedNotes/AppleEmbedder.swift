import Foundation
import NaturalLanguage
import NotesCore

/// Turns a note into one vector using Apple's on-device contextual embedder.
///
/// **An actor, deliberately.** `requestAssets()` can download a model over the
/// network and `load()` pulls it into memory; on a fresh install that is
/// seconds at best. Running either on the main actor freezes the UI *and*
/// stalls every route that needs main-actor state — which on the first real
/// device launch presented as a blank page with an unresponsive button, since
/// `/api/state` could not be served while the model loaded. Isolating this
/// type moves that work to a background executor.
///
/// `NLContextualEmbedding` returns vectors at the *subword* level — Apple's own
/// docs say to "pool or combine subword vectors" for a whole-text
/// representation — so a note vector is the mean of its token vectors,
/// L2-normalised.
///
/// Two things here are load-bearing and easy to get wrong:
///
/// 1. **One model, always.** Several underlying models exist, selected by
///    language. Vectors from two different models share no geometry, so a
///    Spanish note and an English note embedded by different models would be
///    compared under a single cosine threshold and the taxonomy would corrupt
///    silently. So the script is pinned and used for every note, and foreign
///    text is simply embedded a bit worse.
/// 2. **Nothing is hardcoded.** `dimension` and `maximumSequenceLength` are
///    read at runtime. Secondhand sources say 512 and ~256 on iOS, but Apple
///    documents the properties without publishing values and they differ on
///    macOS. The diagnostics page prints whatever the device actually says.
actor AppleEmbedder {

    enum Failure: Error, CustomStringConvertible {
        case unsupportedScript
        case assetsUnavailable(String)
        case loadFailed(String)

        var description: String {
            switch self {
            case .unsupportedScript:
                return "no contextual embedding model for this script"
            case let .assetsUnavailable(detail):
                return "embedding assets unavailable: \(detail)"
            case let .loadFailed(detail):
                return "embedding model would not load: \(detail)"
            }
        }
    }

    private let embedding: NLContextualEmbedding
    private let language: NLLanguage
    private var loaded = false

    /// Identifies the vector space these embeddings live in. Stored alongside
    /// every vector and baked into the threshold preset, so a model or asset
    /// revision change is detectable rather than silently reinterpreted.
    let embedderID: String

    /// A snapshot of what the model reports, so callers can read it without
    /// hopping onto this actor for every field.
    struct Info: Sendable {
        var embedderID: String
        var dimension: Int
        var maximumSequenceLength: Int
        var modelIdentifier: String
        var revision: Int
        var hasAvailableAssets: Bool
    }

    func info() -> Info {
        Info(
            embedderID: embedderID,
            dimension: embedding.dimension,
            maximumSequenceLength: embedding.maximumSequenceLength,
            modelIdentifier: embedding.modelIdentifier,
            revision: embedding.revision,
            hasAvailableAssets: embedding.hasAvailableAssets
        )
    }

    init(script: NLScript = .latin, language: NLLanguage = .english) throws {
        guard let embedding = NLContextualEmbedding(script: script) else {
            throw Failure.unsupportedScript
        }
        self.embedding = embedding
        self.language = language
        self.embedderID = "nl-contextual-\(embedding.modelIdentifier)-r\(embedding.revision)-d\(embedding.dimension)"
    }

    /// Downloads the model assets if needed, then loads them.
    ///
    /// A fresh install genuinely does not have these yet, so "not ready" is a
    /// normal first-run state and not an error worth alarming the user about.
    func prepare() async throws {
        if !embedding.hasAvailableAssets {
            // Assets download over the air, so a fresh install really does not
            // have them. Apple's own example uses this async form and compares
            // against `.available`.
            let result = try await embedding.requestAssets()
            guard result == .available else {
                throw Failure.assetsUnavailable("requestAssets returned \(result)")
            }
        }
        guard !loaded else { return }
        do {
            try embedding.load()
            loaded = true
            Log.embed.notice("embedder loaded: \(self.embedderID, privacy: .public)")
        } catch {
            throw Failure.loadFailed(error.localizedDescription)
        }
    }

    /// One L2-normalised vector for a piece of text.
    ///
    /// Text longer than the model's sequence limit is truncated rather than
    /// windowed: the MVP only needs to know whether these vectors cluster at
    /// all, and the first couple of hundred tokens carry nearly all the topical
    /// signal anyway. Windowed pooling is a later refinement.
    func embed(_ text: String) throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let clipped = String(trimmed.prefix(charLimit))
        let result = try embedding.embeddingResult(for: clipped, language: language)

        var sum = [Double](repeating: 0, count: embedding.dimension)
        var tokens = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            guard vector.count == sum.count else { return true }
            for i in 0..<vector.count { sum[i] += vector[i] }
            tokens += 1
            return true
        }
        guard tokens > 0 else { return [] }

        let mean = sum.map { Float($0 / Double(tokens)) }
        return Vectors.l2Normalise(mean)
    }

    /// A character budget that keeps us inside the token limit without needing
    /// the model's tokenizer. Roughly four characters per subword token, then
    /// a safety margin — overshooting only means the tail is ignored.
    private var charLimit: Int {
        max(256, embedding.maximumSequenceLength * 4 - 64)
    }
}
