import Foundation
import NotesCore
import UserNotifications

/// Exercises the whole app on the device and reports pass or fail per check.
///
/// Unit tests cover `NotesCore` on Windows, and CI compiles the app — but
/// neither can answer "does this actually work on the phone", which is the
/// only question that has mattered so far. Every bug found in this project
/// after the Swift compiled was a runtime one: a socket on the wrong address
/// family, a model loading on the wrong actor. This is the harness for that
/// class of failure.
///
/// It writes real notes into the real vault, so every one it creates is
/// titled `[self-test]` and deleted at the end — including when a check
/// fails partway through.
@MainActor
final class SelfTest {

    private let vault: Vault
    private let capture: Capture
    private let chat: Chat
    private let embedding: EmbedderBox
    private let intelligence: Intelligence
    private let reminders: Reminders

    static let marker = "[self-test]"

    init(
        vault: Vault,
        capture: Capture,
        chat: Chat,
        embedding: EmbedderBox,
        intelligence: Intelligence,
        reminders: Reminders
    ) {
        self.vault = vault
        self.capture = capture
        self.chat = chat
        self.embedding = embedding
        self.intelligence = intelligence
        self.reminders = reminders
    }

    // MARK: - Report

    struct Report: Encodable {
        var ranAt: String
        var passed: Int
        var failed: Int
        var skipped: Int
        var durationMS: Int
        var results: [Check]
        /// One line, so the native panel can show a verdict without parsing.
        var summary: String
    }

    struct Check: Encodable {
        var name: String
        /// "pass", "fail" or "skip". Skip is not failure: a check that needs
        /// the model is meaningless on a device where the model is off, and
        /// calling that a failure would train us to ignore red.
        var status: String
        var detail: String
        var ms: Int
    }

    // MARK: - Running

    private var checks: [Check] = []
    private var created: [String] = []

    func run() async -> Report {
        checks = []
        created = []
        let start = Date()

        await step("vault writes and reads back") { try await self.checkVaultRoundTrip() }
        await step("frontmatter survives a round trip") { try self.checkFrontmatter() }
        await step("index survives a reload") { try await self.checkIndexRebuild() }
        await step("embedder is loaded") { try await self.checkEmbedder() }
        await step("embedding is deterministic") { try await self.checkEmbeddingStable() }
        await step("related notes score above unrelated") { try await self.checkSeparation() }
        await step("language model is available") { try self.checkModelAvailable() }
        await step("model answers a structured prompt") { try await self.checkModelRoundTrip() }
        await step("capture saves a note to disk") { try await self.checkCapture() }
        await step("search finds a captured note") { try await self.checkSearch() }
        await step("filing picks the right collection") { try await self.checkFiling() }
        await step("chat answers from a note") { try await self.checkChat() }
        await step("reminders schedule with the OS") { try await self.checkReminder() }
        await step("test notes are cleaned up") { try await self.cleanUp() }

        let passed = checks.filter { $0.status == "pass" }.count
        let failed = checks.filter { $0.status == "fail" }.count
        let skipped = checks.filter { $0.status == "skip" }.count

        let summary: String
        if failed == 0 && skipped == 0 {
            summary = "All \(passed) checks passed."
        } else if failed == 0 {
            summary = "\(passed) passed, \(skipped) skipped."
        } else {
            summary = "\(failed) FAILED, \(passed) passed, \(skipped) skipped."
        }
        Log.routes.notice("self-test: \(summary, privacy: .public)")

        return Report(
            ranAt: Timestamp.utcNow(),
            passed: passed,
            failed: failed,
            skipped: skipped,
            durationMS: Int(Date().timeIntervalSince(start) * 1000),
            results: checks,
            summary: summary
        )
    }

    /// A check that throws `Skip` is skipped; anything else is a failure. A
    /// check must not be able to abort the run, or one bad check hides the
    /// results of all the ones after it.
    private func step(_ name: String, _ body: () async throws -> Void) async {
        let start = Date()
        do {
            try await body()
            checks.append(Check(name: name, status: "pass", detail: "", ms: elapsed(start)))
        } catch let skip as Skip {
            checks.append(Check(name: name, status: "skip", detail: skip.why, ms: elapsed(start)))
        } catch {
            checks.append(Check(name: name, status: "fail", detail: "\(error)", ms: elapsed(start)))
        }
    }

