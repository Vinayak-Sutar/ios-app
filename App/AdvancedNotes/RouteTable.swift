import FlyingFox
import Foundation
import NotesCore

/// The `/api/…` surface `app.html` talks to.
///
/// Built in the order the page calls them, because that is the order a mistake
/// shows up in: `/api/profiles` is the page's liveness probe and must answer
/// fast or it falls back to its offline copy; then `/api/state` and
/// `/api/agenda` in parallel; then the lists.
///
/// Everything is shaped to the JSON recorded in
/// `Tests/NotesCoreTests/Golden/api/`. Routes the prototype does not implement
/// are stubbed with the right empty shape rather than left to 404, so the
/// page's own designed empty states render instead of an error.
@MainActor
final class RouteTable {

    private let diagnostics: Diagnostics
    private let vault: Vault
    private let capture: Capture
    private let embedding: EmbedderBox
    private let chat: Chat
    private let reminders: Reminders
    /// Held rather than constructed per request: `Intelligence` is
    /// main-actor-isolated, and the route closures are not, so building one
    /// inside a closure is a call across the boundary.
    private let intelligence: Intelligence

    init(
        diagnostics: Diagnostics,
        vault: Vault,
        capture: Capture,
        embedding: EmbedderBox,
        chat: Chat,
        reminders: Reminders,
        intelligence: Intelligence
    ) {
        self.diagnostics = diagnostics
        self.vault = vault
        self.capture = capture
        self.embedding = embedding
        self.chat = chat
        self.reminders = reminders
        self.intelligence = intelligence
    }

    func install(on server: HTTPServer) async {
        await installPages(on: server)
        await installState(on: server)
        await installNotes(on: server)
        await installCapture(on: server)
        await installChat(on: server)
        await installStubs(on: server)
        await installDiagnostics(on: server)

        await server.appendRoute("GET *") { request in
            Log.routes.notice("unhandled GET \(request.path, privacy: .public)")
            return Self.json(API.Failure(error: "not found"), status: .notFound)
        }
        await server.appendRoute("POST *") { request in
            Log.routes.notice("unhandled POST \(request.path, privacy: .public)")
            return Self.json(API.Failure(error: "not found"), status: .notFound)
        }
    }

    // MARK: - Pages

    private func installPages(on server: HTTPServer) async {
        // The real interface, verbatim from the Windows app.
        await server.appendRoute("GET /") { _ in Self.bundled("app", "html") }
        await server.appendRoute("GET /index.html") { _ in Self.bundled("app", "html") }

        // Loaded by a synchronous document.write in app.html. It is the
        // offline-copy engine, which this app never needs - the server is
        // in-process - but a 404 would leave its globals undefined at boot.
        await server.appendRoute("GET /local.js") { _ in Self.bundled("local", "js") }

        await server.appendRoute("GET /diag") { _ in Self.bundled("diag", "html") }

        // Deliberately 404: the page registers a service worker only because
        // loopback is a secure context, and its .catch swallows the failure.
        // No worker means no caching layer between the page and the bridge,
        // which is one less thing to explain when something looks stale.
        await server.appendRoute("GET /sw.js") { _ in
            Self.json(API.Failure(error: "no service worker in the native app"), status: .notFound)
        }
    }

    // MARK: - State

