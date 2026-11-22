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
    private let selfTest: SelfTest
    private let images: ImageCapture
    private let gardener: Gardener
    private let calibration: CalibrationRun
    private let previews: LinkPreviews
    /// Suggestions the user has waved away. In memory: a dismissal should last
    /// the session, not forever, because the vault changes underneath it.
    private let dismissed = DismissedProposals()

    init(
        diagnostics: Diagnostics,
        vault: Vault,
        capture: Capture,
        embedding: EmbedderBox,
        chat: Chat,
        reminders: Reminders,
        intelligence: Intelligence,
        selfTest: SelfTest,
        images: ImageCapture,
        gardener: Gardener,
        calibration: CalibrationRun,
        previews: LinkPreviews
    ) {
        self.diagnostics = diagnostics
        self.vault = vault
        self.capture = capture
        self.embedding = embedding
        self.chat = chat
        self.reminders = reminders
        self.intelligence = intelligence
        self.selfTest = selfTest
        self.images = images
        self.gardener = gardener
        self.calibration = calibration
        self.previews = previews
    }

    func install(on server: HTTPServer) async {
        await installRequestLog(on: server)
        await installPages(on: server)
        await installState(on: server)
        await installNotes(on: server)
        await installCapture(on: server)
        await installChat(on: server)
        await installChecklists(on: server)
        await installStubs(on: server)
        await installDiagnostics(on: server)

        await server.appendRoute("GET *") { request in
            Log.routes.notice("unhandled GET \(request.path, privacy: .public)")
            return Respond.json(API.Failure(error: "not found"), status: .notFound)
        }
        await server.appendRoute("POST *") { request in
            Log.routes.notice("unhandled POST \(request.path, privacy: .public)")
            return Respond.json(API.Failure(error: "not found"), status: .notFound)
        }
    }

    // MARK: - Request log

    /// Log every request, then decline it so the real route handles it.
    ///
    /// FlyingFox tries routes in order and moves to the next one when a
    /// handler throws `HTTPUnhandledError`, which makes a first catch-all an
    /// effective middleware hook. Installed before everything else, so the
    /// diagnostics page's log becomes a full request trace.
    ///
    /// Worth the noise: with no debugger and no web inspector, "which URLs did
    /// the page actually ask for, and in what order" is otherwise unknowable —
    /// and a blank screen is exactly the failure where that is the question.
    private func installRequestLog(on server: HTTPServer) async {
        for method in ["GET", "POST"] {
            await server.appendRoute(HTTPRoute("\(method) *")) { request in
                Log.routes.notice("\(method, privacy: .public) \(request.path, privacy: .public)")
                throw HTTPUnhandledError()
            }
        }
    }

    // MARK: - Pages

    private func installPages(on server: HTTPServer) async {
        // The real interface, verbatim from the Windows app.
        await server.appendRoute("GET /") { _ in Respond.bundled("app", "html") }
        await server.appendRoute("GET /index.html") { _ in Respond.bundled("app", "html") }

        // Loaded by a synchronous document.write in app.html. It is the
        // offline-copy engine, which this app never needs - the server is
        // in-process - but a 404 would leave its globals undefined at boot.
        await server.appendRoute("GET /local.js") { _ in Respond.bundled("local", "js") }

        await server.appendRoute("GET /diag") { _ in Respond.bundled("diag", "html") }

        // Images, served out of the vault's media folder.
        await server.appendRoute("GET /media/*") { [vault] request in
            await Self.media(vault, path: request.path)
        }

        // Deliberately 404: the page registers a service worker only because
        // loopback is a secure context, and its .catch swallows the failure.
        // No worker means no caching layer between the page and the bridge,
        // which is one less thing to explain when something looks stale.
        await server.appendRoute("GET /sw.js") { _ in
            Respond.json(API.Failure(error: "no service worker in the native app"), status: .notFound)
        }
    }

    // MARK: - State

    private func installState(on server: HTTPServer) async {
        // The page's liveness probe, and its first call. It is given a 6 s
        // timeout and falls back to the offline copy if it misses, so this
        // must stay trivial.
        await server.appendRoute("GET /api/profiles") { _ in
            Respond.json(API.Profiles(profiles: [], current: nil))
        }

        await server.appendRoute("GET /api/state") { [vault, embedding, capture] _ in
            await Respond.json(Self.state(vault: vault, embedding: embedding, capture: capture))
        }

        await server.appendRoute("GET /api/agenda") { [vault] _ in
            // Nothing is scheduled yet - reminders are M2 - but dated notes
            // already belong here.
            let due = await vault.notes(status: "open").filter { $0.note.due != nil }
            return await Respond.json(API.Agenda(
                notes: due.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) },
                items: [],
                lists: [],
                anytime: []
            ))
        }

        await server.appendRoute("GET /api/due") { [reminders] _ in
            await Respond.jsonObject(["reminders": reminders.dueNow(), "rolled": 0])
        }

        // The page posts back the keys it has just shown, so nothing fires
        // twice across a reload.
        await server.appendRoute("POST /api/reminded") { [reminders] request in
            let body = try await Respond.body(request)
            let keys = body["keys"] as? [String] ?? []
            await reminders.markFired(keys)
            return Respond.json(API.Ok())
        }

        // Giving a note a time, from the note view or a snooze on an alert.
        await server.appendRoute("POST /api/note/schedule") { [vault, reminders] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Respond.json(API.Failure(error: "not found"), status: .notFound)
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
            return Respond.json(API.Ok())
        }

        await server.appendRoute("POST /api/note/complete") { [vault, reminders] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Respond.json(API.Failure(error: "not found"), status: .notFound)
            }
            let done = body["done"] as? Bool ?? true

            // Ticking a repeating thing moves it on rather than finishing it:
            // otherwise "water the plants every Monday" survives exactly one
            // Monday.
            var next: String?
            if done, entry.note.repeatRule != nil {
                var note = entry.note
                if await reminders.advanceRepeat(&note) {
                    next = note.remind ?? note.due
                    entry.note = note
                }
            }
            if next == nil {
                entry.note.status = done ? "done" : "open"
            }
            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )

            await reminders.cancel(noteID: id)
            if entry.note.remind != nil, entry.note.status == "open" {
                await reminders.schedule(entry.note)
            }
            return Respond.jsonObject(["ok": true, "next": next as Any? ?? NSNull()])
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
            let query = Respond.query(request)
            let entries = await vault.notes(
                topic: query["topic"], kind: query["kind"], status: query["status"]
            )
            return await Respond.json(API.NotesList(
                notes: entries.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) }
            ))
        }

        await server.appendRoute("GET /api/note") { [vault] request in
            let id = Respond.query(request)["id"] ?? ""
            guard let entry = await vault.entry(id) else {
                return Respond.json(API.Failure(error: "not found"), status: .notFound)
            }
            let related = await vault.search(entry.note.title, vector: entry.vector, limit: 6)
                .filter { $0.entry.note.id != id }
                .prefix(4)
                .map { API.NoteBrief($0.entry.note, path: $0.entry.path, needsReview: $0.entry.needsReview) }
            return await Respond.json(API.NoteDetail(
                entry.note, path: entry.path, needsReview: entry.needsReview, related: Array(related)
            ))
        }

        await server.appendRoute("GET /api/inbox") { [vault] _ in
            let inbox = await vault.inbox
            let review = await vault.needingReview
            return await Respond.json(API.InboxList(
                notes: inbox.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) },
                review: review.map { API.NoteBrief($0.note, path: $0.path, needsReview: $0.needsReview) }
            ))
        }

        // "Where would this note go?" - the one-tap pills on an Inbox row.
        await server.appendRoute("GET /api/suggest") { [vault] request in
            let id = Respond.query(request)["id"] ?? ""
            guard let entry = await vault.entry(id) else {
                return Respond.json(API.Suggestions(suggestions: []))
            }
            let candidates = await vault.candidates(for: entry.vector, limit: 3)
            return Respond.json(API.Suggestions(suggestions: candidates
                .filter { $0.similarity > 0 }
                .map { API.Suggestion(
                    path: $0.path,
                    similarity: ($0.similarity * 1000).rounded() / 1000,
                    count: $0.noteCount
                ) }
            ))
        }

        await server.appendRoute("GET /api/search") { [vault, embedding] request in
            let query = Respond.query(request)["q"] ?? ""
            guard !query.isEmpty else { return Respond.json(API.Hits(hits: [])) }
            let vector = await embedding.embed(query)
            let hits = await vault.search(query, vector: vector)
            return Respond.json(API.Hits(hits: hits.map { hit in
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
            let body = try await Respond.body(request)
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return Respond.json(API.Failure(error: "empty"), status: .badRequest)
            }
            let outcome = await capture.capture(text: text)
            return Respond.json(Self.captureResult(outcome))
        }

        await server.appendRoute("POST /api/note/update") { [vault] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Respond.json(API.Failure(error: "not found"), status: .notFound)
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
            return await Respond.json(API.NoteDetail(
                entry.note, path: path, needsReview: false, related: []
            ))
        }

        await server.appendRoute("POST /api/note/new") { [vault] request in
            let body = try await Respond.body(request)
            var note = Note(
                title: body["title"] as? String ?? "Untitled",
                body: body["body"] as? String ?? "",
                kind: body["kind"] as? String == "list" ? "list" : "note"
            )
            note.updated = Timestamp.utcNow()
            let topic = (body["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let path = (try? await vault.save(note, topic: topic, vector: [], needsReview: false)) ?? ""
            return await Respond.json(API.NoteDetail(note, path: path, needsReview: false, related: []))
        }

        await server.appendRoute("POST /api/move") { [vault, embedding] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            let topic = (body["topic"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard var entry = await vault.entry(id), !topic.isEmpty else {
                return Respond.json(API.Failure(error: "id and topic required"), status: .badRequest)
            }
            entry.note.updated = Timestamp.utcNow()
            var vector = entry.vector
            if vector.isEmpty { vector = await embedding.embed(entry.note.embeddingText) }
            // A move is the user correcting us, so the review flag clears.
            let path = (try? await vault.save(
                entry.note, topic: topic, vector: vector, needsReview: false
            )) ?? entry.path
            return Respond.json(["path": path])
        }

        // "File it for me" on an unfiled note.
        await server.appendRoute("POST /api/note/file") { [vault, capture] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard let entry = await vault.entry(id) else {
                return Respond.json(API.Failure(error: "not found"), status: .notFound)
            }
            let outcome = await capture.capture(text: entry.note.body)
            try? await vault.delete(id)
            return Respond.json(Self.captureResult(outcome))
        }

        await server.appendRoute("POST /api/note/delete") { [vault] request in
            let body = try await Respond.body(request)
            try? await vault.delete(body["id"] as? String ?? "")
            return Respond.json(API.Ok())
        }

        // A note opened and closed without typing anything leaves no trace.
        await server.appendRoute("POST /api/note/discard") { [vault] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard let entry = await vault.entry(id) else { return Respond.json(["discarded": false]) }
            let blank = entry.note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank { try? await vault.delete(id) }
            return Respond.json(["discarded": blank])
        }
    }

    /// Serve one file from the vault's media folder.
    ///
    /// The filename is taken as a basename and nothing else: a request may ask
    /// for any name it likes, and joining an attacker-chosen path onto the
    /// vault root is how a server starts handing out arbitrary files.
    @MainActor
    private static func media(_ vault: Vault, path: String) -> HTTPResponse {
        let requested = path
            .removingPercentEncoding ?? path
        guard let name = requested.components(separatedBy: "/").last, !name.isEmpty,
              !name.contains(".."), !name.contains("\\") else {
            return Respond.failure("not found", status: .notFound)
        }

        let url = vault.root
            .appendingPathComponent(".mnemo/media", isDirectory: true)
            .appendingPathComponent(name)

        // And verified afterwards, rather than trusted: the resolved path has
        // to still be inside the media folder.
        let base = vault.root.appendingPathComponent(".mnemo/media").standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(base),
              let data = try? Data(contentsOf: url) else {
            return Respond.failure("not found", status: .notFound)
        }

        let format = ImageFormat.sniff([UInt8](data.prefix(16)))
        return HTTPResponse(
            statusCode: .ok,
            headers: [
                .contentType: format?.contentType ?? "application/octet-stream",
                HTTPHeader("Cache-Control"): "private, max-age=31536000",
                HTTPHeader("X-Content-Type-Options"): "nosniff"
            ],
            body: data
        )
    }

    /// Every note that is a checklist.
    ///
    /// One main-actor hop for the whole list rather than one per note: the
    /// per-element version does not compile anyway, because a `map` closure is
    /// synchronous and nonisolated.
    @MainActor
    private static func allLists(_ vault: Vault) -> [[String: Any]] {
        vault.notes()
            .filter { $0.note.kind == "list" || Checklist.progress(in: $0.note.body) != nil }
            .map { listBrief($0) }
    }

    /// A to-do list as the To-do lists page draws it: the note, plus progress
    /// and whatever deadline it carries.
    @MainActor
    private static func listBrief(_ entry: Vault.Entry) -> [String: Any] {
        let progress = Checklist.progress(in: entry.note.body) ?? [0, 0]
        var out: [String: Any] = [
            "id": entry.note.id,
            "title": entry.note.title.isEmpty ? "Untitled" : entry.note.title,
            "kind": "list",
            "status": entry.note.status,
            "topic": entry.note.primaryTopic as Any? ?? NSNull(),
            "path": entry.path,
            "created": entry.note.created,
            "updated": entry.note.updated,
            "snippet": API.NoteBrief.snippet(from: entry.note.body),
            "done": entry.note.status == "done",
            "review": entry.needsReview,
            "remind": entry.note.remind != nil,
            "due": entry.note.due as Any? ?? NSNull(),
            "progress": progress,
            "lines": API.NoteBrief.previewLines(from: entry.note.body).map { line in
                [
                    "t": line.t,
                    "text": line.text,
                    "done": line.done as Any? ?? NSNull(),
                    "line": line.line as Any? ?? NSNull()
                ]
            },
            "list": [
                "done": progress[0],
                "total": progress[1],
                "due": entry.note.due as Any? ?? NSNull(),
                "checkin": entry.note.checkin as Any? ?? NSNull(),
                "quietUntil": entry.note.quietUntil as Any? ?? NSNull(),
                "repeat": entry.note.repeatRule as Any? ?? NSNull(),
                "parent": entry.note.parent as Any? ?? NSNull(),
                "children": [String](),
                "sections": [[String: Any]]()
            ]
        ]
        out["media"] = entry.note.media as Any? ?? NSNull()
        out["source"] = entry.note.source as Any? ?? NSNull()
        return out
    }

    /// Every link written in any note, once each, with the notes it appears
    /// in.
    ///
    /// Worked out from the notes on every request rather than kept in a
    /// table: there is nothing to keep in step, and nothing a rebuild can
    /// lose. The same article shared two ways collapses to one entry because
    /// the key has its tracking parameters stripped.
    @MainActor
    private static func linkIndex(_ vault: Vault) -> [(key: String, url: URL, notes: [Vault.Entry])] {
        var found: [String: (url: URL, notes: [Vault.Entry])] = [:]
        var order: [String] = []

        for entry in vault.notes() {
            // Only the user's own text, never a fetched page's body - that
            // would turn every outbound link on an article into a tile.
            let ownText = entry.note.source.map { source in
                entry.note.body.components(separatedBy: "\n\n").first ?? source
            } ?? entry.note.body

            var urls = LinkText.allURLs(in: ownText)
            if let source = entry.note.source, let url = URL(string: source) {
                urls = [url] + urls.filter { LinkText.canonical($0) != LinkText.canonical(url) }
            }

            for url in urls {
                let key = LinkText.canonical(url)
                if found[key] == nil {
                    order.append(key)
                    found[key] = (url, [])
                }
                found[key]?.notes.append(entry)
            }
        }
        return order.compactMap { key in
            found[key].map { (key: key, url: $0.url, notes: $0.notes) }
        }
    }

    /// One tile per link, in the user's own arrangement.
    @MainActor
    private static func linkTiles(_ vault: Vault, _ previews: LinkPreviews) -> [[String: Any]] {
        var tiles: [String: [String: Any]] = [:]
        var keys: [String] = []

        for link in linkIndex(vault) {
            let host = link.url.host ?? "link"
            let firstSaved = link.notes.map { $0.note.created }.min()
            keys.append(link.key)

            var tile: [String: Any] = [
                "key": link.key,
                "url": link.url.absoluteString,
                "site": host,
                "kind": LinkKind.of(host: host, path: link.url.path),
                "title": (link.notes.first?.note.title ?? "").ifEmpty(host),
                "caption": "",
                "handle": "",
                "thumb": NSNull(),
                "saved": firstSaved as Any? ?? NSNull(),
                // Hosts that might need the user's account are never
                // contacted, and the tile says so plainly rather than looking
                // like a fetch that failed.
                "private": !LinkFetcher.shouldFetch(link.url),
                "notes": link.notes.map { entry -> [String: Any] in
                    let isSource = entry.note.source
                        .flatMap { URL(string: $0) }
                        .map { LinkText.canonical($0) == link.key } ?? false
                    return [
                        "id": entry.note.id,
                        "title": entry.note.title.ifEmpty("Untitled"),
                        "topic": entry.note.primaryTopic as Any? ?? NSNull(),
                        "how": isSource ? "saved" : "mentioned"
                    ]
                }
            ]

            if let preview = previews.preview(for: link.key) {
                for (field, value) in preview.fields where field != "key" {
                    // A site that gave no title leaves the note's own in
                    // place: a tile labelled with the bare host is worse than
                    // one labelled with what the user wrote.
                    if field == "title", (value as? String)?.isEmpty != false { continue }
                    tile[field] = value
                }
            }
            tiles[link.key] = tile
        }

        return previews.sort(keys).compactMap { tiles[$0] }
    }

    /// The collections and notes, as the Map screen draws them.
    ///
    /// Topics first, because the page keeps only the first 600 nodes and then
    /// drops any link whose ends are missing: with notes first, a large vault
    /// would render as a field of unconnected dots.
    @MainActor
    /// Not private: the on-device self-test checks the invariant the
    /// page depends on, that every link joins two nodes it was sent.
    static func graph(_ vault: Vault, _ capture: Capture) -> [String: Any] {
        let thresholds = capture.thresholds
        var nodes: [[String: Any]] = []
        var links: [[String: Any]] = []

        let paths = vault.collectionPaths
        let known = Set(paths)
        for path in paths {
            nodes.append([
                "id": "t:" + path,
                "type": "topic",
                "label": path.components(separatedBy: "/").last ?? path,
                "path": path,
                "size": vault.notes(topic: path).count,
                "state": "active"
            ])
            // A nested collection hangs off its parent, but only when the
            // parent is itself a collection: a path can outlive the
            // collection above it.
            if let cut = path.lastIndex(of: "/") {
                let parent = String(path[path.startIndex..<cut])
                if known.contains(parent) {
                    links.append(["source": "t:" + parent, "target": "t:" + path, "type": "parent"])
                }
            }
        }

        let room = Swift.max(0, 600 - nodes.count)
        let entries = Array(vault.notes().prefix(room))
        for entry in entries {
            nodes.append([
                "id": entry.note.id,
                "type": "note",
                "label": entry.note.title.ifEmpty("Untitled"),
                "topic": entry.note.primaryTopic as Any? ?? NSNull()
            ])
            if let topic = entry.note.primaryTopic, known.contains(topic) {
                links.append(["source": entry.note.id, "target": "t:" + topic, "type": "about"])
            }
        }

        // Two notes are joined when they are as close as the router would
        // need to be to suggest one for the other - the same bar, so a dotted
        // line on the map means the same thing as a suggestion elsewhere.
        // Capped at two per note: past that the layout is a ball of wool.
        for (index, entry) in entries.enumerated() where !entry.vector.isEmpty {
            var near: [(id: String, score: Double)] = []
            for other in entries[(index + 1)...] where !other.vector.isEmpty {
                let score = Vectors.cosine(entry.vector, other.vector)
                if score >= thresholds.reviewFloor { near.append((other.note.id, score)) }
            }
            for found in near.sorted(by: { $0.score > $1.score }).prefix(2) {
                links.append(["source": entry.note.id, "target": found.id, "type": "related"])
            }
        }

        return ["nodes": nodes, "links": links]
    }

    /// One stored link thumbnail.
    @MainActor
    private static func thumb(_ previews: LinkPreviews, path: String) -> HTTPResponse {
        let requested = path.removingPercentEncoding ?? path
        guard let name = requested.components(separatedBy: "/").last, !name.isEmpty,
              let (data, type) = previews.thumbData(named: name) else {
            return Respond.failure("not found", status: .notFound)
        }
        return HTTPResponse(
            statusCode: .ok,
            headers: [
                .contentType: type,
                // Named after the hash of its own bytes, so it can be cached
                // hard: a different image is a different name.
                HTTPHeader("Cache-Control"): "private, max-age=31536000",
                HTTPHeader("X-Content-Type-Options"): "nosniff"
            ],
            body: data
        )
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
            let body = try await Respond.body(request)
            let message = (body["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return Respond.ndjson([#"{"type":"error","message":"empty message"}"#])
            }

            var history: [(role: String, content: String)] = []
            for turn in body["history"] as? [[String: Any]] ?? [] {
                let role = turn["role"] as? String ?? "user"
                let content = (turn["content"] as? String) ?? (turn["text"] as? String) ?? ""
                if !content.isEmpty { history.append((role: role, content: content)) }
            }

            // Streamed, so the sources reach the page before the model has
            // written anything.
            return await Respond.ndjsonStream(
                chat.stream(to: Chat.Request(message: message, history: history))
            )
        }

        await server.appendRoute("POST /api/note/ai") { [vault, intelligence] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            let ask = (body["request"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = await vault.entry(id)
            let text = entry?.note.body ?? (body["body"] as? String ?? "")

            guard !ask.isEmpty else {
                return Respond.json(API.Failure(error: "empty request"), status: .badRequest)
            }
            guard Intelligence.availability.isAvailable else {
                return Respond.json(
                    API.Failure(error: "The on-device model isn't available yet."),
                    status: .serviceUnavailable
                )
            }
            do {
                let edit = try await intelligence.editNote(body: text, request: ask)
                return Respond.json([
                    "action": edit.action.wire,
                    "reply": edit.reply,
                    "text": edit.text,
                    "position": "end"
                ])
            } catch {
                Log.model.error("note AI failed: \(error.localizedDescription, privacy: .public)")
                return Respond.json(
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
        // Both of these are derived from the notes every time rather than
        // stored. Nothing to keep in step, and nothing a rebuild can lose.
        await server.appendRoute("GET /api/lists") { [vault] _ in
            await Respond.jsonObject(["lists": Self.allLists(vault)])
        }

        await server.appendRoute("GET /api/links") { [vault, previews] _ in
            await Respond.jsonObject(["links": Self.linkTiles(vault, previews)])
        }

        // Previews arrive a few at a time while the Links page is open,
        // because the page asks again as long as any are left. A whole
        // vault's worth in one request would be a burst of traffic to a
        // dozen sites and a view that sits empty until the slowest answers.
        await server.appendRoute("POST /api/links/fetch") { [vault, previews] request in
            let body = try await Respond.body(request)
            let asked = body["max"] as? Int ?? 3
            let wanted = Swift.min(Swift.max(1, asked), 8)

            let pending = await Self.linkIndex(vault)
                .filter { LinkFetcher.shouldFetch($0.url) }
                .map { (key: $0.key, url: $0.url) }
            let result = await previews.fetchMissing(urls: pending, max: wanted)

            return Respond.jsonObject([
                "done": result.done.map { $0.fields },
                "left": result.left
            ])
        }

        // The user's own arrangement of the tiles.
        await server.appendRoute("POST /api/links/layout") { [previews] request in
            let body = try await Respond.body(request)
            let order = body["order"] as? [String] ?? []
            await previews.setOrder(order)
            return Respond.jsonObject(["ok": true])
        }

        await server.appendRoute("GET /link-thumb/*") { [previews] request in
            await Self.thumb(previews, path: request.path)
        }
        await server.appendRoute("GET /api/garden") { [gardener, dismissed] _ in
            // Snapshot first: a filter closure is synchronous, so awaiting
            // the actor inside one does not compile.
            let hidden = await dismissed.all()
            let live = await gardener.proposals().filter { !hidden.contains($0.id) }
            return Respond.jsonObject(["proposals": live.map { proposal in
                [
                    "id": proposal.id,
                    "kind": proposal.kind,
                    "summary": proposal.summary,
                    "detail": proposal.detail,
                    "score": proposal.score
                ]
            }])
        }

        await server.appendRoute("POST /api/garden/apply") { [gardener] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard let proposal = await gardener.proposals().first(where: { $0.id == id }) else {
                // The vault moved on since the page drew this card.
                return Respond.failure("That suggestion is out of date.", status: .notFound)
            }
            let ok = await gardener.apply(proposal)
            return Respond.jsonObject(["ok": ok])
        }

        await server.appendRoute("POST /api/garden/dismiss") { [dismissed] request in
            let body = try await Respond.body(request)
            if let id = body["id"] as? String { await dismissed.insert(id) }
            return Respond.jsonObject(["ok": true])
        }
        await server.appendRoute("GET /api/graph") { [vault, capture] _ in
            await Respond.jsonObject(Self.graph(vault, capture))
        }
        await server.appendRoute("POST /api/undo") { [vault, embedding, reminders] _ in
            Respond.json(await Undo.perform(vault: vault, embedding: embedding, reminders: reminders))
        }

        // Personal notes is the WhatsApp import, prepared by hand on the
        // laptop. It has no meaning here.
        await server.appendRoute("GET /api/personal") { _ in
            Respond.json(["sources": [String]()])
        }
    }

    private func installChecklists(on server: HTTPServer) async {
        // Tick or untick one line. The page sends the line number AND the
        // text; the text is what actually identifies the item, because the
        // page may be a moment out of date and toggling the wrong line
        // silently is the failure worth avoiding.
        await server.appendRoute("POST /api/list/item") { [vault] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            let line = body["line"] as? Int ?? -1
            let text = body["text"] as? String ?? ""
            let done = body["done"] as? Bool ?? true

            guard var entry = await vault.entry(id) else {
                return Respond.failure("not found", status: .notFound)
            }
            let today = String(Timestamp.utcNow().prefix(10))
            guard let updated = Checklist.setDone(
                entry.note.body, line: line, text: text, done: done, today: today
            ) else {
                return Respond.failure("That item changed. Open the note to see it.", status: .conflict)
            }

            await vault.recordTick(id: id, previousBody: entry.note.body)
            entry.note.body = updated
            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )

            let progress = Checklist.progress(in: updated) ?? [0, 0]
            return Respond.jsonObject(["ok": true, "progress": progress])
        }

        // A list's own settings: deadline, daily check-in, pause, repeat.
        await server.appendRoute("POST /api/list/settings") { [vault, reminders] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Respond.failure("not found", status: .notFound)
            }

            // A key that is present but null clears the setting; a key that
            // is absent leaves it alone. The page relies on that difference.
            func read(_ name: String) -> String?? {
                guard body.keys.contains(name) else { return nil }
                guard let value = body[name] as? String, !value.isEmpty else { return .some(nil) }
                return .some(value)
            }
            if let due = read("due") { entry.note.due = due }
            if let checkin = read("checkin") { entry.note.checkin = checkin }
            if let quiet = read("quiet_until") ?? read("quietUntil") { entry.note.quietUntil = quiet }
            if let rule = read("repeat") { entry.note.repeatRule = rule }
            if let parent = read("parent") { entry.note.parent = parent }
            if body["kind"] as? String == "list" { entry.note.kind = "list" }

            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )
            await reminders.cancel(noteID: id)
            if entry.note.remind != nil { await reminders.schedule(entry.note) }
            return Respond.jsonObject(["ok": true])
        }

        // A time on one checklist item, written into its own line.
        await server.appendRoute("POST /api/list/item/when") { [vault] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            let text = body["text"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Respond.failure("not found", status: .notFound)
            }
            var items = Checklist.items(in: entry.note.body)
            guard let index = items.firstIndex(where: { $0.text == text }) else {
                return Respond.failure("That item changed. Open the note to see it.", status: .conflict)
            }

            if body.keys.contains("remind") { items[index].remind = body["remind"] as? String }
            if body.keys.contains("due") { items[index].due = body["due"] as? String }
            if body.keys.contains("repeat") { items[index].repeatRule = body["repeat"] as? String }

            var lines = entry.note.body.components(separatedBy: "\n")
            let line = items[index].line
            guard line >= 0, line < lines.count else {
                return Respond.failure("That item moved.", status: .conflict)
            }
            let indent = String(lines[line].prefix(while: { $0 == " " || $0 == "\t" }))
            lines[line] = indent + Checklist.render(items[index])

            entry.note.body = lines.joined(separator: "\n")
            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )
            return Respond.jsonObject(["ok": true])
        }

        // An image, sent as base64 JSON rather than multipart - which is how
        // the page does it, so the bridge matches rather than arguing.
        await server.appendRoute("POST /api/upload") { [images] request in
            let body = try await Respond.body(request)
            let data = body["data"] as? String ?? ""
            let caption = body["text"] as? String ?? ""
            guard !data.isEmpty else {
                return Respond.failure("no image data", status: .badRequest)
            }
            do {
                let result = try await images.save(dataURL: data, caption: caption)
                return Respond.jsonObject([
                    "id": result.note.id,
                    "title": result.note.title,
                    "topic": result.decision.topicPath as Any? ?? NSNull(),
                    "outcome": result.decision.outcome.rawValue,
                    "media": result.media,
                    "ocr": result.transcript.isEmpty ? NSNull() : result.transcript,
                    "description": NSNull(),
                    "error": NSNull(),
                    "enrichError": NSNull()
                ])
            } catch {
                Log.vault.error("upload failed: \(error.localizedDescription, privacy: .public)")
                return Respond.failure("\(error)", status: .unprocessableContent)
            }
        }

        // Adding to a note the user named, rather than making a new one.
        await server.appendRoute("POST /api/note/append") { [vault, embedding] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            let text = (body["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard var entry = await vault.entry(id), !text.isEmpty else {
                return Respond.failure("id and text required", status: .badRequest)
            }
            entry.note.body = entry.note.body.isEmpty ? text : entry.note.body + "\n" + text
            entry.note.updated = Timestamp.utcNow()
            let vector = await embedding.embed(entry.note.embeddingText)
            let path = (try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: vector, needsReview: entry.needsReview, recordUndo: true
            )) ?? entry.path
            return await Respond.json(API.NoteDetail(
                entry.note, path: path, needsReview: entry.needsReview, related: []
            ))
        }

        // Drag to arrange. Fractional positions mean a drop between two notes
        // never has to renumber the ones around it.
        await server.appendRoute("POST /api/note/order") { [vault] request in
            let body = try await Respond.body(request)
            let id = body["id"] as? String ?? ""
            guard var entry = await vault.entry(id) else {
                return Respond.failure("not found", status: .notFound)
            }
            var before: Double?
            var after: Double?
            if let neighbour = body["before"] as? String {
                before = await vault.entry(neighbour)?.note.order
            }
            if let neighbour = body["after"] as? String {
                after = await vault.entry(neighbour)?.note.order
            }
            let position = Self.midpoint(before: before, after: after)

            entry.note.order = position
            entry.note.updated = Timestamp.utcNow()
            _ = try? await vault.save(
                entry.note, topic: entry.note.primaryTopic,
                vector: entry.vector, needsReview: entry.needsReview
            )
            return Respond.jsonObject(["ok": true, "pos": position])
        }
    }

    /// A position between two neighbours, or just outside the end ones.
    nonisolated static func midpoint(before: Double?, after: Double?) -> Double {
        switch (before, after) {
        case let (.some(a), .some(b)): return (a + b) / 2
        case let (.some(a), .none): return a - 1
        case let (.none, .some(b)): return b + 1
        case (.none, .none): return 0
        }
    }

    private func installDiagnostics(on server: HTTPServer) async {
        // The on-device test run. Writes real notes and removes them again.
        await server.appendRoute("POST /api/selftest") { [selfTest] _ in
            Respond.json(await selfTest.run())
        }

        await server.appendRoute("GET /api/diag") { [diagnostics] _ in
            Respond.json(await diagnostics.report())
        }
        await server.appendRoute("POST /api/diag/probe") { [diagnostics] _ in
            Respond.json(await diagnostics.runProbes())
        }
        // Measures both distributions on this device, derives thresholds
        // from them, and exports the matrix so every later sweep can run on
        // a laptop instead.
        await server.appendRoute("POST /api/calibrate") { [calibration] _ in
            Respond.json(await calibration.run())
        }

        await server.appendRoute("GET /api/diag/log") { _ in
            Respond.text(Log.recentEntries().joined(separator: "\n"))
        }
    }

}
