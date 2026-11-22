import FlyingFox
import Foundation
import FoundationModels
import NotesCore

/// "Ask your notes": retrieval, then the on-device model, streamed.
///
/// The wire format is newline-delimited JSON, one event per line, taken from
/// `app.html` itself rather than inferred — the page ships a mock chat
/// implementation that is effectively the protocol spec:
///
///     {"type":"sources","notes":[{"id","title","topic"}]}
///     {"type":"token","text":"..."}
///     {"type":"done","fromNotes":true}
///     {"type":"error","message":"..."}
///
/// Sources go out **before** the first token, which is why the model is never
/// asked to cite anything: the citations are already on screen, and asking for
/// them again just invites a `Sources:` line to leak into the prose.
@MainActor
final class Chat {

    private let vault: Vault
    private let embedding: EmbedderBox
    private let thresholds: () -> Thresholds

    /// How many notes to put in front of the model.
    ///
    /// Six, not everything. The on-device context is finite and the excerpts
    /// have to share it with the question, the instructions and the answer —
    /// and a note that ranked seventh is rarely what was being asked about.
    static let maxNotes = 6
    /// Characters per excerpt. Enough to answer from, short enough that six of
    /// them fit.
    static let excerptChars = 700

    init(vault: Vault, embedding: EmbedderBox, thresholds: @escaping () -> Thresholds) {
        self.vault = vault
        self.embedding = embedding
        self.thresholds = thresholds
    }

    struct Request {
        var message: String
        var history: [(role: String, content: String)]
    }

    /// Answer as a stream of events, written as they are produced.
    ///
    /// The sources go out the moment retrieval finishes, before the model has
    /// written a word. That is most of the value: on-device generation takes
    /// seconds, and during those seconds the user can already be reading which
    /// of their notes this is going to be answered from.
    ///
    /// Returns immediately; the work happens in the returned stream.
    func stream(to request: Request) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let work = Task { @MainActor in
                func emit(_ event: [String: Any]) {
                    guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
                    continuation.yield(data + Data("\n".utf8))
                }

                let picked = await retrieve(for: request.message)
                emit([
                    "type": "sources",
                    "notes": picked.map { entry in
                        [
                            "id": entry.note.id,
                            "title": entry.note.title.isEmpty ? "Untitled" : entry.note.title,
                            "topic": entry.note.primaryTopic as Any? ?? NSNull()
                        ]
                    }
                ])

                guard Intelligence.availability.isAvailable else {
                    if picked.isEmpty {
                        emit(["type": "error", "message": "The on-device model isn't available yet."])
                    } else {
                        emit(["type": "token", "text": Self.fallbackAnswer(picked)])
                        emit(["type": "done", "fromNotes": true])
                    }
                    continuation.finish()
                    return
                }

                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let prompt = Self.prompt(
                        message: request.message, notes: picked, history: request.history
                    )

                    // Snapshots are cumulative, so each one is diffed against
                    // the last to get the new text. Sending the snapshot
                    // itself would repeat the whole answer on every tick.
                    var sent = ""
                    var filter = SourcesLineFilter()
                    for try await snapshot in session.streamResponse(
                        to: prompt, options: GenerationOptions(sampling: .greedy)
                    ) {
                        let whole = String(describing: snapshot)
                        guard whole.count > sent.count, whole.hasPrefix(sent) else { continue }
                        let delta = String(whole.dropFirst(sent.count))
                        sent = whole
                        let safe = filter.push(delta)
                        if !safe.isEmpty { emit(["type": "token", "text": safe]) }
                    }
                    let tail = filter.finish()
                    if !tail.isEmpty { emit(["type": "token", "text": tail]) }

                    emit(["type": "done", "fromNotes": !picked.isEmpty])
                } catch {
                    Log.model.error("chat failed: \(error.localizedDescription, privacy: .public)")
                    emit([
                        "type": "error",
                        "message": "The on-device model couldn't answer that: \(error.localizedDescription)"
                    ])
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// The collected form, kept for the self-test: it needs the whole answer
    /// to assert on, and a test that consumed a stream would be testing the
    /// stream rather than the answer.
    func respond(to request: Request) async -> Data {
        var lines: [String] = []

        func emit(_ event: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: event),
                  let text = String(data: data, encoding: .utf8) else { return }
            lines.append(text)
        }

        let picked = await retrieve(for: request.message)
        emit([
            "type": "sources",
            "notes": picked.map { entry in
                [
                    "id": entry.note.id,
                    "title": entry.note.title.isEmpty ? "Untitled" : entry.note.title,
                    "topic": entry.note.primaryTopic as Any? ?? NSNull()
                ]
            }
        ])

        guard Intelligence.availability.isAvailable else {
            // Degrades to listing what search found. The Python app does the
            // same: a question still gets the notes even when the model is
            // unavailable, which beats an error for the common case of assets
            // still downloading.
            if picked.isEmpty {
                emit(["type": "error", "message": "The on-device model isn't available yet."])
            } else {
                emit(["type": "token", "text": Self.fallbackAnswer(picked)])
                emit(["type": "done", "fromNotes": true])
            }
            return Self.body(lines)
        }

        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(
                to: Self.prompt(message: request.message, notes: picked, history: request.history),
                options: GenerationOptions(sampling: .greedy)
            )

            // Even unasked, a model may end with a citation line. Filtering it
            // through the same state machine the streaming path would use
            // keeps one behaviour rather than two.
            var filter = SourcesLineFilter()
            var text = filter.push(response.content)
            text += filter.finish()

            if !text.isEmpty { emit(["type": "token", "text": text]) }
            emit(["type": "done", "fromNotes": !picked.isEmpty])
        } catch {
            Log.model.error("chat failed: \(error.localizedDescription, privacy: .public)")
            emit([
                "type": "error",
                "message": "The on-device model couldn't answer that: \(error.localizedDescription)"
            ])
        }

