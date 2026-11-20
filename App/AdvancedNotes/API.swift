import Foundation
import NotesCore

/// The JSON `app.html` expects, field for field.
///
/// Every shape here was **recorded** from `python -m mnemo serve`, not inferred
/// — see `Tests/NotesCoreTests/Golden/api/`. That mattered immediately:
/// `/api/graph` returns `{links, nodes}` where a reasonable guess says
/// `{nodes, edges}`, and a field the page reads but we never send renders as
/// `undefined` with no error anywhere. Keys are lowerCamelCase exactly as
/// captured, so no `CodingKeys` and no key-encoding strategy.
enum API {

    /// A note as it appears in a list. `mnemo/server.py` calls this
    /// `_note_brief`.
    struct NoteBrief: Encodable {
        var id: String
        var title: String
        var kind: String
        var status: String
        var path: String?
        /// The primary collection, or nil for Inbox. The page shows a colour
        /// dot per collection and treats nil as unfiled.
        var topic: String?
        var snippet: String
        var created: String
        var updated: String
        var review: Bool
        var due: String?
        var remind: Bool
        var done: Bool
        var media: String?
        var source: String?
        /// Preview rows the list and tile views render directly.
        var lines: [Line]
        /// `[done, total]` for a checklist, nil otherwise.
        var progress: [Int]?

        struct Line: Encodable {
            /// "text", "head" or "check".
            var t: String
            var text: String
            var done: Bool?
            var line: Int?
            var remind: String?
        }
    }

    /// `_note_detail`: a brief plus the body and its relationships.
    struct NoteDetail: Encodable {
        var id: String
        var title: String
        var kind: String
        var status: String
        var path: String?
        var topic: String?
        var topics: [String]
        var snippet: String
        var body: String
        var created: String
        var updated: String
        var review: Bool
        var due: String?
        var remind: Bool
        var done: Bool
        var media: String?
        var source: String?
        var repeat_: String?
        var lines: [NoteBrief.Line]
        var progress: [Int]?
        var related: [NoteBrief]
        var links: [String]

        // `repeat` is a Swift keyword, so the property carries a trailing
        // underscore and is renamed on the way out.
        enum CodingKeys: String, CodingKey {
            case id, title, kind, status, path, topic, topics, snippet, body
            case created, updated, review, due, remind, done, media, source
            case lines, progress, related, links
            case repeat_ = "repeat"
        }
    }

    /// A node in the collection tree the sidebar draws.
    struct TopicNode: Encodable {
        var id: String
        var name: String
        var path: String
        var state: String
        /// Subtree total, which is what the sidebar badge shows.
        var count: Int
        /// Notes directly in this collection.
        var own: Int
        /// Type counts, drawn as lighter child rows: video, link, image, task.
        var views: [String: Int]
        var children: [TopicNode]
    }

    /// `/api/state` — the whole shell in one response, and the first thing the
    /// page asks for after its liveness probe.
    struct State: Encodable {
        var tree: [TopicNode]
        var inbox: Int
        var review: Int
        var notes: Int
        var topics: Int
        var embedder: String
        var router: String
        var profile: String
        var vault: String
        /// How many more notes before the vault is allowed to grow a taxonomy.
        /// 0 means filing is live.
        var coldStart: Int
        var embedderChanged: String?
        /// Always true here. The page uses this to decide whether the backend
        /// is reachable; a standalone app's backend is in-process, so there is
        /// no offline path to fall into.
        var laptop: Bool
        var paths: [String: String]
    }

    struct NotesList: Encodable { var notes: [NoteBrief] }
    struct InboxList: Encodable { var notes: [NoteBrief]; var review: [NoteBrief] }

    struct Agenda: Encodable {
        var notes: [NoteBrief]
        var items: [String]
        var lists: [String]
        var anytime: [NoteBrief]
    }

    struct Suggestion: Encodable {
        var path: String
        var similarity: Double
        var count: Int
    }
    struct Suggestions: Encodable { var suggestions: [Suggestion] }

