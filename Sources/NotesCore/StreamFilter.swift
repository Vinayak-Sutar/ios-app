import Foundation

/// Holds back a trailing `Sources:` line while a model's answer streams.
///
/// Models trained on citation habits like to end with `Sources: 1, 2` whether
/// or not you asked. The chat already sends its sources as a separate event up
/// front, so that line is noise — but it cannot simply be stripped at the end,
/// because the text is shown token by token as it arrives and would flash on
/// screen before the answer finished.
///
/// So: anything that might still turn out to be that line is withheld, and
/// released the moment it proves not to be. The hard part is that the phrase
/// arrives split at arbitrary points — `"Sou"`, `"rces"`, `":"` — which is
/// exactly what makes this worth a state machine and a test rather than a
/// `hasSuffix` check.
public struct SourcesLineFilter: Sendable {

    /// What a trailing citation line can start with.
    static let marker = "Sources:"

    /// Text withheld because it might still become a citation line. Only ever
    /// holds text that began at a line start.
    private var held = ""
    /// Whether `held` began right after a newline.
    ///
    /// Without this the filter forgets where it is the moment it releases the
    /// newline: the next chunk arrives with no newline in it, looks like
    /// ordinary mid-line text, and the marker slips through one character at a
    /// time.
    private var heldIsLineStart = false

    public init() {}

    /// Feed a chunk; get back the text that is safe to display now.
    public mutating func push(_ chunk: String) -> String {
        let buffer = held + chunk
        held = ""

        // A citation line starts a line, so only text after the last newline
        // is a candidate.
        if let lastBreak = buffer.lastIndex(of: "\n") {
            let tailStart = buffer.index(after: lastBreak)
            let tail = String(buffer[tailStart...])
            if Self.couldBecomeMarker(tail) {
                held = tail
                heldIsLineStart = true
                return String(buffer[..<tailStart])
            }
            heldIsLineStart = false
            return buffer
        }

        // No newline in this buffer. If we were already withholding a
        // line-start tail, this chunk continues it.
        if heldIsLineStart {
            if Self.couldBecomeMarker(buffer) {
                held = buffer
                return ""
            }
            heldIsLineStart = false
            return buffer
        }

        // Mid-line, or the very first line — which is never withheld, since a
        // citation line is never the whole of an answer.
        return buffer
    }

    /// Call when the stream ends. Returns whatever was held back and is not a
    /// citation line after all.
    public mutating func finish() -> String {
        let remaining = held
        held = ""
        heldIsLineStart = false
        let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(Self.marker.lowercased()) {
            return ""
        }
        return remaining
    }

    /// True while `text` is still a viable prefix of a citation line, or has
    /// become one. `"Sou"` is viable; `"Sorry"` is not.
    static func couldBecomeMarker(_ text: String) -> Bool {
        let candidate = text.lowercased()
        let target = marker.lowercased()
        if candidate.isEmpty { return true }
        if candidate.count < target.count {
            return target.hasPrefix(candidate)
        }
        return candidate.hasPrefix(target)
    }
}
