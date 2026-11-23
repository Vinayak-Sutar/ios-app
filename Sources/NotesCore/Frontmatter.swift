import Foundation

/// The hand-rolled frontmatter codec, ported from `mnemo/vault.py`.
///
/// This is the most safety-critical code in the app: the Markdown files are the
/// truth and the index is a disposable cache, so a codec bug loses notes rather
/// than inconveniencing a query. It is deliberately NOT a general YAML parser.
/// Only the subset emitted here is supported -- scalars and flow sequences --
/// because YAML 1.1 would read `no` as `false`, coerce `1.0`, choke on an
/// unquoted title containing a colon-space, and turn an all-digits ULID into an
/// integer. A closed schema that fails loudly beats a permissive one here.
///
/// Reads are CRLF-tolerant; writes are always LF.
public struct Frontmatter: Sendable, Equatable {
    public var scalars: [String: String] = [:]
    public var lists: [String: [String]] = [:]

    public init() {}

    public subscript(key: String) -> String? { scalars[key] }
    public func list(_ key: String) -> [String] { lists[key] ?? [] }
}

public enum FrontmatterCodec {

    // MARK: - Emitting

    /// Characters that would change what the line means.
    static let risky: Set<Character> = [":", "#", "[", "]", "{", "}", ",", "\"", "\u{27}"]

    /// Characters YAML reads as an instruction when a value starts with one:
    /// a block scalar, an anchor, an alias, a tag, a directive. Quoted here
    /// even though the parser below would not be fooled, because the Python
    /// vault reads these files with a real YAML parser that would be.
    static let riskyFirst: Set<Character> = ["-", "?", "|", ">", "&", "*", "!", "%", "@", "`"]

    /// Quote when the value is empty, holds a character that would change the
    /// meaning of the line, starts with one YAML would act on, or has
    /// leading/trailing whitespace that would be lost.
    static func emitScalar(_ value: String) -> String {
        guard let first = value.first, let last = value.last else { return "\"\"" }
        let needsQuote =
            value.contains(where: { risky.contains($0) || $0.isNewline || $0 == "\t" })
            || riskyFirst.contains(first)
            || first.isWhitespace
            || last.isWhitespace
        guard needsQuote else { return value }
        return "\"" + escape(value) + "\""
    }

    /// Escape what cannot survive inside one line.
    ///
    /// A newline in a title was previously written out as a newline, which put
    /// a second line inside the frontmatter block: usually dropped on reload,
    /// and if the stray text happened to be `---`, the closing marker moved
    /// and the body was truncated. Titles come from pastes and from a model,
    /// so neither is hypothetical.
    ///
    /// Written scalar by scalar, not character by character. Swift treats
    /// CRLF as one Character, so a switch over Characters would not match
    /// either half of it - the same grapheme trap that once made every note
    /// from the Windows vault parse as a bodyless blob.
    static func escape(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The inverse, in one pass.
    ///
    /// Sequential `replacingOccurrences` cannot do this: unescaping `\\\\`
    /// before `\\n` turns a literal backslash-n into a newline, and doing it
    /// the other way round has the matching flaw. An unrecognised escape is
    /// left exactly as it was found rather than being half-eaten.
    static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "n": out += "\n"
                case "r": out += "\r"
                case "t": out += "\t"
                case "\\": out += "\\"
                case "\"": out += "\""
                default:
                    out.append("\\")
                    out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    static func emitOrder(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }

    public static func render(_ note: Note) -> String {
        var lines: [String] = ["---"]
        lines.append("id: " + note.id)
        lines.append("title: " + emitScalar(note.title))
        lines.append("kind: " + note.kind)
        lines.append("status: " + note.status)
        lines.append("topics: [" + note.topics.map(emitScalar).joined(separator: ", ") + "]")
        lines.append("entities: [" + note.entities.map(emitScalar).joined(separator: ", ") + "]")
        lines.append("tags: [" + note.tags.map(emitScalar).joined(separator: ", ") + "]")
        if let source = note.source, !source.isEmpty {
            lines.append("source: " + emitScalar(source))
        }
        if let media = note.media, !media.isEmpty {
            lines.append("media: " + emitScalar(media))
        }

        // Order matters: the Python side writes these in exactly this sequence,
        // and a byte-identical file keeps diffs against the Windows vault clean.
        func optional(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append(key + ": " + emitScalar(value))
        }
        optional("due", note.due)
        optional("remind", note.remind)
        optional("repeat", note.repeatRule)
        optional("checkin", note.checkin)
        optional("quiet_until", note.quietUntil)
        optional("parent", note.parent)
        if let order = note.order { lines.append("order: " + emitOrder(order)) }

        lines.append("created: " + note.created)
        lines.append("updated: " + note.updated)
        lines.append("---")

        let body = trimTrailingWhitespace(note.body)
        let tail = body.isEmpty ? "\n" : "\n" + body + "\n"
        return lines.joined(separator: "\n") + "\n" + tail
    }

    // MARK: - Parsing

    static func parseScalar(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            return unescape(String(text.dropFirst().dropLast()))
        }
        if text.isEmpty || text == "~" || text == "null" { return nil }
        return text
    }