    struct Hit: Encodable {
        var id: String
        var title: String
        var topic: String?
        var kind: String
        var snippet: String
        /// "fts", "vector" or "both" — the page shows nothing for it yet, but
        /// it is in the recorded shape.
        var via: String
        var score: Double
    }
    struct Hits: Encodable { var hits: [Hit] }

    /// What `/api/capture` answers with. The page builds its toast from this,
    /// so the fields it reads have to be present even when empty.
    struct CaptureResult: Encodable {
        var id: String
        var title: String
        var body: String
        var kind: String
        var due: String?
        var reminder: Bool
        var recurrence: String?
        var appendedTo: String?
        var listItems: [String]
        var pausedUntil: String?
        var appendCandidates: [String]
        var matched: String?
        var summary: String
        var topic: String?
        var path: String?
        /// "filed", "review" or "inbox".
        var outcome: String
        var related: Int
        var steered: Bool
        var bootstrapped: Int
        var promoted: [String]
    }

    // Empty-shaped stubs. Captured from the real server, so the page renders
    // its own designed empty states rather than erroring.
    struct Profiles: Encodable { var profiles: [String]; var current: String? }
    struct Lists: Encodable { var lists: [String] }
    struct Links: Encodable { var links: [String] }
    struct Garden: Encodable { var proposals: [String] }
    struct Graph: Encodable { var nodes: [String]; var links: [String] }
    struct Due: Encodable { var reminders: [String]; var rolled: Int }
    struct Ok: Encodable { var ok: Bool = true }
    struct Undone: Encodable { var undone: String? }
    struct Failure: Encodable { var error: String }
}

// MARK: - Building the DTOs from a note

extension API.NoteBrief {
    /// Markdown preview rows. Headings and checklist lines are recognised
    /// because the page styles them differently; everything else is text.
    static func previewLines(from body: String, limit: Int = 6) -> [Line] {
        var out: [Line] = []
        for (index, raw) in body.components(separatedBy: "\n").enumerated() {
            if out.count >= limit { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append(Line(t: "head", text: text, done: nil, line: index, remind: nil))
            } else if line.hasPrefix("- [") {
                let done = line.hasPrefix("- [x]") || line.hasPrefix("- [X]")
                let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                out.append(Line(t: "check", text: text, done: done, line: index, remind: nil))
            } else {
                let text = line.hasPrefix("- ")
                    ? String(line.dropFirst(2))
                    : line
                out.append(Line(t: "text", text: text, done: nil, line: index, remind: nil))
            }
        }
        return out
    }

    /// Markdown marks stripped, so a preview does not show `**` and `##`.
    static func snippet(from body: String, limit: Int = 220) -> String {
        var text = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > limit ? String(text.prefix(limit)) : text
    }

    init(_ note: Note, path: String?, needsReview: Bool) {
        self.id = note.id
        self.title = note.title.isEmpty ? "(untitled)" : note.title
        self.kind = note.kind
        self.status = note.status
        self.path = path
        self.topic = note.primaryTopic
        self.snippet = Self.snippet(from: note.body)
        self.created = note.created
        self.updated = note.updated
        self.review = needsReview
        self.due = note.due
        self.remind = note.remind != nil
        self.done = note.status == "done"
        self.media = note.media
        self.source = note.source
        self.lines = Self.previewLines(from: note.body)
        self.progress = nil
    }
}

extension API.NoteDetail {
    init(_ note: Note, path: String?, needsReview: Bool, related: [API.NoteBrief]) {
        let brief = API.NoteBrief(note, path: path, needsReview: needsReview)
        self.id = brief.id
        self.title = brief.title
        self.kind = brief.kind
        self.status = brief.status
        self.path = brief.path
        self.topic = brief.topic
        self.topics = note.topics
        self.snippet = brief.snippet
        self.body = note.body
        self.created = brief.created
        self.updated = brief.updated
        self.review = brief.review
        self.due = brief.due
        self.remind = brief.remind
        self.done = brief.done
        self.media = brief.media
        self.source = brief.source
        self.repeat_ = note.repeatRule
        self.lines = brief.lines
        self.progress = brief.progress
        self.related = related
        self.links = []
    }
}