    private func installState(on server: HTTPServer) async {
        // The page's liveness probe, and its first call. It is given a 6 s
        // timeout and falls back to the offline copy if it misses, so this
        // must stay trivial.
        await server.appendRoute("GET /api/profiles") { _ in
            Self.json(API.Profiles(profiles: [], current: nil))
        }

        await server.appendRoute("GET /api/state") { [vault, embedding, capture] _ in
            await Self.json(Self.state(vault: vault, embedding: embedding, capture: capture))
        }

        await server.appendRoute("GET /api/agenda") { [vault] _ in
            // Nothing is scheduled yet - reminders are M2 - but dated notes
            // already belong here.
            let due = await vault.notes(status: "open").filter { $0.note.due != nil }
            return await Self.json(API.Agenda(
                notes: due.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) },
                items: [],
                lists: [],
                anytime: []
            ))
        }

        await server.appendRoute("GET /api/due") { [reminders] _ in
            await Self.jsonObject(["reminders": reminders.dueNow(), "rolled": 0])
        }

        // The page posts back the keys it has just shown, so nothing fires
        // twice across a reload.
        await server.appendRoute("POST /api/reminded") { [reminders] request in
            let body = try await Self.body(request)
            let keys = body["keys"] as? [String] ?? []
            await reminders.markFired(keys)
            return Self.json(API.Ok())
        }

        // Giving a note a time, from the note view or a snooze on an alert.
        await server.appendRoute("POST /api/note/schedule") { [vault, reminders] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Self.json(API.Failure(error: "not found"), status: .notFound)
            }
            let when = body["when"] as? String
            let wantsReminder = body["remind"] as? Bool ?? true

            entry.note.due = when
            entry.note.remind = wantsReminder ? when : nil
            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )

            await reminders.cancel(noteID: id)
            if entry.note.remind != nil { await reminders.schedule(entry.note) }
            return Self.json(API.Ok())
        }

        await server.appendRoute("POST /api/note/complete") { [vault, reminders] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Self.json(API.Failure(error: "not found"), status: .notFound)
            }
            let done = body["done"] as? Bool ?? true
            entry.note.status = done ? "done" : "open"
            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )
            // A finished note should not go on reminding.
            if done { await reminders.cancel(noteID: id) }
            return Self.jsonObject(["ok": true, "next": NSNull()])
        }
    }

    @MainActor
    private static func state(vault: Vault, embedding: EmbedderBox, capture: Capture) -> API.State {
        var nodes: [API.TopicNode] = []
        for path in vault.collectionPaths {
            let members = vault.notes(topic: path)
            var views: [String: Int] = [:]
            for member in members where member.note.kind != "note" {
                views[member.note.kind, default: 0] += 1
            }
            nodes.append(API.TopicNode(
                id: path,
                name: path.components(separatedBy: "/").last ?? path,
                path: path,
                state: "active",
                count: members.count,
                own: members.count,
                views: views,
                children: []
            ))
        }

        let coldStart = max(0, capture.coldStartNotes - vault.entries.count)
        return API.State(
            tree: nodes,
            inbox: vault.inbox.count,
            review: vault.needingReview.count,
            notes: vault.entries.count,
            topics: nodes.count,
            embedder: embedding.identifier,
            router: Intelligence.availability.isAvailable ? "apple-on-device" : "retrieval-only",
            profile: "main",
            vault: vault.root.path,
            coldStart: coldStart,
            embedderChanged: nil,
            laptop: true,
            paths: ["vault": vault.root.path]
        )
    }

    // MARK: - Notes

    private func installNotes(on server: HTTPServer) async {
        await server.appendRoute("GET /api/notes") { [vault] request in
            let query = Self.queryItems(request)
            let entries = await vault.notes(
                topic: query["topic"], kind: query["kind"], status: query["status"]
            )
            return await Self.json(API.NotesList(
                notes: entries.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) }
            ))
        }

        await server.appendRoute("GET /api/note") { [vault] request in
            let id = Self.queryItems(request)["id"] ?? ""
            guard let entry = await vault.entry(id) else {
                return Self.json(API.Failure(error: "not found"), status: .notFound)
            }
            let related = await vault.search(entry.note.title, vector: entry.vector, limit: 6)
                .filter { $0.entry.note.id != id }
                .prefix(4)
                .map { API.NoteBrief($0.entry.note, path: $0.entry.path, needsReview: $0.entry.needsReview) }
            return await Self.json(API.NoteDetail(
                entry.note, path: entry.path, needsReview: entry.needsReview, related: Array(related)
            ))
        }

        await server.appendRoute("GET /api/inbox") { [vault] _ in
            let inbox = await vault.inbox
            let review = await vault.needingReview
            return await Self.json(API.InboxList(
                notes: inbox.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) },
                review: review.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) }
            ))
        }

        // "Where would this note go?" - the one-tap pills on an Inbox row.
        await server.appendRoute("GET /api/suggest") { [vault] request in
            let id = Self.queryItems(request)["id"] ?? ""
            guard let entry = await vault.entry(id) else {
                return Self.json(API.Suggestions(suggestions: []))
            }
            let candidates = await vault.candidates(for: entry.vector, limit: 3)
            return Self.json(API.Suggestions(suggestions: candidates
                .filter { $0.similarity > 0 }
                .map { API.Suggestion(
                    path: $0.path,
                    similarity: ($0.similarity * 1000).rounded() / 1000,
                    count: $0.noteCount
                ) }
            ))
        }

        await server.appendRoute("GET /api/search") { [vault, embedding] request in
            let query = Self.queryItems(request)["q"] ?? ""
            guard !query.isEmpty else { return Self.json(API.Hits(hits: [])) }
            let vector = await embedding.embed(query)
            let hits = await vault.search(query, vector: vector)
            return Self.json(API.Hits(hits: hits.map { hit in
                API.Hit(
                    id: hit.entry.note.id,
                    title: hit.entry.note.title,
                    topic: hit.entry.note.primaryTopic,
                    kind: hit.entry.note.kind,
                    snippet: API.NoteBrief.snippet(from: hit.entry.note.body),
                    via: hit.via,
                    score: (hit.score * 1000).rounded() / 1000
                )
            }))
        }
    }

    // MARK: - Mutations

    private func installCapture(on server: HTTPServer) async {
        await server.appendRoute("POST /api/capture") { [capture] request in
            let body = try await Self.body(request)
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return Self.json(API.Failure(error: "empty"), status: .badRequest)
            }
            let outcome = await capture.capture(text: text)
            return Self.json(Self.captureResult(outcome))
        }

        await server.appendRoute("POST /api/note/update") { [vault] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Self.json(API.Failure(error: "not found"), status: .notFound)
            }
            if let title = body["title"] as? String { entry.note.title = title }
            if let text = body["body"] as? String { entry.note.body = text }
            entry.note.updated = Timestamp.utcNow()
            // Re-embed: the text changed, so the old vector describes a note
            // that no longer exists.
            let vector = await self.embedding.embed(entry.note.embeddingText)
            let path = (try? await vault.save(
                entry.note, topic: entry.note.primaryTopic, vector: vector, needsReview: false
            )) ?? entry.path
            return await Self.json(API.NoteDetail(
                entry.note, path: path, needsReview: false, related: []
            ))
        }

        await server.appendRoute("POST /api/note/new") { [vault] request in
            let body = try await Self.body(request)
            var note = Note(
                title: body["title"] as? String ?? "Untitled",
                body: body["body"] as? String ?? "",
                kind: body["kind"] as? String == "list" ? "list" : "note"
            )
            note.updated = Timestamp.utcNow()
            let topic = (body["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let path = (try? await vault.save(note, topic: topic, vector: [], needsReview: false)) ?? ""
            return await Self.json(API.NoteDetail(note, path: path, needsReview: false, related: []))
        }

        await server.appendRoute("POST /api/move") { [vault, embedding] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            let topic = (body["topic"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard var entry = await vault.entry(id), !topic.isEmpty else {
                return Self.json(API.Failure(error: "id and topic required"), status: .badRequest)
            }
            entry.note.updated = Timestamp.utcNow()
            var vector = entry.vector
            if vector.isEmpty { vector = await embedding.embed(entry.note.embeddingText) }
            // A move is the user correcting us, so the review flag clears.
            let path = (try? await vault.save(
                entry.note, topic: topic, vector: vector, needsReview: false
            )) ?? entry.path
            return Self.json(["path": path])
        }

        // "File it for me" on an unfiled note.
        await server.appendRoute("POST /api/note/file") { [vault, capture] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            guard let entry = await vault.entry(id) else {
                return Self.json(API.Failure(error: "not found"), status: .notFound)
            }
            let outcome = await capture.capture(text: entry.note.body)
            try? await vault.delete(id)
            return Self.json(Self.captureResult(outcome))
        }

        await server.appendRoute("POST /api/note/delete") { [vault] request in
            let body = try await Self.body(request)
            try? await vault.delete(body["id"] as? String ?? "")
            return Self.json(API.Ok())
        }

        // A note opened and closed without typing anything leaves no trace.
        await server.appendRoute("POST /api/note/discard") { [vault] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            guard let entry = await vault.entry(id) else { return Self.json(["discarded": false]) }
            let blank = entry.note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank { try? await vault.delete(id) }
            return Self.json(["discarded": blank])
        }
    }

    nonisolated private static func captureResult(_ outcome: Capture.Outcome) -> API.CaptureResult {
        API.CaptureResult(
            id: outcome.note.id,
            title: outcome.note.title,
            body: outcome.note.body,
            kind: outcome.note.kind,
            due: outcome.note.due,
            reminder: outcome.note.remind != nil,
            recurrence: nil,
            appendedTo: nil,
            listItems: [],
            pausedUntil: nil,
            appendCandidates: [],
            matched: nil,
            summary: outcome.decision.reason,
            topic: outcome.decision.topicPath,
            path: outcome.path,
            outcome: outcome.decision.outcome.rawValue,
            related: outcome.relatedCount,
            steered: false,
            bootstrapped: 0,
            promoted: []
        )
    }

    // MARK: - Chat

    private func installChat(on server: HTTPServer) async {
        // Newline-delimited JSON, one event per line. The page reads it with a
        // streaming reader, so the content type matters.
        await server.appendRoute("POST /api/chat") { [chat] request in
            let body = try await Self.body(request)
            let message = (body["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return Self.ndjson([#"{"type":"error","message":"empty message"}"#])
            }

            var history: [(role: String, content: String)] = []
            for turn in body["history"] as? [[String: Any]] ?? [] {
                let role = turn["role"] as? String ?? "user"
                let content = (turn["content"] as? String) ?? (turn["text"] as? String) ?? ""
                if !content.isEmpty { history.append((role: role, content: content)) }
            }

            let data = await chat.respond(to: Chat.Request(message: message, history: history))
            return HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "application/x-ndjson; charset=utf-8"],
                body: data
            )
        }

        await server.appendRoute("POST /api/note/ai") { [vault, intelligence] request in
            let body = try await Self.body(request)
            let id = body["id"] as? String ?? ""
            let ask = (body["request"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = await vault.entry(id)
            let text = entry?.note.body ?? (body["body"] as? String ?? "")

            guard !ask.isEmpty else {
                return Self.json(API.Failure(error: "empty request"), status: .badRequest)
            }
            guard Intelligence.availability.isAvailable else {
                return Self.json(
                    API.Failure(error: "The on-device model isn't available yet."),
                    status: .serviceUnavailable
                )
            }
            do {
                let edit = try await intelligence.editNote(body: text, request: ask)
                return Self.json([
                    "action": edit.action.wire,
                    "reply": edit.reply,
                    "text": edit.text,
                    "position": "end"
                ])
            } catch {
                Log.model.error("note AI failed: \(error.localizedDescription, privacy: .public)")
                return Self.json(
                    API.Failure(error: "The model couldn't do that."),
                    status: .serviceUnavailable
                )
            }
        }
    }

    // MARK: - Stubs

    /// Right shape, nothing in it. The page has designed empty states for all
    /// of these, so they read as "nothing here yet" rather than failing.
    private func installStubs(on server: HTTPServer) async {
        await server.appendRoute("GET /api/lists") { _ in Self.json(API.Lists(lists: [])) }
        await server.appendRoute("GET /api/links") { _ in Self.json(API.Links(links: [])) }
        await server.appendRoute("GET /api/garden") { _ in Self.json(API.Garden(proposals: [])) }
        await server.appendRoute("GET /api/graph") { _ in Self.json(API.Graph(nodes: [], links: [])) }
        await server.appendRoute("POST /api/undo") { _ in Self.json(API.Undone(undone: nil)) }

        // Personal notes is the WhatsApp import, prepared by hand on the
        // laptop. It has no meaning here.
        await server.appendRoute("GET /api/personal") { _ in
            Self.json(["sources": [String]()])
        }
    }

    private func installDiagnostics(on server: HTTPServer) async {
        await server.appendRoute("GET /api/diag") { [diagnostics] _ in
            Self.json(await diagnostics.report())
        }
        await server.appendRoute("POST /api/diag/probe") { [diagnostics] _ in
            Self.json(await diagnostics.runProbes())
        }
        await server.appendRoute("GET /api/diag/log") { _ in
            HTTPResponse(
                statusCode: .ok,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: Data(Log.recentEntries().joined(separator: "\n").utf8)
            )
        }
    }

    // MARK: - Helpers
    //
    // nonisolated because the route closures are @Sendable and so not on the
    // main actor, while this class is. None of these touch instance state.

    nonisolated static func queryItems(_ request: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for item in request.query { out[item.name] = item.value }
        return out
    }

    nonisolated static func body(_ request: HTTPRequest) async throws -> [String: Any] {
        let data = try await request.bodyData
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    nonisolated static func json(_ value: some Encodable, status: HTTPStatusCode = .ok) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        return HTTPResponse(
            statusCode: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: body
        )
    }

    /// Named separately from `json(_:status:)` rather than overloaded on it.
    /// A dictionary of uniform value type satisfies both, and "it will
    /// probably resolve" is not worth a round trip to a CI runner to find out.
    nonisolated static func jsonObject(_ value: [String: Any]) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: value))
            ?? Data("{\"error\":\"encoding failed\"}".utf8)
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: body
        )
    }

    nonisolated static func ndjson(_ lines: [String]) -> HTTPResponse {
        HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "application/x-ndjson; charset=utf-8"],
            body: Data((lines.joined(separator: "\n") + "\n").utf8)
        )
    }

    nonisolated static func bundled(_ name: String, _ ext: String) -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            Log.routes.error("missing bundled resource \(name, privacy: .public).\(ext, privacy: .public)")
            return HTTPResponse(
                statusCode: .internalServerError,
                headers: [.contentType: "text/plain; charset=utf-8"],
                body: Data("missing \(name).\(ext) in the app bundle".utf8)
            )
        }
        var headers: HTTPHeaders = [.contentType: contentType(for: ext)]
        // The page checks for this header on itself.
        if ext == "html" { headers[HTTPHeader("X-Notes-App")] = "1" }
        return HTTPResponse(statusCode: .ok, headers: headers, body: data)
    }

    nonisolated static func contentType(for ext: String) -> String {
        switch ext {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
