import Foundation
import FoundationModels
import NotesCore

// MARK: - The shape we ask the model for

@Generable
enum NoteKind {
    case note, task, link, idea, reference
}

/// Which collection the note belongs in.
///
/// These are **positional slots**, not collection names, and the prompt shows
/// the candidates as a numbered list. That is a deliberate choice over having
/// the model echo a real collection id: Apple's guided generation guides rather
/// than strictly constrains, so a model asked for an id can return one that
/// does not exist, and a 26-character ULID is the worst possible thing to ask a
/// small model to transcribe. A compile-time enum of slot names costs one token
/// and multiple-choice-by-index is the most heavily trained output format there
/// is.
///
/// The cost is position bias — small models favour the first option — which is
/// why `Router` flags any pick that disagrees with retrieval's ranking instead
/// of filing it silently.
@Generable
enum CollectionChoice {
    case collection1, collection2, collection3, collection4
    case collection5, collection6, collection7, collection8
    case newCollection
    case noneFit

    /// 1-based slot number, or nil for the two non-slot answers.
    var slot: Int? {
        switch self {
        case .collection1: return 1
        case .collection2: return 2
        case .collection3: return 3
        case .collection4: return 4
        case .collection5: return 5
        case .collection6: return 6
        case .collection7: return 7
        case .collection8: return 8
        case .newCollection, .noneFit: return nil
        }
    }
}

/// One model call does intent *and* filing.
///
/// The Windows app has ~550 lines of hand-tuned rules for this, written that
/// way because a local 4B model was too slow for live feedback. Asking Apple's
/// model instead is the MVP's biggest simplification, and whether it holds up
/// is one of the questions this prototype exists to answer.
@Generable
struct CaptureReading {
    @Guide(description: "A short title for this note, at most 8 words. No quotes, no trailing full stop.")
    var title: String

    @Guide(description: "What kind of thing this note is.")
    var kind: NoteKind

    @Guide(description: "Which numbered collection this note belongs in.")
    var collection: CollectionChoice

    @Guide(description: "A name for a new collection, 1 to 3 words, or exactly NONE if an existing one fits.")
    var newCollectionName: String

    @Guide(description: "When the note implies a reminder, as yyyy-MM-dd HH:mm. Otherwise exactly NONE.")
    var due: String
}

// MARK: - The session wrapper

/// Everything that talks to the on-device model.
///
/// The one rule that matters: **the note is already saved to disk before any
/// method here is called.** The model can refuse perfectly ordinary content
/// with a guardrail violation — a note about a doctor's appointment is just the
/// kind of thing that trips it — so a refusal must cost a filing decision, not
/// a note.
@MainActor
final class Intelligence {

    enum Availability: Equatable {
        case available
        case unavailable(String)

        var isAvailable: Bool { self == .available }

        var describe: String {
            switch self {
            case .available: return "available"
            case let .unavailable(reason): return "unavailable: \(reason)"
            }
        }
    }

    /// Why the model cannot be used, in Apple's own words. This enum is the
    /// only error message the framework ever gives, so it is surfaced verbatim
    /// rather than translated into something friendlier and less useful.
    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable("deviceNotEligible")
            case .appleIntelligenceNotEnabled:
                return .unavailable("appleIntelligenceNotEnabled")
            case .modelNotReady:
                // Normal on a fresh install while assets download.
                return .unavailable("modelNotReady")
            @unknown default:
                return .unavailable("unknown reason")
            }
        @unknown default:
            return .unavailable("unknown availability")
        }
    }

    /// Greedy sampling always takes the most likely token, which is the
    /// temperature-0 equivalent. Temperature is ignored under greedy and there
    /// is no seed parameter, so this is the only determinism available —
    /// and it is still not stable across OS updates, which is why decisions
    /// are logged with the OS version.
    static let deterministic = GenerationOptions(sampling: .greedy)

    /// A minimal round trip, used by the diagnostics page to prove the model
    /// is reachable from app code and not merely from Shortcuts.
    func probe() async -> Result<String, Error> {
        guard Self.availability.isAvailable else {
            return .failure(ProbeError.unavailable(Self.availability.describe))
        }
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(
                to: "Reply with one lowercase word: the colour of a clear midday sky.",
                generating: ProbeAnswer.self,
                options: Self.deterministic
            )
            Log.model.notice("probe ok: \(response.content.word, privacy: .public)")
            return .success(response.content.word)
        } catch {
            Log.model.error("probe failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case unavailable(String)
        var description: String {
            switch self {
            case let .unavailable(detail): return detail
            }
        }
    }
}

@Generable
struct ProbeAnswer {
    @Guide(description: "A single lowercase word.")
    var word: String
}