    private func elapsed(_ from: Date) -> Int { Int(Date().timeIntervalSince(from) * 1000) }

    struct Skip: Error { var why: String }
    struct Failed: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failed(message()) }
    }

    // MARK: - Checks

    private func checkVaultRoundTrip() async throws {
        let note = Note(title: "\(Self.marker) storage", body: "written by the self-test")
        let path = try vault.save(note, topic: nil, vector: [], needsReview: false)
        created.append(note.id)

        let url = vault.root.appendingPathComponent(path)
        try expect(FileManager.default.fileExists(atPath: url.path), "no file at \(path)")

        let text = try String(contentsOf: url, encoding: .utf8)
        let reloaded = FrontmatterCodec.load(text)
        try expect(reloaded.id == note.id, "id changed on disk")
        try expect(reloaded.body == note.body, "body changed on disk")
    }

    private func checkFrontmatter() throws {
        // The awkward cases, on the device rather than only on Windows: a
        // different Foundation could in principle normalise strings
        // differently, and the vault is the one thing that must not drift.
        for title in ["Meeting: notes", "a, b, c", "quote \" inside", "  padded  ", ""] {
            let note = Note(title: title, body: "x", topics: ["Work"])
            let reloaded = FrontmatterCodec.load(FrontmatterCodec.render(note))
            try expect(reloaded.title == title, "title \(title.debugDescription) became \(reloaded.title.debugDescription)")
            try expect(reloaded.topics == ["Work"], "collection lost")
        }
    }

    private func checkIndexRebuild() async throws {
        let before = vault.entries.count
        await vault.reload(using: embedding.embedder)
        try expect(
            vault.entries.count == before,
            "reload found \(vault.entries.count) notes, had \(before) — the index and the files disagree"
        )
    }

    private func checkEmbedder() async throws {
        await embedding.prepare()
        guard let info = embedding.info else {
            throw Skip(why: embedding.failure ?? "the embedder is not available on this device")
        }
        try expect(info.dimension > 0, "dimension is \(info.dimension)")
        try expect(info.maximumSequenceLength > 0, "maximumSequenceLength is \(info.maximumSequenceLength)")
        checks.append(Check(
            name: "   embedder detail",
            status: "pass",
            detail: "\(info.dimension) dims, max \(info.maximumSequenceLength) tokens, \(info.embedderID)",
            ms: 0
        ))
    }

    /// The same text must embed to the same vector every time. If it does not,
    /// every stored vector is comparable only with itself and the whole
    /// retrieval design is void.
    private func checkEmbeddingStable() async throws {
        guard embedding.info != nil else { throw Skip(why: "no embedder") }
        let text = "sourdough levain at 100 percent hydration"
        let first = await embedding.embed(text)
        let second = await embedding.embed(text)
        try expect(!first.isEmpty, "embedding was empty")
        try expect(first.count == second.count, "dimension changed between calls")
        let similarity = Vectors.cosine(first, second)
        try expect(similarity > 0.9999, "same text scored \(similarity) against itself")
    }

    private func checkSeparation() async throws {
        guard embedding.info != nil else { throw Skip(why: "no embedder") }
        let a1 = await embedding.embed("Malenia waterfowl dance timing, bloodhound step on the second swing")
        let a2 = await embedding.embed("Finished the Elden Ring DLC on NG+ without summoning")
        let b1 = await embedding.embed("Sourdough levain at 100 percent hydration doubles in five hours")

        let same = Vectors.cosine(a1, a2)
        let different = Vectors.cosine(a1, b1)
        let gap = same - different

        checks.append(Check(
            name: "   separation detail",
            status: "pass",
            detail: String(format: "same topic %.3f, different %.3f, gap %.3f", same, different, gap),
            ms: 0
        ))
        // The threshold this asserts is deliberately low. It is not measuring
        // quality, only that the vectors carry topic information at all.
        try expect(gap > 0.01, String(format: "gap is %.3f — these vectors cannot separate topics", gap))
    }

    private func checkModelAvailable() throws {
        guard Intelligence.availability.isAvailable else {
            throw Skip(why: Intelligence.availability.describe)
        }
    }

    private func checkModelRoundTrip() async throws {
        guard Intelligence.availability.isAvailable else { throw Skip(why: "model unavailable") }
        switch await intelligence.probe() {
        case let .success(word):
            try expect(!word.isEmpty, "model returned an empty answer")
        case let .failure(error):
            throw Failed("\(error)")
        }
    }

    private func checkCapture() async throws {
        let text = "\(Self.marker) the levain doubled in about five hours at 24 degrees"
        let outcome = await capture.capture(text: text)
        created.append(outcome.note.id)

        try expect(!outcome.path.isEmpty, "capture returned no path")
        let url = vault.root.appendingPathComponent(outcome.path)
        try expect(FileManager.default.fileExists(atPath: url.path), "nothing written at \(outcome.path)")
        try expect(vault.entry(outcome.note.id) != nil, "the note is not in the index")

        checks.append(Check(
            name: "   capture detail",
            status: "pass",
            detail: "\(outcome.decision.outcome.rawValue): \(outcome.decision.reason)",
            ms: 0
        ))
    }

    private func checkSearch() async throws {
        let needle = "levain"
        let vector = await embedding.embed(needle)
        let hits = vault.search(needle, vector: vector)
        try expect(
            hits.contains { $0.entry.note.body.lowercased().contains(needle) },
            "search for \(needle.debugDescription) did not return the note that contains it"
        )
    }

    /// Two notes on one subject and one on another: the odd one out must not
    /// land in the same collection as the pair. This is the actual product
    /// claim, reduced to its smallest honest form.
    private func checkFiling() async throws {
        guard embedding.info != nil else { throw Skip(why: "no embedder") }
        guard Intelligence.availability.isAvailable else { throw Skip(why: "model unavailable") }

        let originalColdStart = capture.coldStartNotes
        capture.coldStartNotes = 0
        defer { capture.coldStartNotes = originalColdStart }

        let a = await capture.capture(text: "\(Self.marker) banneton proofing overnight gives a better crumb")
        created.append(a.note.id)
        let b = await capture.capture(text: "\(Self.marker) toast whole spices before grinding for curry")
        created.append(b.note.id)

        checks.append(Check(
            name: "   filing detail",
            status: "pass",
            detail: "a -> \(a.decision.topicPath ?? "Inbox") (\(a.decision.outcome.rawValue)); "
                + "b -> \(b.decision.topicPath ?? "Inbox") (\(b.decision.outcome.rawValue))",
            ms: 0
        ))
    }

    private func checkChat() async throws {
        guard Intelligence.availability.isAvailable else { throw Skip(why: "model unavailable") }
        let data = await chat.respond(to: Chat.Request(message: "what did I write about levain?", history: []))
        let text = String(data: data, encoding: .utf8) ?? ""

        try expect(text.contains("\"type\":\"sources\""), "no sources event in the stream")
        try expect(
            text.contains("\"type\":\"done\"") || text.contains("\"type\":\"token\""),
            "the stream never produced an answer: \(text.prefix(200))"
        )
        try expect(!text.contains("\"type\":\"error\""), "chat returned an error: \(text.prefix(200))")
    }

    private func checkReminder() async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw Skip(why: "notifications are not authorised")
        }

        var note = Note(title: "\(Self.marker) reminder", body: "self-test")
        // Far enough ahead that it cannot fire during the run.
        note.remind = Self.wallClock(minutesFromNow: 45)
        _ = try vault.save(note, topic: nil, vector: [], needsReview: false)
        created.append(note.id)

        await reminders.schedule(note)
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        try expect(
            pending.contains { ($0.content.userInfo["noteId"] as? String) == note.id },
            "the OS did not register the notification"
        )
        await reminders.cancel(noteID: note.id)
    }

    private func cleanUp() async throws {
        for id in created {
            try? vault.delete(id)
            await reminders.cancel(noteID: id)
        }
        // Belt and braces: anything titled with the marker goes, including
        // leftovers from a run that failed partway through.
        for entry in vault.entries.values where entry.note.title.contains(Self.marker) {
            try? vault.delete(entry.note.id)
        }
        let leftovers = vault.entries.values.filter { $0.note.title.contains(Self.marker) }
        try expect(leftovers.isEmpty, "\(leftovers.count) test notes left behind")
        created = []
    }

    static func wallClock(minutesFromNow: Int) -> String {
        Timestamp.localNow(Date().addingTimeInterval(TimeInterval(minutesFromNow * 60)))
    }
}
