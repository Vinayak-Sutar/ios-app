import Foundation
import NotesCore
import Vision

/// Reads the text out of an image, using Vision.
///
/// **Vision rather than the language model, deliberately.** Apple's on-device
/// model cannot see images on iOS 26: `Attachment` is iOS 27.0 and later, and
/// images only reach a prompt through it. Vision has done text recognition
/// since iOS 13 and needs no model at all — so on this device it is not a
/// fallback, it is the only thing that works.
///
/// For a notes app it is also the more valuable half. Most images people save
/// are screenshots, and it is the text in them that makes them findable
/// later. The Python app split description and transcription into two calls
/// anyway — one prompt asked to do both reliably returns a summary with a few
/// quoted fragments rather than a transcript — so the split already matches,
/// and a description can slot in behind an availability check on iOS 27.
///
/// An actor: recognition is synchronous and takes hundreds of milliseconds on
/// a large screenshot, which is exactly the kind of work that must not sit on
/// the main actor.
actor TextInImages {

    struct Reading: Sendable {
        var transcript: String
        var lineCount: Int
        var elapsedMS: Int
    }

    /// Recognised text, newline-separated, in reading order.
    ///
    /// Returns an empty transcript rather than throwing when a picture simply
    /// has no text in it — a photo of a dog is not a failure.
    func read(_ data: Data) throws -> Reading {
        let start = Date()

        let request = VNRecognizeTextRequest()
        // Accurate rather than fast: this runs once per image, in the
        // background, and a wrong transcript is worse than a slow one because
        // it is what the note gets filed and searched on.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(data: data, options: [:])
        try handler.perform([request])

        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        let transcript = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return Reading(
            transcript: transcript,
            lineCount: lines.count,
            elapsedMS: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    /// Whether the on-device model could describe an image on this OS.
    ///
    /// Checked at runtime rather than assumed: this build targets iOS 26, the
    /// device may be on 27, and the answer decides whether a description is
    /// even attempted.
    static var canDescribeImages: Bool {
        if #available(iOS 27.0, *) {
            return Intelligence.availability.isAvailable
        }
        return false
    }
}
