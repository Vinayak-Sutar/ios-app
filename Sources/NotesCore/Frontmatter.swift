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

    /// Quote when the value is empty, holds a character that would change the
    /// meaning of the line, or has leading/trailing whitespace that would be
    /// lost. Mirrors the Python `_fm_scalar` regex.
    static func emitScalar(_ value: String) -> String {
        guard let first = value.first, let last = value.last else { return "\"\"" }
        let risky: Set<Character> = [":", "#", "[", "]", "{", "}", ",", "\"", "\u{27}"]
        let needsQuote =
            value.contains(where: { risky.contains($0) })
            || first.isWhitespace
            || last.isWhitespace
        guard needsQuote else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
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
            let inner = String(text.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
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
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, stripCR(first) == "---" else { return (fm, text) }

        var closing: Int?
        var index = 1
        while index < lines.count {
            if stripCR(lines[index]) == "---" {
                closing = index
                break
            }
            index += 1
        }
        guard let end = closing else { return (fm, text) }

        for line in lines[1..<end] {
            let raw = stripCR(line)
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

        let body = lines[(end + 1)...].map(stripCR).joined(separator: "\n")
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

    static func stripCR(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

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