    /// Split the interior of a flow list, respecting quotes and escapes.
    static func splitFlowList(_ raw: String) -> [String] {
        var out: [String] = []
        var buf = ""
        var inQuotes = false
        var escaped = false
        for ch in raw {
            if escaped {
                buf.append(ch)
                escaped = false
            } else if ch == "\\" {
                buf.append(ch)
                escaped = true
            } else if ch == "\"" {
                inQuotes.toggle()
                buf.append(ch)
            } else if ch == "," && !inQuotes {
                out.append(buf)
                buf = ""
            } else {
                buf.append(ch)
            }
        }
        out.append(buf)
        return out.compactMap { parseScalar($0) }.filter { !$0.isEmpty }
    }

    /// Returns the frontmatter and the body that follows it. A file with no
    /// frontmatter yields empty metadata and the whole text as body, which is
    /// how a note hand-written in the Files app still reads.
    public static func parse(_ text: String) -> (Frontmatter, String) {
        var fm = Frontmatter()

        // Newlines are normalised FIRST, and this is not tidying up.
        //
        // Swift treats "\r\n" as a single grapheme cluster, so
        // `components(separatedBy: "\n")` does not split a CRLF file at all —
        // the entire frontmatter arrives as one "line", no closing `---` is
        // found, and every note silently parses as a bodyless blob with a
        // freshly generated id. The Windows app writes CRLF (Python's
        // `write_text` translates on Windows), so that is not a hypothetical.
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalised.components(separatedBy: "\n")
        guard let first = lines.first, first == "---" else { return (fm, normalised) }

        var closing: Int?
        var index = 1
        while index < lines.count {
            if lines[index] == "---" {
                closing = index
                break
            }
            index += 1
        }
        guard let end = closing else { return (fm, normalised) }

        for raw in lines[1..<end] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if value.hasPrefix("["), value.hasSuffix("]") {
                fm.lists[key] = splitFlowList(String(value.dropFirst().dropLast()))
            } else if let scalar = parseScalar(value) {
                fm.scalars[key] = scalar
            }
        }

        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fm, body)
    }

    public static func load(_ text: String) -> Note {
        let (fm, body) = parse(text)
        return Note(
            id: fm["id"] ?? ULID.generate(),
            title: fm["title"] ?? "",
            body: trimNewlines(body),
            kind: fm["kind"] ?? "note",
            status: fm["status"] ?? "open",
            topics: fm.list("topics"),
            entities: fm.list("entities"),
            tags: fm.list("tags"),
            source: fm["source"],
            media: fm["media"],
            due: fm["due"],
            remind: fm["remind"],
            repeatRule: fm["repeat"],
            checkin: fm["checkin"],
            quietUntil: fm["quiet_until"],
            parent: fm["parent"],
            order: fm["order"].flatMap { Double($0) },
            created: fm["created"] ?? Timestamp.utcNow(),
            updated: fm["updated"] ?? Timestamp.utcNow()
        )
    }

    // MARK: - Helpers

    static func trimTrailingWhitespace(_ text: String) -> String {
        var out = text
        while let last = out.last, last.isWhitespace || last.isNewline { out.removeLast() }
        return out
    }

    static func trimNewlines(_ text: String) -> String {
        var out = text
        while out.hasPrefix("\n") { out.removeFirst() }
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
