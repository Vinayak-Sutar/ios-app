import Foundation

/// A collection the note might belong to, as retrieval ranks them.
public struct Candidate: Sendable, Equatable {
    public let path: String
    public let similarity: Double
    public let noteCount: Int

    public init(path: String, similarity: Double, noteCount: Int) {
        self.path = path
        self.similarity = similarity
        self.noteCount = noteCount
    }
}

/// What the model may answer. The slot cases map positionally onto the numbered
/// list the prompt showed it.
public enum ModelChoice: Sendable, Equatable {
    case slot(Int)                  // 1-based, matching the prompt's numbering
    case newCollection(String)
    case noneFit
}

public enum Outcome: String, Sendable, Codable {
    /// Filed, and we are confident enough not to mention it.
    case filed
    /// Filed, but flagged -- the user should glance at it.
    case review
    /// Unfiled. One tap from filed, and visible rather than lost, which is the
    /// whole argument for a high Inbox rate.
    case inbox
}

public struct Decision: Sendable, Equatable {
    public var topicPath: String?
    public var outcome: Outcome
    public var confidence: Double
    /// Short human-readable trace, surfaced on the diagnostics page. With no
    /// debugger this is how a bad filing decision gets explained.
    public var reason: String
    public var usedModel: Bool
    public var createdCollection: Bool

    public init(
        topicPath: String?,
        outcome: Outcome,
        confidence: Double,
        reason: String,
        usedModel: Bool,
        createdCollection: Bool = false
    ) {
        self.topicPath = topicPath
        self.outcome = outcome
        self.confidence = confidence
        self.reason = reason
        self.usedModel = usedModel
        self.createdCollection = createdCollection
    }

    /// Inbox means unfiled. Leaving a path attached to an inbox outcome would
    /// silently file the note anyway and quietly empty the triage queue -- a
    /// bug the Python code calls out by name, so it is enforced here instead of
    /// remembered.
    public static func inbox(reason: String, usedModel: Bool, confidence: Double = 0) -> Decision {
        Decision(
            topicPath: nil,
            outcome: .inbox,
            confidence: confidence,
            reason: reason,
            usedModel: usedModel
        )
    }
}

/// `retrieve -> decide -> validate -> tier`, ported from `mnemo/router.py` with
/// the six-check gate reduced to two checks for the prototype.
public enum Router {

    /// The margin between the best candidate and the runner-up.
    public static func margin(_ candidates: [Candidate]) -> Double {
        guard let best = candidates.first else { return 0 }
        guard candidates.count > 1 else { return best.similarity }
        return best.similarity - candidates[1].similarity
    }

    /// Whether retrieval is sure enough that asking the model would only add
    /// latency and risk.
    ///
    /// Worth not quietly "improving": measured on 40 held-out notes, retrieval
    /// alone was right 40/40 and a 4B model 34/40, and *every* deviation from
    /// retrieval's rank-1 was a mistake. So the maths ranks and the model names.
    public static func retrievalIsConfident(_ candidates: [Candidate], _ t: Thresholds) -> Bool {
        guard let best = candidates.first else { return false }
        return best.similarity >= t.reviewFloor && margin(candidates) >= t.minMargin
    }

    /// Decide from retrieval alone. Also the fallback whenever the model is
    /// unavailable, refuses, or answers off-menu -- which is why it has to be a
    /// real decision procedure and not a stub.
    public static func decideFromRetrieval(
        _ candidates: [Candidate],
        _ t: Thresholds,
        usedModel: Bool = false
    ) -> Decision {
        guard let best = candidates.first else {
            return .inbox(reason: "no collections to compare against yet", usedModel: usedModel)
        }
        let m = margin(candidates)
        let confidence = min(1.0, best.similarity + m)

        if best.similarity >= t.reviewFloor && m >= t.minMargin {
            return Decision(
                topicPath: best.path,
                outcome: .filed,
                confidence: confidence,
                reason: String(format: "clear match (%.3f, margin %.3f)", best.similarity, m),
                usedModel: usedModel
            )
        }
        if best.similarity >= t.fileFloor {
            return Decision(
                topicPath: best.path,
                outcome: .review,
                confidence: confidence,
                reason: String(format: "likely match, worth a look (%.3f, margin %.3f)", best.similarity, m),
                usedModel: usedModel
            )
        }
        return .inbox(
            reason: String(format: "nothing close enough (best %.3f)", best.similarity),
            usedModel: usedModel,
            confidence: confidence
        )
    }

    /// Apply the model's answer, having validated it against the slate we
    /// actually showed it.
    ///
    /// Apple's guided generation guides rather than strictly constrains, so an
    /// out-of-range slot is an expected answer, not a freak event. It falls
    /// back to retrieval rather than being trusted or discarded.
    public static func apply(
        choice: ModelChoice,
        candidates: [Candidate],
        thresholds t: Thresholds,
        existingCollections: [String],
        collectionCount: Int
    ) -> Decision {
        switch choice {
        case let .slot(index):
            guard index >= 1, index <= candidates.count else {
                return decideFromRetrieval(
                    candidates, t, usedModel: true
                ).withReason("model picked slot \(index), off the menu of \(candidates.count); used retrieval")
            }
            let picked = candidates[index - 1]
            // The model agreeing with retrieval's rank-1 is the common case and
            // the one we trust most.
            let agreesWithRetrieval = index == 1
            let outcome: Outcome = (agreesWithRetrieval && picked.similarity >= t.fileFloor) ? .filed : .review
            return Decision(
                topicPath: picked.path,
                outcome: outcome,
                confidence: min(1.0, picked.similarity + margin(candidates)),
                reason: agreesWithRetrieval
                    ? String(format: "model and retrieval agree (%.3f)", picked.similarity)
                    : String(format: "model chose %@ over retrieval's top pick", picked.path),
                usedModel: true
            )

        case let .newCollection(rawName):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.uppercased() != "NONE" else {
                return .inbox(reason: "model wanted a new collection but gave no name", usedModel: true)
            }
            guard collectionCount < t.maxCollections else {
                return decideFromRetrieval(candidates, t, usedModel: true)
                    .withReason("at the \(t.maxCollections)-collection cap; used retrieval instead")
            }
            // Check one: a name that already exists is that collection, not a
            // new one. Case and punctuation differences are not new topics.
            let slug = Slug.slugify(name)
            if let existing = existingCollections.first(where: { Slug.slugify($0) == slug }) {
                return Decision(
                    topicPath: existing,
                    outcome: .review,
                    confidence: 0.5,
                    reason: "proposed \"\(name)\", which is the existing \(existing)",
                    usedModel: true
                )
            }
            // A brand-new collection is never a silent decision.
            return Decision(
                topicPath: Slug.safeDirname(name),
                outcome: .review,
                confidence: 0.4,
                reason: "new collection \"\(name)\"",
                usedModel: true,
                createdCollection: true
            )

        case .noneFit:
            return .inbox(reason: "model found it too vague to file", usedModel: true)
        }
    }
}

extension Decision {
    public func withReason(_ reason: String) -> Decision {
        var copy = self
        copy.reason = reason
        return copy
    }
}
