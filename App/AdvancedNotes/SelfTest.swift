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

    /// Measures how far apart related and unrelated notes sit, raw and centred.
    ///
    /// Both, because the first run measured a gap of 0.055 with everything
    /// scoring 0.84–0.90: mean-pooled transformer vectors share a large common
    /// direction, so almost the whole cosine range is wasted and a threshold
    /// has nowhere to sit. Centring removes that shared component. Whether it
    /// helps *here* is a question for the device, not for my judgement — so it
    /// reports both and lets the numbers decide.
    private func checkSeparation() async throws {
        guard embedding.info != nil else { throw Skip(why: "no embedder") }

        let gaming = [
            "Malenia waterfowl dance timing, bloodhound step on the second swing",
            "Finished the Elden Ring DLC on NG+ without summoning",
            "The RTX 4070 undervolt saves 30 watts with no framerate loss"
        ]
        let cooking = [
            "Sourdough levain at 100 percent hydration doubles in five hours",
            "Banneton proofing overnight in the fridge gives a better crumb",
            "Toast whole spices before grinding or the curry tastes flat"
        ]

        var vectors: [[Float]] = []
        for text in gaming + cooking { vectors.append(await embedding.embed(text)) }
        try expect(vectors.allSatisfy { !$0.isEmpty }, "an embedding came back empty")

        func measure(_ set: [[Float]]) -> (same: Double, different: Double, gap: Double) {
            var same: [Double] = []
            var different: [Double] = []
            for i in 0..<set.count {
                for j in (i + 1)..<set.count {
                    let sameTopic = (i < 3) == (j < 3)
                    let score = Vectors.cosine(set[i], set[j])
                    if sameTopic { same.append(score) } else { different.append(score) }
                }
            }
            let a = same.reduce(0, +) / Double(max(1, same.count))
            let b = different.reduce(0, +) / Double(max(1, different.count))
            return (a, b, a - b)
        }

        let raw = measure(vectors)
        let centred = measure(Vectors.centred(vectors))

        checks.append(Check(
            name: "   separation detail",
            status: "pass",
            detail: String(
                format: "raw: same %.3f, diff %.3f, gap %.3f  |  centred: same %.3f, diff %.3f, gap %.3f",
                raw.same, raw.different, raw.gap, centred.same, centred.different, centred.gap
            ),
            ms: 0
        ))
        checks.append(Check(
            name: "   centring verdict",
            status: centred.gap > raw.gap ? "pass" : "skip",
            detail: centred.gap > raw.gap
                ? String(format: "centring widens the gap %.3f -> %.3f (%.1fx)", raw.gap, centred.gap, centred.gap / max(0.001, raw.gap))
                : String(format: "centring does not help here (%.3f vs %.3f)", centred.gap, raw.gap),
            ms: 0
        ))

        // Deliberately a low bar. This is not measuring quality, only that the
        // vectors carry topic information at all.
        try expect(
            max(raw.gap, centred.gap) > 0.01,
            String(format: "best gap is %.3f — these vectors cannot separate topics", max(raw.gap, centred.gap))
        )
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

    /// Seed two collections, then file a note that plainly belongs in one.
    ///
    /// The first version of this check passed without testing anything: it
    /// captured two notes into an empty vault, where there are no collections
    /// to choose between, so "went to Inbox" was the only possible outcome and
    /// the assertion was that the code ran. A green check that cannot fail is
    /// worse than no check, because it is read as evidence.
    private func checkFiling() async throws {
        guard embedding.info != nil else { throw Skip(why: "no embedder") }

        let originalColdStart = capture.coldStartNotes
        capture.coldStartNotes = 0
        defer { capture.coldStartNotes = originalColdStart }

        // Seed directly rather than through capture, so the collections exist
        // regardless of how capture decides to file them.
        let seeds: [(String, String)] = [
            ("SelfTestCooking", "sourdough levain doubles in five hours at room temperature"),
            ("SelfTestCooking", "banneton proofing overnight in the fridge gives a better crumb"),
            ("SelfTestCooking", "toast whole spices before grinding or the curry tastes flat"),
            ("SelfTestGaming", "malenia waterfowl dance timing is brutal, bloodhound step works"),
            ("SelfTestGaming", "finished the elden ring dlc on NG+ without summoning"),
            ("SelfTestGaming", "the rtx 4070 undervolt saves thirty watts with no framerate loss")
        ]
        for (collection, text) in seeds {
            let note = Note(title: "\(Self.marker) \(text.prefix(30))", body: text)
            let vector = await embedding.embed(note.embeddingText)
            _ = try vault.save(note, topic: collection, vector: vector, needsReview: false)
            created.append(note.id)
        }

        let probe = "\(Self.marker) the starter rose faster in a warm kitchen than in the fridge"
        let vector = await embedding.embed(probe)
        let candidates = vault.candidates(for: vector, limit: 8)

        let best = candidates.first
        let runnerUp = candidates.count > 1 ? candidates[1] : nil
        checks.append(Check(
            name: "   filing detail",
            status: "pass",
            detail: candidates
                .prefix(3)
                .map { String(format: "%@ %.3f", $0.path, $0.similarity) }
                .joined(separator: ", "),
            ms: 0
        ))

        try expect(best != nil, "no collections to choose from")
        // The real claim: a baking note is nearer the baking collection than
        // the gaming one. If retrieval cannot do this, no threshold saves it.
        try expect(
            best?.path == "SelfTestCooking",
            "a baking note ranked \(best?.path ?? "nothing") first"
        )
        if let best, let runnerUp {
            checks.append(Check(
                name: "   filing margin",
                status: "pass",
                detail: String(format: "%.4f between first and second", best.similarity - runnerUp.similarity),
                ms: 0
            ))
        }
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
