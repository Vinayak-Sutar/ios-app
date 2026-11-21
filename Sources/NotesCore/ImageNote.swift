import Foundation

/// What kind of image some bytes are, decided by looking at them.
///
/// Never by the filename or a declared content type: both are supplied by
/// whatever sent the data, and writing an arbitrary blob into the vault
/// because it claimed to be a PNG is how a notes app ends up storing
/// something that is not a note.
public enum ImageFormat: String, Sendable, CaseIterable {
    case png, jpeg, gif, webp, heic, tiff

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .webp: return "webp"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }

    public var contentType: String {
        switch self {
        case .png: return "image/png"
        case .jpeg: return "image/jpeg"
        case .gif: return "image/gif"
        case .webp: return "image/webp"
        case .heic: return "image/heic"
        case .tiff: return "image/tiff"
        }
    }

    /// Identify by magic bytes. Returns nil for anything not recognised,
    /// which is the honest answer and means the upload is refused.
    public static func sniff(_ bytes: [UInt8]) -> ImageFormat? {
        guard bytes.count >= 12 else { return nil }

        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if bytes.starts(with: Array("RIFF".utf8)),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return .webp
        }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return .tiff
        }
        // HEIC: a box-structured file whose brand appears just after "ftyp".
        if Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "heim", "heis", "mif1", "msf1"].contains(brand) {
                return .heic
            }
        }
        return nil
    }

    /// Strips a `data:` URL prefix if there is one, since that is how the page
    /// sends an image, and returns the raw base64.
    public static func base64Payload(of text: String) -> String {
        guard text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else {
            return text
        }
        return String(text[text.index(after: comma)...])
    }
}

/// Where the user's own words end and the machine's begin, inside an image
/// note's body.
///
/// Both live in one Markdown file so the note stays a single readable
/// document — but the interface has to let you edit your own caption without
/// touching a transcript you did not write, and re-running recognition must
/// not clobber what you typed. So the two are separable by convention:
///
///     my words about the screenshot
///
///     **What's in the picture**
///
///     a description
///
///     **Text in image**
///
///     the transcript
public enum ImageNote {

    public static let descriptionHeading = "**What's in the picture**"
    public static let textHeading = "**Text in image**"

    public struct Parts: Sendable, Equatable {
        public var userText: String
        public var description: String
        public var transcript: String

        public init(userText: String = "", description: String = "", transcript: String = "") {
            self.userText = userText
            self.description = description
            self.transcript = transcript
        }
    }

    public static func split(_ body: String) -> Parts {
        var parts = Parts()
        var section = 0            // 0 = user, 1 = description, 2 = transcript
        var buckets: [[String]] = [[], [], []]

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == descriptionHeading {
                section = 1
                continue
            }
            if trimmed == textHeading {
                section = 2
                continue
            }
            buckets[section].append(line)
        }

        parts.userText = trim(buckets[0])
        parts.description = trim(buckets[1])
        parts.transcript = trim(buckets[2])
        return parts
    }

    public static func join(_ parts: Parts) -> String {
        var blocks: [String] = []
        if !parts.userText.isEmpty { blocks.append(parts.userText) }
        if !parts.description.isEmpty {
            blocks.append(descriptionHeading)
            blocks.append(parts.description)
        }
        if !parts.transcript.isEmpty {
            blocks.append(textHeading)
            blocks.append(parts.transcript)
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Replace only the machine-written parts, leaving the caption alone.
    public static func replacingMachineText(
        in body: String, description: String?, transcript: String?
    ) -> String {
        var parts = split(body)
        if let description { parts.description = description }
        if let transcript { parts.transcript = transcript }
        return join(parts)
    }

    /// What a note with no caption yet shows, so the body is never empty while
    /// recognition is still running.
    public static func placeholder(filename: String) -> String {
        "(image: \(filename))"
    }

    public static func isPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("(image:") && trimmed.hasSuffix(")")
    }

    static func trim(_ lines: [String]) -> String {
        var slice = lines[...]
        while let first = slice.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            slice = slice.dropLast()
        }
        return slice.joined(separator: "\n")
    }
}