        return Self.body(lines)
    }

    private static func body(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - Retrieval

    /// Pick the notes to answer from.
    ///
    /// A note whose title is named in the question is always included, however
    /// it ranks — "what did I write in the trip note?" should not depend on
    /// cosine similarity finding it.
    private func retrieve(for question: String) async -> [Vault.Entry] {
        let vector = await embedding.embed(question)
        var picked: [Vault.Entry] = []
        var seen = Set<String>()

        let lowered = question.lowercased()
        for entry in vault.entries.values {
            let title = entry.note.title.lowercased()
            guard title.count >= 4, lowered.contains(title) else { continue }
            if seen.insert(entry.note.id).inserted { picked.append(entry) }
        }

        let hits = vault.search(question, vector: vector, limit: Self.maxNotes * 2)
        let floor = thresholds().fileFloor * 0.5
        let best = hits.first?.score ?? 0

        for hit in hits where picked.count < Self.maxNotes {
            // Keep only what is close to the best match. A long tail of weak
            // hits is how a grocery list ends up cited in an answer about
            // something else.
            guard hit.score >= max(floor, best - 0.15) else { continue }
            if seen.insert(hit.entry.note.id).inserted { picked.append(hit.entry) }
        }
        return picked
    }

    private static func fallbackAnswer(_ notes: [Vault.Entry]) -> String {
        let titles = notes.prefix(5).map { "- **\($0.note.title.isEmpty ? "Untitled" : $0.note.title)**" }
        return """
            I can't answer from the model right now, but these notes look relevant:

            \(titles.joined(separator: "\n"))
            """
    }

    // MARK: - Prompt

    static let instructions = """
        You are the assistant inside a private notes app. Everything runs on \
        the user's own phone. Answer from the notes you are given when they are \
        relevant. Be brief: plain words, short paragraphs, '-' bullets, note \
        titles in bold. If the notes do not answer the question, say so in one \
        short sentence. Never invent notes, dates or reminders. Do not list \
        your sources; they are already shown to the user.
        """

    static func prompt(
        message: String,
        notes: [Vault.Entry],
        history: [(role: String, content: String)]
    ) -> String {
        var out = ""

        if notes.isEmpty {
            out += "NOTES: none matched.\n\n"
        } else {
            out += "NOTES:\n"
            for (index, entry) in notes.enumerated() {
                let title = entry.note.title.isEmpty ? "Untitled" : entry.note.title
                var line = "[\(index + 1)] \(title)"
                if let topic = entry.note.primaryTopic { line += " (collection: \(topic))" }
                if let due = entry.note.due { line += " (due: \(due))" }
                out += line + "\n"
                out += String(entry.note.body.prefix(excerptChars)) + "\n\n"
            }
        }

        // Only the last couple of turns: the context is finite and older turns
        // crowd out the notes, which are the part that actually answers.
        let recent = history.suffix(4)
        if !recent.isEmpty {
            out += "EARLIER:\n"
            for turn in recent {
                out += "\(turn.role): \(String(turn.content.prefix(300)))\n"
            }
            out += "\n"
        }

        out += "QUESTION: " + message
        return out
    }
}
