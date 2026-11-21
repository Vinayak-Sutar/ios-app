import CryptoKit
import Foundation
import NotesCore

/// Saving a pasted or picked image as a note.
///
/// The same ordering rule as text capture, for the same reason: the file and
/// the note are written first, and recognition runs afterwards. Vision taking
/// a second on a large screenshot, or failing outright, must cost the
/// transcript and never the image.
///
/// Storage is content-addressed by SHA-256, so the same screenshot pasted
/// twice is stored once — which matters more than it sounds, because the
/// obvious alternative is one copy per paste and screenshots are large.
@MainActor
final class ImageCapture {

    private let vault: Vault
    private let capture: Capture
    private let embedding: EmbedderBox
    private let text: TextInImages

    /// Generous, since an iPhone screenshot can be several megabytes, but
    /// bounded: this writes into the user's own storage.
    static let maxBytes = 12_000_000

    init(vault: Vault, capture: Capture, embedding: EmbedderBox, text: TextInImages = TextInImages()) {
        self.vault = vault
        self.capture = capture
        self.embedding = embedding
        self.text = text
    }

    enum Failure: Error, CustomStringConvertible {
        case notBase64
        case empty
        case tooLarge(Int)
        case unsupported

        var description: String {
            switch self {
            case .notBase64: return "that image could not be decoded"
            case .empty: return "the image was empty"
            case let .tooLarge(bytes): return "the image is \(bytes / 1_000_000) MB, which is too large"
            case .unsupported: return "that file is not an image this app recognises"
            }
        }
    }

    struct Result {
        var note: Note
        var path: String
        var media: String
        var transcript: String
        var decision: Decision
        var recognitionMS: Int
    }

    func save(dataURL: String, caption: String) async throws -> Result {
        // 1. Decode and verify it really is an image, by its bytes rather
        //    than by anything the sender claimed.
        guard let data = Data(base64Encoded: ImageFormat.base64Payload(of: dataURL)) else {
            throw Failure.notBase64
        }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge(data.count) }
        guard let format = ImageFormat.sniff([UInt8](data.prefix(16))) else { throw Failure.unsupported }

        // 2. Store, addressed by content. A repeat paste reuses the file.
        let digest = Self.digest(data)
        let filename = "\(digest).\(format.fileExtension)"
        let relative = ".mnemo/media/\(filename)"
        let url = vault.root.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }

        // 3. Write the note before recognising anything.
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = Note(
            title: trimmedCaption.isEmpty
                ? "Image"
                : Capture.provisionalTitle(from: trimmedCaption),
            body: trimmedCaption.isEmpty ? ImageNote.placeholder(filename: filename) : trimmedCaption,
            kind: "image",
            media: relative
        )
        var path = try vault.save(note, topic: nil, vector: [], needsReview: false)

        // 4. Recognise. Vision only: the on-device model cannot see images
        //    before iOS 27.
        var transcript = ""
        var elapsed = 0
        do {
            let reading = try await text.read(data)
            transcript = reading.transcript
            elapsed = reading.elapsedMS
            Log.vault.notice("read \(reading.lineCount, privacy: .public) lines of text in \(reading.elapsedMS, privacy: .public) ms")
        } catch {
            Log.vault.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
        }

        if !transcript.isEmpty {
            let base = ImageNote.isPlaceholder(note.body) ? "" : note.body
            note.body = ImageNote.replacingMachineText(
                in: base, description: nil, transcript: transcript
            )
            // The transcript is usually the only thing worth titling a
            // screenshot by, so use its first line when there is no caption.
            if trimmedCaption.isEmpty, let first = transcript.components(separatedBy: "\n").first {
                note.title = String(first.prefix(60))
            }
        }

        // 5. Now there is text to file on. Without a transcript there is
        //    almost nothing, and Inbox is the honest answer.
        note.updated = Timestamp.utcNow()
        let vector = await embedding.embed(note.embeddingText)
        let candidates = vault.candidates(for: vector, limit: capture.thresholds.topicCandidates)

        var decision: Decision
        if transcript.isEmpty || vector.isEmpty {
            decision = .inbox(reason: "no text found in the image", usedModel: false)
        } else if vault.entries.count < capture.coldStartNotes {
            decision = .inbox(
                reason: "still learning your collections (\(capture.coldStartNotes - vault.entries.count) more notes)",
                usedModel: false
            )
        } else {
            decision = Router.decideFromRetrieval(candidates, capture.thresholds)
        }

        note.topics = decision.topicPath.map { [$0] } ?? []
        path = (try? vault.save(
            note, topic: decision.topicPath, vector: vector,
            needsReview: decision.outcome == .review, recordUndo: true
        )) ?? path

        return Result(
            note: note, path: path, media: relative,
            transcript: transcript, decision: decision, recognitionMS: elapsed
        )
    }

    /// SHA-256, first 16 hex characters — the same scheme the Python vault
    /// uses, so media filenames are interchangeable between the two.
    ///
    /// CryptoKit, not a hand-rolled one. I wrote a hundred lines of SHA-256
    /// here first, which would have been a hundred lines of unverifiable risk
    /// compiled on a machine three thousand miles away to hash a screenshot.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .description
    }
}
